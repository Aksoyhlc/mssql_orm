// Records the SQL the examples build. It implements MssqlSession so the
// generated AppDatabase can run against it, but the printed SQL is a
// rendering — not evidence that SQL Server accepted it or returned these
// rows. Nothing here talks to a server.
//
// Dialect probes (SERVERPROPERTY) are answered locally so they do not
// consume the prepared result rows.
library;

import 'package:mssql_native/mssql_native.dart';

class RecordingSession with MssqlSession {
  RecordingSession({
    this.inTransaction = false,
    MssqlDecimalMode decimalMode = MssqlDecimalMode.exact,
  }) : config = MssqlConnectionConfig(
         host: 'example',
         database: 'example',
         username: 'example',
         password: '',
         decimalMode: decimalMode,
       );

  @override
  final bool inTransaction;

  @override
  final MssqlConnectionConfig config;

  /// Answers for reads, consumed in order; a call past the end gets none.
  final List<List<Map<String, Object?>>> replies =
      <List<Map<String, Object?>>>[];

  /// What a write reports as affected, consumed in order; 1 when exhausted.
  final List<int> affected = <int>[];

  final List<String> statements = <String>[];
  int _replyIndex = 0;
  int _affectedIndex = 0;

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
  }) async {
    statements.add(sql);
    if (_isDialectProbe(sql)) {
      return MssqlExecutionResult(
        resultSets: <MssqlResultSet>[
          _resultSet(<Map<String, Object?>>[
            <String, Object?>{'v': '11.0.2100.60', 'c': 110},
          ]),
        ],
        affectedRows: 0,
        outputParameters: const <String, Object?>{},
        messages: const <MssqlServerMessage>[],
      );
    }
    final rows = _replyIndex < replies.length
        ? replies[_replyIndex++]
        : const <Map<String, Object?>>[];
    final changed = _affectedIndex < affected.length
        ? affected[_affectedIndex++]
        : 1;
    return MssqlExecutionResult(
      resultSets: rows.isEmpty
          ? const <MssqlResultSet>[]
          : <MssqlResultSet>[_resultSet(rows)],
      affectedRows: rows.isEmpty ? changed : 0,
      outputParameters: const <String, Object?>{},
      messages: const <MssqlServerMessage>[],
    );
  }

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
  }) => throw UnsupportedError('The examples do not call procedures.');

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
  }) => throw UnsupportedError('The examples do not stream.');

  @override
  Future<void> ping({MssqlCancellationToken? cancellationToken}) async {}
}

bool _isDialectProbe(String sql) =>
    sql.contains("SERVERPROPERTY('ProductVersion')");

MssqlResultSet _resultSet(List<Map<String, Object?>> maps) {
  final names = maps.first.keys.toList();
  return MssqlResultSet.fromValues(
    columns: <MssqlColumn>[
      for (var i = 0; i < names.length; i++)
        MssqlColumn(
          index: i,
          name: names[i],
          type: MssqlType.varchar,
          nullable: true,
          maxLength: 0,
          precision: 0,
          scale: 0,
          nativeType: 0,
        ),
    ],
    values: <List<Object?>>[
      for (final m in maps) <Object?>[for (final name in names) m[name]],
    ],
    metrics: MssqlResultSetMetrics.empty,
  );
}
