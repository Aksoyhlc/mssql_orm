import 'dart:async';

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_executor.dart';

void main() {
  group('what it reports', () {
    test('the sql and the values, for a read', () async {
      final log = MssqlQueryRecorder();
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1},
          <String, Object?>{'Id': 2},
        ]);
      await fake
          .observedBy(
            log.record,
            options: const MssqlObserverOptions(includeParameterValues: true),
          )
          .queryRows(
            'SELECT [Id] FROM [dbo].[Users] WHERE [Name] = @q0',
            parameters: <String, Object?>{'q0': 'Ali'},
          );
      final event = log.events.single;
      expect(event.sql, contains('FROM [dbo].[Users]'));
      expect(event.parameters, <String, Object?>{'q0': 'Ali'});
      expect(event.kind, MssqlQueryKind.query);
      expect(event.rows, 2);
      expect(event.affectedRows, 2);
      expect(event.failed, isFalse);
    });

    test('the rows changed, for a write', () async {
      final log = MssqlQueryRecorder();
      final fake = FakeExecutor()..affected.add(7);
      await fake.observedBy(log.record).execute('DELETE FROM [dbo].[Users]');
      final event = log.events.single;
      expect(event.kind, MssqlQueryKind.query);
      expect(event.affectedRows, 7);
      expect(event.rows, isNull);
    });

    test('both, for the full result a query returns', () async {
      final log = MssqlQueryRecorder();
      await _QueryOnlyExecutor(
        rows: 3,
        affected: 9,
      ).observedBy(log.record).query('SELECT 1');
      final event = log.events.single;
      expect(event.kind, MssqlQueryKind.query);
      expect(event.rows, 3);
      expect(event.affectedRows, 9);
    });

    test('no result set at all is no row count, rather than zero', () async {
      final log = MssqlQueryRecorder();
      await _QueryOnlyExecutor(
        rows: null,
        affected: 4,
      ).observedBy(log.record).query('EXEC dbo.DoSomething');
      expect(log.events.single.rows, isNull);
      expect(log.events.single.affectedRows, 4);
    });

    test('how long it took', () async {
      final log = MssqlQueryRecorder();
      await FakeExecutor().observedBy(log.record).execute('DELETE FROM T');
      expect(log.events.single.elapsed, greaterThanOrEqualTo(Duration.zero));
      expect(log.elapsed, log.events.single.elapsed);
    });

    test('whether it ran inside a transaction', () async {
      final log = MssqlQueryRecorder();
      await FakeExecutor(
        inTransaction: true,
      ).observedBy(log.record).execute('DELETE FROM T');
      expect(log.events.single.inTransaction, isTrue);

      log.clear();
      await FakeExecutor().observedBy(log.record).execute('DELETE FROM T');
      expect(log.events.single.inTransaction, isFalse);
    });
  });

  group('a statement that failed', () {
    test('is reported, then rethrown', () async {
      final log = MssqlQueryRecorder();
      final fake = FakeExecutor()
        ..queryRowsErrors.add(
          MssqlException(
            type: MssqlErrorType.querySyntax,
            message: 'invalid column',
          ),
        );
      await expectLater(
        fake.observedBy(log.record).queryRows('SELECT [Nope] FROM T'),
        throwsA(isA<MssqlException>()),
      );
      final event = log.events.single;
      expect(event.failed, isTrue);
      expect(event.failure, isA<MssqlException>());
      expect(event.rows, isNull);
      expect(log.failures, hasLength(1));
    });

    test('still carries the sql that caused it', () async {
      final log = MssqlQueryRecorder();
      final fake = FakeExecutor()..executeErrors.add(StateError('nope'));
      await expectLater(
        fake.observedBy(log.record).execute('UPDATE T SET X = 1'),
        throwsStateError,
      );
      expect(log.events.single.sql, 'UPDATE T SET X = 1');
    });
  });

  group('an observer that misbehaves', () {
    test('cannot turn a statement that worked into one that failed', () async {
      final fake = FakeExecutor()..affected.add(1);
      final executor = fake.observedBy((_) => throw StateError('bad logger'));
      final errors = <Object>[];
      await runZonedGuarded(() async {
        expect(await executor.execute('DELETE FROM T'), 1);
      }, (error, _) => errors.add(error));
      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
    });

    test('does not stop the next statement being watched', () async {
      final log = MssqlQueryRecorder();
      var first = true;
      final executor = FakeExecutor().observedBy((event) {
        if (first) {
          first = false;
          throw StateError('bad logger');
        }
        log.record(event);
      });
      await runZonedGuarded(() async {
        await executor.execute('DELETE FROM A');
        await executor.execute('DELETE FROM B');
      }, (_, _) {});
      expect(log.events.single.sql, 'DELETE FROM B');
    });
  });

  group('the executor it wraps', () {
    test('is not otherwise interfered with', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 5},
        ]);
      final rows = await fake
          .observedBy((_) {})
          .queryRows(
            'SELECT 1',
            parameters: <String, Object?>{'a': 1},
            timeout: const Duration(seconds: 3),
            retry: MssqlRetryPolicy.idempotentRead,
          );
      expect(rows.single['Id'], 5);
      expect(fake.onlyCall.sql, 'SELECT 1');
      expect(fake.onlyCall.parameters, <String, Object?>{'a': 1});
      expect(fake.onlyCall.idempotent, isTrue);
    });

    test('still answers for the transaction and the decimal setting', () {
      final inner = FakeExecutor(
        inTransaction: true,
        decimalMode: MssqlDecimalMode.text,
      );
      final observed = inner.observedBy((_) {});
      expect(observed.inTransaction, isTrue);
      expect(observed.config.decimalMode, MssqlDecimalMode.text);
    });

    test('can be wrapped twice, and both are told', () async {
      final first = MssqlQueryRecorder();
      final second = MssqlQueryRecorder();
      await FakeExecutor()
          .observedBy(first.record)
          .observedBy(second.record)
          .execute('DELETE FROM T');
      expect(first.count, 1);
      expect(second.count, 1);
    });
  });

  group('a repository under one', () {
    test('reports every statement it sends, relations included', () async {
      final log = MssqlQueryRecorder();
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[])
        ..affected.add(1);
      final executor = fake.observedBy(log.record);
      await executor.queryRows('SELECT 1');
      await executor.execute('UPDATE T SET X = 1');
      expect(log.count, 2);
      expect(log.events.map((e) => e.kind), <MssqlQueryKind>[
        MssqlQueryKind.query,
        MssqlQueryKind.query,
      ]);
    });
  });

  group('the recorder', () {
    test('sums the time and counts the statements', () async {
      final log = MssqlQueryRecorder();
      final executor = FakeExecutor().observedBy(log.record);
      await executor.execute('DELETE FROM A');
      await executor.execute('DELETE FROM B');
      expect(log.count, 2);
      expect(log.elapsed, log.events[0].elapsed + log.events[1].elapsed);
    });

    test('clears', () async {
      final log = MssqlQueryRecorder();
      await FakeExecutor().observedBy(log.record).execute('DELETE FROM A');
      log.clear();
      expect(log.count, 0);
      expect(log.elapsed, Duration.zero);
    });

    test('describes nothing as nothing, rather than an empty report', () {
      expect(MssqlQueryRecorder().describe(), 'No statements.');
    });

    test('lists the statements longest first', () async {
      final log = MssqlQueryRecorder()
        ..record(_event('SELECT 1', const Duration(milliseconds: 1)))
        ..record(_event('SELECT 2', const Duration(milliseconds: 50)))
        ..record(_event('SELECT 3', const Duration(milliseconds: 10)));
      final text = log.describe();
      expect(text, contains('3 statement(s)'));
      expect(text, contains('61ms total'));
      expect(text.indexOf('SELECT 2'), lessThan(text.indexOf('SELECT 3')));
      expect(text.indexOf('SELECT 3'), lessThan(text.indexOf('SELECT 1')));
    });

    test('a line says the time, the outcome and the statement', () {
      final line = _event(
        'SELECT\n  [Id]\nFROM [T]',
        const Duration(milliseconds: 12),
        rows: 3,
      ).toString();
      expect(line, startsWith('12.0ms'));
      expect(line, contains('3 row(s)'));
      expect(line, contains('SELECT [Id] FROM [T]'));
      expect(line, isNot(contains('\n')));
    });

    test('a failed line says so instead of a row count', () {
      final line = MssqlQueryEvent(
        sql: 'SELECT 1',
        parameters: const <String, Object?>{},
        elapsed: const Duration(milliseconds: 2),
        kind: MssqlQueryKind.query,
        inTransaction: false,
        failure: StateError('nope'),
      ).toString();
      expect(line, contains('failed:'));
      expect(line, contains('nope'));
    });
  });
}

MssqlQueryEvent _event(String sql, Duration elapsed, {int? rows}) =>
    MssqlQueryEvent(
      sql: sql,
      parameters: const <String, Object?>{},
      elapsed: elapsed,
      kind: MssqlQueryKind.query,
      inTransaction: false,
      rows: rows,
    );

class _QueryOnlyExecutor with MssqlSession {
  _QueryOnlyExecutor({required this.rows, required this.affected});

  final int? rows;
  final int affected;

  @override
  bool get inTransaction => false;

  @override
  final MssqlConnectionConfig config = const MssqlConnectionConfig(
    host: 'fake',
    database: 'fake',
    username: 'fake',
    password: 'fake',
  );

  @override
  Future<MssqlExecutionResult> query(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlRetryPolicy? retry,
  }) async => MssqlExecutionResult(
    resultSets: <MssqlResultSet>[
      if (rows != null)
        MssqlResultSet.fromValues(
          columns: <MssqlColumn>[
            MssqlColumn(
              index: 0,
              name: 'Id',
              type: MssqlType.int32,
              nullable: false,
              maxLength: 4,
              precision: 0,
              scale: 0,
              nativeType: 0,
            ),
          ],
          values: <List<Object?>>[
            for (var i = 0; i < rows!; i++) <Object?>[i],
          ],
          metrics: MssqlResultSetMetrics.empty,
        ),
    ],
    affectedRows: affected,
    messages: const <MssqlServerMessage>[],
    returnStatus: null,
    outputParameters: const <String, Object?>{},
    metrics: MssqlExecutionMetrics.empty,
  );

  @override
  Future<MssqlExecutionResult> callProcedure(
    String procedure, {
    Object parameters = const <String, Object?>{},
    Set<String> outputParameters = const <String>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
    MssqlProcedureMetadata? declared,
    MssqlMetadataDriftPolicy driftPolicy =
        MssqlMetadataDriftPolicy.preferDeclared,
  }) {
    throw UnimplementedError();
  }

  @override
  Stream<MssqlStreamEvent> stream(
    String sql, {
    Object parameters = const <String, Object?>{},
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    int? batchRows,
    int? maximumRows,
    int? maximumBytes,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> ping({MssqlCancellationToken? cancellationToken}) async {}
}

