import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';

/// Shared dialect resolution for one server and one database.
///
/// Asking `SERVERPROPERTY` and `sys.databases` once per repository was a
/// round-trip per table getter. Two repositories of the same database — and
/// two callers that race — share one in-flight [Future] keyed by host, port
/// and the session's current database. A `USE` that changes the database is
/// a different key, not a stale answer. An explicit [invalidate] is the
/// answer after a reconnect or a compatibility-level change.
///
/// This is not a compilation cache of user SQL. Caching raw query text
/// would pin tenant values in a process-wide map with no bound.
class MssqlCapabilityCache {
  MssqlCapabilityCache();

  /// Process-wide cache used when a repository or context was not given one.
  ///
  /// AppDatabase holds its own so a test or a second server does not share
  /// with the first; passing [shared] is opt-in for callers that want one
  /// cache across databases constructed separately against the same server.
  static final MssqlCapabilityCache shared = MssqlCapabilityCache();

  final Map<String, Future<MssqlDialect>> _inflight =
      <String, Future<MssqlDialect>>{};

  /// Host, port and current database — not the login catalog, and not a
  /// connection identity. Two leases of the same database share; a `USE`
  /// does not.
  String keyFor(MssqlSession session) {
    final config = session.config;
    return '${config.host}:${config.port}/${session.currentDatabase}';
  }

  /// The dialect for [session], asking the server at most once per key.
  Future<MssqlDialect> resolve(MssqlSession session) {
    final key = keyFor(session);
    return _inflight.putIfAbsent(key, () => _query(session, key));
  }

  Future<MssqlDialect> _query(MssqlSession session, String key) async {
    try {
      final rows = await session.queryTypedRows(
        "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS [v], "
        'CAST((SELECT [compatibility_level] FROM [sys].[databases] '
        'WHERE [database_id] = DB_ID()) AS int) AS [c];',
        options: const MssqlQueryOptions(queryName: 'mssql_orm.dialect'),
      );
      if (rows.isEmpty) return MssqlDialect.sql2012;
      final row = rows.first;
      final version = row.at(0)?.toString() ?? '';
      final level = row.at(1);
      return MssqlDialect.forProductVersion(
        version,
        compatibilityLevel: level is num ? level.toInt() : null,
      );
    } catch (error) {
      // The removed value is the future this call is already failing out of,
      // so there is nothing left to wait for; the map only registers the
      // resolutions in flight, and dropping this one lets the next caller
      // ask the server again instead of re-awaiting a failure.
      // ignore: unawaited_futures
      _inflight.remove(key);
      rethrow;
    }
  }

  /// Drops a cached dialect so the next [resolve] asks the server again.
  ///
  /// [session] drops that server/database. Omitting it drops everything this
  /// cache holds — the right answer after a failover where product version
  /// or compatibility level may have changed.
  void invalidate({MssqlSession? session}) {
    if (session != null) {
      _inflight.remove(keyFor(session));
      return;
    }
    _inflight.clear();
  }
}
