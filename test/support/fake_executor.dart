import 'package:mssql_native/mssql_native.dart';

class FakeExecutor with MssqlSession {
  FakeExecutor({
    this.inTransaction = false,
    MssqlDecimalMode decimalMode = MssqlDecimalMode.exact,
  }) : config = MssqlConnectionConfig(
         host: 'fake',
         database: 'fake',
         username: 'fake',
         password: 'fake',
         decimalMode: decimalMode,
       );

  @override
  final bool inTransaction;

  @override
  final MssqlConnectionConfig config;

  final List<FakeCall> calls = <FakeCall>[];

  void Function(FakeCall call)? afterCall;

  final List<List<Map<String, Object?>>> replies =
      <List<Map<String, Object?>>>[];

  final List<int> affected = <int>[];

  final List<Object> queryRowsErrors = <Object>[];
  final List<Object> executeErrors = <Object>[];

  int _replyIndex = 0;
  int _affectedIndex = 0;
  int _queryRowsErrorIndex = 0;
  int _executeErrorIndex = 0;

  FakeCall get lastCall => calls.last;
  FakeCall get onlyCall {
    if (calls.length != 1) {
      throw StateError('Expected one call, got ${calls.length}: $calls');
    }
    return calls.single;
  }

  List<Map<String, Object?>> _nextReply() =>
      _replyIndex < replies.length ? replies[_replyIndex++] : const [];

  int _nextAffected() =>
      _affectedIndex < affected.length ? affected[_affectedIndex++] : 1;

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
    final policy = retry ?? options.retry;
    final call = FakeCall(
      sql,
      _asMap(parameters),
      bound: _rawMap(parameters),
      retry: policy,
    );
    calls.add(call);
    afterCall?.call(call);
    final upper = sql.trimLeft().toUpperCase();
    final counted = sql.contains('AS [mssql_affected]');
    final isWrite =
        counted ||
        upper.startsWith('INSERT') ||
        upper.startsWith('UPDATE') ||
        upper.startsWith('DELETE') ||
        upper.startsWith('MERGE');
    final returnsRows =
        !isWrite ||
        upper.contains('OUTPUT') ||
        upper.contains('SCOPE_IDENTITY') ||
        upper.contains('RETURNING');
    if (isWrite) {
      if (_executeErrorIndex < executeErrors.length) {
        throw executeErrors[_executeErrorIndex++];
      }
    } else if (_queryRowsErrorIndex < queryRowsErrors.length) {
      throw queryRowsErrors[_queryRowsErrorIndex++];
    }
    if (counted) {
      return driverResult(<Map<String, Object?>>[
        <String, Object?>{'mssql_affected': _nextAffected()},
      ]);
    }
    if (returnsRows && _replyIndex < replies.length) {
      return driverResult(_nextReply());
    }
    if (!returnsRows) {
      return MssqlExecutionResult(
        resultSets: const <MssqlResultSet>[],
        affectedRows: _nextAffected(),
        messages: const <MssqlServerMessage>[],
        returnStatus: null,
        outputParameters: const <String, Object?>{},
        metrics: MssqlExecutionMetrics.empty,
      );
    }
    return const MssqlExecutionResult(
      resultSets: <MssqlResultSet>[],
      affectedRows: 0,
      messages: <MssqlServerMessage>[],
      returnStatus: null,
      outputParameters: <String, Object?>{},
      metrics: MssqlExecutionMetrics.empty,
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
  }) {
    throw UnimplementedError('FakeExecutor.callProcedure');
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
    throw UnimplementedError('FakeExecutor.stream');
  }

  @override
  Future<void> ping({MssqlCancellationToken? cancellationToken}) async {}

  Map<String, Object?> _asMap(Object parameters) {
    if (parameters is! Map) {
      throw ArgumentError.value(parameters, 'parameters');
    }
    return <String, Object?>{
      for (final entry in parameters.entries)
        entry.key.toString(): _unwrap(entry.value),
    };
  }

  Map<String, Object?> _rawMap(Object parameters) {
    if (parameters is! Map) {
      throw ArgumentError.value(parameters, 'parameters');
    }
    return <String, Object?>{
      for (final entry in parameters.entries) entry.key.toString(): entry.value,
    };
  }
}

Object? _unwrap(Object? value) => value is MssqlValue ? value.value : value;

class FakeCall {
  const FakeCall(
    this.sql,
    this.parameters, {
    required this.bound,
    required this.retry,
  });

  final String sql;

  final Map<String, Object?> parameters;

  final Map<String, Object?> bound;

  final MssqlRetryPolicy retry;

  bool get idempotent => retry == MssqlRetryPolicy.idempotentRead;

  @override
  String toString() => 'FakeCall($sql, $parameters, retry: ${retry.name})';
}

MssqlExecutionResult driverResult(List<Map<String, Object?>> maps) {
  if (maps.isEmpty) {
    return const MssqlExecutionResult(
      resultSets: <MssqlResultSet>[],
      affectedRows: 0,
      messages: <MssqlServerMessage>[],
      returnStatus: null,
      outputParameters: <String, Object?>{},
      metrics: MssqlExecutionMetrics.empty,
    );
  }
  final names = maps.first.keys.toList();
  return MssqlExecutionResult(
    resultSets: <MssqlResultSet>[
      MssqlResultSet.fromValues(
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
      ),
    ],
    affectedRows: maps.length,
    messages: const <MssqlServerMessage>[],
    returnStatus: null,
    outputParameters: const <String, Object?>{},
    metrics: MssqlExecutionMetrics.empty,
  );
}

