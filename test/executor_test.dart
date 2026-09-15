import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_driver.dart';

void main() {
  group('app database query execution', () {
    test('passes the compiled read retry policy to the session', () async {
      final fake = FakeConnection();
      final database = MssqlUntypedDatabase(fake);

      await database.query(
        MssqlQuery.from('dbo.Users'),
        dialect: MssqlDialect.sql2012,
      );

      expect(fake.onlyCall.member, 'queryTypedRows');
      expect(fake.onlyCall['retry'], MssqlRetryPolicy.idempotentRead);
    });
  });

  group('a connection is a session', () {
    test('reports that it is not in a transaction', () {
      expect(FakeConnection().inTransaction, isFalse);
    });

    test('reads decimalMode from the connection config', () {
      expect(
        FakeConnection(
          decimalMode: MssqlDecimalMode.doublePrecision,
        ).config.decimalMode,
        MssqlDecimalMode.doublePrecision,
      );
      expect(
        FakeConnection(decimalMode: MssqlDecimalMode.text).config.decimalMode,
        MssqlDecimalMode.text,
      );
    });

    test(
      'query passes the sql, parameters, timeout and retry through',
      () async {
        final fake = FakeConnection();
        await fake.query(
          'SELECT 1',
          parameters: <String, Object?>{'a': 1},
          timeout: const Duration(seconds: 7),
          retry: MssqlRetryPolicy.idempotentRead,
        );
        expect(fake.onlyCall.member, 'query');
        expect(fake.onlyCall.sql, 'SELECT 1');
        expect(fake.onlyCall.parameters, <String, Object?>{'a': 1});
        expect(fake.onlyCall['timeout'], const Duration(seconds: 7));
        expect(fake.onlyCall['retry'], MssqlRetryPolicy.idempotentRead);
      },
    );

    test('queryRows returns the first result set as maps', () async {
      final fake = FakeConnection()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1, 'Name': 'a'},
          <String, Object?>{'Id': 2, 'Name': 'b'},
        ]);
      final rows = await fake.queryRows('SELECT 1');
      expect(rows, hasLength(2));
      expect(rows.first['Name'], 'a');
    });

    test('queryRows returns an empty list when nothing came back', () async {
      final fake = FakeConnection();
      expect(await fake.queryRows('SELECT 1'), isEmpty);
    });

    test('queryRows carries retry too', () async {
      final fake = FakeConnection();
      await fake.queryRows('SELECT 1', retry: MssqlRetryPolicy.idempotentRead);
      expect(fake.onlyCall['retry'], MssqlRetryPolicy.idempotentRead);
      expect(fake.onlyCall.member, 'queryRows');
    });

    test('execute reports the affected row count', () async {
      final fake = FakeConnection()..affected.add(3);
      expect(await fake.execute('DELETE FROM T'), 3);
      expect(fake.onlyCall.member, 'execute');
    });

    test('a driver failure is not swallowed', () async {
      final fake = FakeConnection()
        ..failures.add(
          MssqlException(type: MssqlErrorType.connection, message: 'gone'),
        );
      await expectLater(
        fake.queryRows('SELECT 1'),
        throwsA(isA<MssqlException>()),
      );
    });
  });

  group('a transaction is a session', () {
    test('reports that it is in a transaction', () {
      expect(FakeTransaction().inTransaction, isTrue);
    });

    test('reads decimalMode from the transaction\'s own connection', () {
      expect(
        FakeTransaction(decimalMode: MssqlDecimalMode.text).config.decimalMode,
        MssqlDecimalMode.text,
      );
    });

    test('query goes to the transaction, not around it', () async {
      final fake = FakeTransaction();
      await fake.query('SELECT 1');
      expect(fake.calls, hasLength(1));
      expect(fake.connection.calls, isEmpty);
    });

    test('retry is recorded on the transaction call', () async {
      final fake = FakeTransaction();
      await fake.queryRows('SELECT 1', retry: MssqlRetryPolicy.idempotentRead);
      expect(fake.onlyCall['retry'], MssqlRetryPolicy.idempotentRead);
    });

    test('queryRows types the first result set, and copes with none', () async {
      final withRows = FakeTransaction()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1},
        ]);
      expect(await withRows.queryRows('SELECT 1'), hasLength(1));
      expect(await FakeTransaction().queryRows('SELECT 1'), isEmpty);
    });

    test('execute reports the affected row count', () async {
      final fake = FakeTransaction()..affected.add(2);
      expect(await fake.execute('DELETE FROM T'), 2);
    });
  });
}

