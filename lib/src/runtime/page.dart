import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'exception.dart';
import 'observer.dart';

/// How a page and its optional count should see the database.
enum MssqlReadConsistency {
  /// Each statement sees whatever is committed when that statement runs.
  ///
  /// The default. A `COUNT(*)` after the page can disagree with the page
  /// when another session writes in between. `hasMore` does not need a
  /// count, so this is the cheap reading.
  committed,

  /// Page, count and includes share one `SNAPSHOT` transaction.
  ///
  /// The database must have `ALLOW_SNAPSHOT_ISOLATION` on. If it does
  /// not, the call fails rather than silently using read committed.
  snapshot,
}

/// One page of rows.
@immutable
class MssqlPage<TRow> {
  MssqlPage({
    required List<TRow> rows,
    required this.offset,
    required this.requestedRows,
    required this.hasMore,
    this.total,
  }) : rows = List<TRow>.unmodifiable(rows);

  final List<TRow> rows;
  final int offset;

  /// How many rows were asked for, which is not how many came back.
  final int requestedRows;

  /// Whether at least one row follows this page.
  ///
  /// Computed by fetching one row beyond the page and discarding it, so this
  /// is right even when [total] was not requested.
  final bool hasMore;

  /// Null unless `page(total: true)` asked for it.
  final int? total;

  bool get isEmpty => rows.isEmpty;
  bool get isNotEmpty => rows.isNotEmpty;

  @override
  String toString() =>
      'MssqlPage(${rows.length} rows at $offset'
      '${total == null ? '' : ' of $total'})';
}

/// Runs [body] under [consistency].
///
/// Snapshot isolation is requested of SQL Server as-is. A database that
/// does not allow it raises [MssqlCapabilityException]; this does not
/// retry at a weaker level.
Future<T> mssqlRunConsistent<T>({
  required MssqlSession session,
  required MssqlReadConsistency consistency,
  required Future<T> Function(MssqlSession session) body,
}) async {
  if (consistency != MssqlReadConsistency.snapshot) {
    return body(session);
  }
  if (session.inTransaction) {
    try {
      return await body(session);
    } on MssqlException catch (error) {
      throw _snapshotCapability(error);
    }
  }
  final inner = _unwrapSession(session);
  if (inner is MssqlConnection) {
    try {
      return await inner.transaction(
        (tx) => body(_rewrapSession(session, tx)),
        isolationLevel: MssqlIsolationLevel.snapshot,
      );
    } on MssqlException catch (error) {
      throw _snapshotCapability(error);
    }
  }
  throw StateError(
    'page(consistency: snapshot) needs a transaction, and this session '
    'cannot open one (a pooled handle is the usual case). Open a '
    'connection or an explicit SNAPSHOT transaction, then retry.',
  );
}

Never _snapshotCapability(MssqlException error) {
  final message = error.message.toLowerCase();
  final denied =
      error.code == 3952 ||
      error.code == 3954 ||
      message.contains('snapshot isolation is not allowed') ||
      message.contains('allow_snapshot_isolation');
  if (!denied) throw error;
  throw MssqlCapabilityException(
    feature: 'page(consistency: snapshot)',
    requires:
        'ALLOW_SNAPSHOT_ISOLATION ON for this database. ALTER DATABASE '
        '… SET ALLOW_SNAPSHOT_ISOLATION ON; there is no silent fallback '
        'to read committed',
    found: 'SQL Server error ${error.code}',
  );
}

MssqlSession _unwrapSession(MssqlSession session) {
  var current = session;
  while (current is MssqlObservedSession) {
    current = current.inner;
  }
  return current;
}

MssqlSession _rewrapSession(MssqlSession original, MssqlSession transaction) {
  final observers = <MssqlQueryObserver>[];
  var current = original;
  while (current is MssqlObservedSession) {
    observers.add(current.observer);
    current = current.inner;
  }
  var out = transaction;
  for (final observer in observers.reversed) {
    out = MssqlObservedSession(out, observer);
  }
  return out;
}
