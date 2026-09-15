import 'dart:async';

import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

/// How an observer prints and stores bound parameter values.
///
/// Values are off by default: a log of `WHERE email = @p0` with the address
/// still in it is a leak, and a password in an exception default is a
/// password to rotate. Turning values on is an explicit choice for a
/// local debugging session, and even then names that look like secrets
/// stay redacted.
@immutable
class MssqlObserverOptions {
  const MssqlObserverOptions({
    this.includeParameterValues = false,
    this.recorderCapacity = 256,
  });

  /// When true, non-secret parameter values are kept on the event.
  final bool includeParameterValues;

  /// How many events [MssqlQueryRecorder] keeps. Oldest are dropped.
  final int recorderCapacity;
}

/// Called when an observer itself throws after a statement succeeded.
///
/// The write already happened. Routing that error through the caller's
/// `catch` would make a successful DML look like a failed one and could
/// trip a retry. The sink is a separate channel.
typedef MssqlDiagnosticSink = void Function(Object error, StackTrace stack);

/// Compile elapsed for the statement that is about to run on [session].
///
/// The observer wraps the session, not the compiler, so compile time has
/// to be handed across this seam. [MssqlSelectQuery.get] records it;
/// [MssqlObservedSession] reads it once and clears it.
void mssqlNoteCompileElapsed(MssqlSession session, Duration elapsed) {
  _compileElapsed[session] = elapsed;
}

final Expando<Duration> _compileElapsed = Expando<Duration>();

Duration? _takeCompileElapsed(MssqlSession session) {
  final value = _compileElapsed[session];
  _compileElapsed[session] = null;
  return value;
}

/// What one statement did.
@immutable
class MssqlQueryEvent {
  const MssqlQueryEvent({
    required this.sql,
    required this.parameters,
    required this.elapsed,
    required this.kind,
    required this.inTransaction,
    this.rows,
    this.affectedRows,
    this.failure,
    this.compileElapsed,
    this.queueWait,
    this.executionElapsed,
    this.mappingElapsed,
    this.relationLoadElapsed,
    this.decodedBytes,
    this.roundTrips,
    this.batchRows,
    this.queryName,
  });

  final String sql;

  /// Bound parameters, redacted unless the observer was told to keep values.
  final Object parameters;

  /// How long the call took from the session's point of view.
  final Duration elapsed;

  /// Which kind of command ran.
  final MssqlQueryKind kind;

  final bool inTransaction;

  /// Rows read, for a read. Null for a write and for a buffered statement
  /// that failed.
  final int? rows;

  /// Rows changed, for a write.
  final int? affectedRows;

  /// What the statement threw, when it threw.
  final Object? failure;

  /// Time spent compiling SQL on this isolate. Null when the observer did
  /// not see a compiler — a raw `session.query` has none.
  final Duration? compileElapsed;

  /// Time the driver spent waiting for the connection's operation gate.
  ///
  /// This is client-side queueing, not server CPU. The driver does not
  /// measure server CPU, and this field is not a substitute for it.
  final Duration? queueWait;

  /// Time the driver spent running the command after the gate opened.
  final Duration? executionElapsed;

  /// Time spent mapping native rows onto generated types. Null on a session
  /// observer: mapping happens above the session.
  final Duration? mappingElapsed;

  /// Time spent loading included relations. Null on a session observer.
  final Duration? relationLoadElapsed;

  /// Bytes the driver decoded for this result, when the driver measured it.
  final int? decodedBytes;

  /// Network round-trips this event represents.
  ///
  /// One statement is one round-trip. A cached procedure describe that is
  /// skipped is not a round-trip. This is not "how many SQL strings were
  /// built".
  final int? roundTrips;

  /// `MssqlQueryOptions.batchRows` for the command, when it had one.
  final int? batchRows;

  /// Caller-supplied label from `MssqlQueryOptions.queryName`.
  final String? queryName;

  bool get failed => failure != null;

  @override
  String toString() {
    final millis = elapsed.inMicroseconds / 1000;
    final outcome = failed
        ? 'failed: $failure'
        : rows != null
        ? '$rows row(s)'
        : '${affectedRows ?? 0} affected';
    final name = queryName;
    final label = name == null ? '' : '$name  ';
    return '${millis.toStringAsFixed(1)}ms  $label$outcome  '
        '${sql.replaceAll(RegExp(r'\s+'), ' ')}';
  }
}

/// The session primitives an observer sees.
///
/// Buffered reads and writes funnel through `query`. BCP does not, so
/// [bulkCopy] is its own kind rather than pretending an INSERT ran.
enum MssqlQueryKind { query, procedure, stream, bulkCopy }

/// Called once per statement, after it finishes.
typedef MssqlQueryObserver = void Function(MssqlQueryEvent event);

/// A session that reports every statement to [observer].
///
/// This wraps the session rather than the ORM because everything goes through
/// the session — queries, the relation loader, generated typed SQL and a
/// hand-built query alike — so one observer sees the lot. A hook further up
/// would miss exactly the statements worth watching: the ones a relation load
/// fans out into.
///
/// "Fifty parents cost three queries" cannot be checked from outside; a counter
/// here makes an N+1 measurable.
///
/// Only the session's primitives are overridden. Conveniences derived from
/// `query` — `queryRows`, `querySingle`, `execute` — reach the observer
/// through `query`. [MssqlSession.bulkInsert] is its own primitive, so it
/// is overridden here too rather than looking like an INSERT.
///
/// ```dart
/// final log = MssqlQueryRecorder();
/// final db = AppDatabase(connection.observedBy(log.record));
/// await db.orders.include((o) => [o.customer]).get();
/// print('${log.count} statements, ${log.elapsed.inMilliseconds}ms');
/// ```
class MssqlObservedSession with MssqlSession {
  const MssqlObservedSession(
    this.inner,
    this.observer, {
    this.observerOptions = const MssqlObserverOptions(),
    this.onObserverError,
  });

  final MssqlSession inner;
  final MssqlQueryObserver observer;
  final MssqlObserverOptions observerOptions;

  /// Where an observer exception goes instead of the caller's `catch`.
  ///
  /// Null uses `Zone.current.handleUncaughtError`, which is already not
  /// the statement's own error. A custom sink is for a logger that must
  /// not look like a failed DML.
  final MssqlDiagnosticSink? onObserverError;

  @override
  bool get inTransaction => inner.inTransaction;

  @override
  MssqlConnectionConfig get config => inner.config;

  @override
  String get currentDatabase => inner.currentDatabase;

  @override
  void invalidateMetadata({String? object}) =>
      inner.invalidateMetadata(object: object);

  @override
  Future<void> ping({MssqlCancellationToken? cancellationToken}) =>
      inner.ping(cancellationToken: cancellationToken);

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
  }) => _watch(
    sql,
    parameters,
    MssqlQueryKind.query,
    () => inner.query(
      sql,
      parameters: parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      retry: retry,
    ),
    rows: _rowsOf,
    affected: (result) => result.affectedRows,
    batchRows: batchRows ?? options.batchRows,
    queryName: options.queryName,
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
  }) => _watch(
    procedure,
    parameters,
    MssqlQueryKind.procedure,
    () => inner.callProcedure(
      procedure,
      parameters: parameters,
      outputParameters: outputParameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: batchRows,
      maximumRows: maximumRows,
      maximumBytes: maximumBytes,
      declared: declared,
      driftPolicy: driftPolicy,
    ),
    rows: _rowsOf,
    affected: (result) => result.affectedRows,
    batchRows: batchRows ?? options.batchRows,
    queryName: options.queryName,
  );

  /// Reported when the stream finishes, with the rows it actually yielded.
  ///
  /// Timing a stream at the call that creates it would report nothing; the
  /// interesting number is how long the consumer took to drain it.
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
  }) async* {
    final stopwatch = Stopwatch()..start();
    var rows = 0;
    try {
      await for (final event in inner.stream(
        sql,
        parameters: parameters,
        options: options,
        timeout: timeout,
        cancellationToken: cancellationToken,
        batchRows: batchRows,
        maximumRows: maximumRows,
        maximumBytes: maximumBytes,
      )) {
        if (event is MssqlRowBatch) rows += event.rows.length;
        yield event;
      }
    } catch (error) {
      stopwatch.stop();
      _report(
        MssqlQueryEvent(
          sql: sql,
          parameters: _visibleParameters(parameters),
          elapsed: stopwatch.elapsed,
          kind: MssqlQueryKind.stream,
          inTransaction: inner.inTransaction,
          rows: rows,
          failure: error,
          compileElapsed: _takeCompileElapsed(this),
          roundTrips: 1,
          batchRows: batchRows ?? options.batchRows,
          queryName: options.queryName,
        ),
      );
      rethrow;
    }
    stopwatch.stop();
    _report(
      MssqlQueryEvent(
        sql: sql,
        parameters: _visibleParameters(parameters),
        elapsed: stopwatch.elapsed,
        kind: MssqlQueryKind.stream,
        inTransaction: inner.inTransaction,
        rows: rows,
        compileElapsed: _takeCompileElapsed(this),
        roundTrips: 1,
        batchRows: batchRows ?? options.batchRows,
        queryName: options.queryName,
      ),
    );
  }

  @override
  Future<MssqlBulkResult> bulkInsert({
    required String tableName,
    required Iterable<Object> rows,
    Object? columns,
    MssqlBulkOptions options = const MssqlBulkOptions(),
    MssqlCancellationToken? cancellationToken,
    void Function(int sentRows)? onProgress,
  }) => _watch(
    'BULK INSERT $tableName',
    columns ?? tableName,
    MssqlQueryKind.bulkCopy,
    () => inner.bulkInsert(
      tableName: tableName,
      rows: rows,
      columns: columns,
      options: options,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    ),
    affected: (result) => result.insertedRows,
  );

  static int? _rowsOf(MssqlExecutionResult result) =>
      result.resultSets.isEmpty ? null : result.resultSets.first.rows.length;

  Future<T> _watch<T>(
    String sql,
    Object parameters,
    MssqlQueryKind kind,
    Future<T> Function() run, {
    int? Function(T result)? rows,
    int? Function(T result)? affected,
    int? batchRows,
    String? queryName,
  }) async {
    final stopwatch = Stopwatch()..start();
    final compileElapsed = _takeCompileElapsed(this);
    try {
      final result = await run();
      stopwatch.stop();
      _report(
        _eventFor(
          sql: sql,
          parameters: parameters,
          elapsed: stopwatch.elapsed,
          kind: kind,
          result: result,
          rows: rows?.call(result),
          affectedRows: affected?.call(result),
          compileElapsed: compileElapsed,
          batchRows: batchRows,
          queryName: queryName,
        ),
      );
      return result;
    } catch (error) {
      stopwatch.stop();
      _report(
        MssqlQueryEvent(
          sql: sql,
          parameters: _visibleParameters(parameters),
          elapsed: stopwatch.elapsed,
          kind: kind,
          inTransaction: inner.inTransaction,
          failure: error,
          compileElapsed: compileElapsed,
          roundTrips: 1,
          batchRows: batchRows,
          queryName: queryName,
        ),
      );
      rethrow;
    }
  }

  MssqlQueryEvent _eventFor<T>({
    required String sql,
    required Object parameters,
    required Duration elapsed,
    required MssqlQueryKind kind,
    required T result,
    required int? rows,
    required int? affectedRows,
    required Duration? compileElapsed,
    required int? batchRows,
    required String? queryName,
  }) {
    final metrics = result is MssqlExecutionResult ? result.metrics : null;
    // `rows` null means "this statement returned no result set", which is a
    // different answer from "it returned an empty one" — a DELETE and a
    // SELECT that matched nothing are not the same event. Falling back to
    // `metrics.rowCount` erased that distinction, because that field is a
    // non-nullable count of decoded rows and reads 0 for a statement with no
    // result set at all. So the fallback only applies when there *was* a
    // result set and no extractor was given for it.
    final decoded = metrics != null && metrics.resultSets.isNotEmpty
        ? metrics.rowCount
        : null;
    return MssqlQueryEvent(
      sql: sql,
      parameters: _visibleParameters(parameters),
      elapsed: elapsed,
      kind: kind,
      inTransaction: inner.inTransaction,
      rows: rows ?? decoded,
      affectedRows: affectedRows,
      compileElapsed: compileElapsed,
      queueWait: metrics?.queueWait,
      executionElapsed: metrics?.executionElapsed,
      decodedBytes: metrics?.decodedBytes,
      roundTrips: 1,
      batchRows: batchRows,
      queryName: queryName,
    );
  }

  Object _visibleParameters(Object parameters) => mssqlRedactParameters(
    parameters,
    includeValues: observerOptions.includeParameterValues,
  );

  void _report(MssqlQueryEvent event) {
    try {
      observer(event);
    } catch (error, stack) {
      // An observer that throws must not turn a statement that succeeded into
      // one the caller sees fail — the write already happened. It goes to a
      // diagnostic sink, not the caller's catch, so it cannot trip a retry.
      final sink = onObserverError;
      if (sink != null) {
        sink(error, stack);
      } else {
        Zone.current.handleUncaughtError(error, stack);
      }
    }
  }
}

/// Keeps the events, for a request-scoped or development-time report.
///
/// Bounded: [capacity] oldest events are dropped so a long-lived recorder
/// cannot grow without limit. Printing is left to whoever knows where the
/// output should go.
class MssqlQueryRecorder {
  MssqlQueryRecorder({this.capacity = 256}) {
    if (capacity < 1) {
      throw ArgumentError.value(
        capacity,
        'capacity',
        'A recorder with no room cannot keep an event.',
      );
    }
  }

  /// How many events are kept. Oldest are dropped when this is exceeded.
  final int capacity;

  final List<MssqlQueryEvent> events = <MssqlQueryEvent>[];

  void record(MssqlQueryEvent event) {
    events.add(event);
    while (events.length > capacity) {
      events.removeAt(0);
    }
  }

  void clear() => events.clear();

  int get count => events.length;

  Duration get elapsed =>
      events.fold(Duration.zero, (total, event) => total + event.elapsed);

  List<MssqlQueryEvent> get failures =>
      events.where((e) => e.failed).toList(growable: false);

  /// The statements that ran, one per line, longest first.
  String describe() {
    if (events.isEmpty) return 'No statements.';
    final sorted = <MssqlQueryEvent>[...events]
      ..sort((a, b) => b.elapsed.compareTo(a.elapsed));
    final buffer = StringBuffer(
      '$count statement(s), ${elapsed.inMilliseconds}ms total:\n',
    );
    for (final event in sorted) {
      buffer.writeln('  $event');
    }
    return buffer.toString();
  }
}

/// Bound parameters with secrets removed.
///
/// Names that look like passwords stay redacted even when [includeValues]
/// is true. A generated `toString` is a different surface — that one omits
/// hidden columns — but an observer log is the one that would otherwise
/// print `@password` next to the SQL.
Object mssqlRedactParameters(Object parameters, {bool includeValues = false}) {
  if (parameters is Map) {
    return <String, Object?>{
      for (final entry in parameters.entries)
        entry.key.toString(): _redactValue(
          entry.key.toString(),
          entry.value,
          includeValues: includeValues,
        ),
    };
  }
  if (parameters is Iterable) {
    return <Object?>[
      for (final value in parameters) includeValues ? value : '<redacted>',
    ];
  }
  return includeValues ? parameters : '<redacted>';
}

Object? _redactValue(
  String name,
  Object? value, {
  required bool includeValues,
}) {
  final folded = name.toLowerCase().replaceAll('_', '');
  if (folded.contains('password') ||
      folded == 'pwd' ||
      folded.contains('secret') ||
      folded.contains('token')) {
    return '<redacted>';
  }
  return includeValues ? value : '<redacted>';
}

extension MssqlObservedSessionExtension on MssqlSession {
  /// This session, reporting every statement to [observer].
  MssqlSession observedBy(
    MssqlQueryObserver observer, {
    MssqlObserverOptions options = const MssqlObserverOptions(),
    MssqlDiagnosticSink? onObserverError,
  }) => MssqlObservedSession(
    this,
    observer,
    observerOptions: options,
    onObserverError: onObserverError,
  );
}
