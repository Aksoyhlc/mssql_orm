import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../query.dart';
import '../statement.dart';
import 'binding.dart';
import 'capability_cache.dart';
import 'observer.dart';
import 'query_context.dart';
import 'retry.dart';
import 'watch.dart';

/// The entry point for ORM access: holds a session and produces table queries.
///
/// Generated code extends this with lazy getters for each table —
/// `db.orders`, `db.customers` — that return immutable root queries bound to
/// the right [MssqlTableBinding]. The base class provides the session
/// lifecycle, transaction support, and the builder-execution seam.
///
/// [TSelf] is the generated class (`AppDatabase extends
/// MssqlAppDatabase`). The generic is the generated type itself, so
/// [transaction] hands the callback the same type that has `db.orders`.
///
/// Two construction modes:
///
/// * **Borrowed** — [owned] is false. [close] does nothing; the caller
///   closes the resource.
/// * **Owned** — [owned] is true, typically from generated `AppDatabase.open`.
///   [close] closes the connection — or the pool — once.
///
/// A pooled database keeps the pool itself, not only its convenience
/// session, because [transaction] has to hold one lease for the whole
/// callback.
abstract class MssqlAppDatabase<TSelf extends MssqlAppDatabase<TSelf>> {
  MssqlAppDatabase(
    MssqlSession session, {
    this.clock = MssqlClock.serverUtc,
    this.owned = false,
    this.pool,
    MssqlChangeHub? changes,
    MssqlCapabilityCache? capabilities,
    this.observer,
    this.observerOptions = const MssqlObserverOptions(),
  }) : _session = session,
       changes = changes ?? MssqlChangeHub(),
       capabilities = capabilities ?? MssqlCapabilityCache();

  /// Wraps a borrowed [MssqlConnection] the caller owns.
  ///
  /// Query-builder-only code that has no generated `AppDatabase` uses this.
  /// Generated databases expose their own `borrow`/`withPool`/`open` that
  /// return `TSelf`.
  static MssqlUntypedDatabase borrow(MssqlConnection connection) =>
      MssqlUntypedDatabase(connection);

  /// Wraps a borrowed [MssqlConnectionPool] the caller owns.
  ///
  /// Every single-statement read and write takes a lease and gives it back.
  /// The pool itself is kept, not just its convenience session, because
  /// [transaction] needs a connection it can hold for the whole callback —
  /// a session that hands out a different lease per statement cannot open
  /// one.
  static MssqlUntypedDatabase withPool(MssqlConnectionPool pool) =>
      MssqlUntypedDatabase(pool.session, pool: pool);

  /// Opens a connection from [config] and owns it.
  static Future<MssqlUntypedDatabase> open(MssqlConnectionConfig config) async {
    final connection = await MssqlConnection.open(config);
    return MssqlUntypedDatabase(connection, owned: true);
  }

  final MssqlSession _session;
  bool _closed = false;

  /// The session every table query reads and writes through.
  MssqlSession get session {
    if (_closed) {
      throw StateError('AppDatabase has been closed and is no longer usable.');
    }
    return _session;
  }

  /// The clock timestamp columns use, inherited by transaction contexts.
  final MssqlClock clock;

  /// The pool behind [session], when this database was built with
  /// [withPool].
  ///
  /// Null for a connection-backed database. [transaction] uses it to hold
  /// one lease for the whole callback; without it a pooled database could
  /// only run each statement on its own lease, which is not a transaction.
  final MssqlConnectionPool? pool;

  /// Whether [close] should close [session].
  ///
  /// True only for a database that opened its own connection. A transaction
  /// fork always passes `owned: false` — the outer database still owns the
  /// connection, and closing the fork would close the lease under the
  /// callback still running on it.
  final bool owned;

  /// Committed writes visible to [MssqlWatchStrategy.localWrites].
  ///
  /// Shared across [fork], so a transaction database notifies the same
  /// listeners as its parent, and only after COMMIT.
  final MssqlChangeHub changes;

  /// Dialect resolution shared by every table query of this database.
  ///
  /// Shared across [fork] so a transaction does not ask the server again,
  /// and so two repositories of the same database share the in-flight
  /// [Future].
  final MssqlCapabilityCache capabilities;

  /// ORM-level observer for compile / mapping / relation-load timings.
  final MssqlQueryObserver? observer;

  final MssqlObserverOptions observerOptions;

  /// Reconstructs this generated type over [session], keeping [clock].
  ///
  /// [transaction] uses this so the callback receives `AppDatabase` rather
  /// than a private sibling class it would have to cast.
  TSelf fork(MssqlSession session);

  /// Closes the owned resource, if any.
  ///
  /// A borrowed database does nothing here. An owned database closes what it
  /// opened — the connection, or the pool — once; calling again is a no-op.
  /// After [close], the database and every query derived from it are
  /// unusable.
  Future<void> close() async {
    if (!owned || _closed) return;
    _closed = true;
    final borrowed = pool;
    if (borrowed != null) {
      await borrowed.close();
      return;
    }
    final s = _session;
    if (s is MssqlConnection) {
      await s.close();
    }
  }

  /// Runs [action] inside a transaction, with a new [TSelf] over the
  /// transaction's session.
  ///
  /// Every table getter inside [action] sees the same transaction session, so
  /// a read and a write in the same callback go to the same physical lease.
  ///
  /// Three cases, and none of them silently runs [action] without a
  /// transaction:
  ///
  /// * A connection-backed database opens one on that connection.
  /// * A [withPool] database takes one lease and opens the transaction on
  ///   it, so the whole callback runs on one physical connection.
  /// * A database already forked over an [MssqlTransaction] nests through a
  ///   savepoint, so a failure inside [action] rolls back [action]'s writes
  ///   and leaves the outer transaction to its own scope.
  ///
  /// A session that is none of those — a bare [MssqlSession] implementation
  /// that cannot hold a lease — is refused rather than run unprotected.
  Future<R> transaction<R>(Future<R> Function(TSelf db) action) async {
    final s = session;
    if (s is MssqlTransaction) {
      // Nested: the inner scope is a savepoint of the open transaction, not
      // a second transaction and not an unprotected run. Rolling back to the
      // savepoint undoes [action] and nothing the caller did before it.
      return s.savepoint<R>(() => action(this as TSelf));
    }
    if (s is MssqlConnection) {
      return _openOn<R>(action, (callback) => s.transaction(callback));
    }
    final borrowed = pool;
    if (borrowed != null) {
      return _openOn<R>(action, (callback) => borrowed.transaction(callback));
    }
    throw StateError(
      'This AppDatabase runs on a session that cannot open a transaction: '
      '${s.runtimeType}. Build it with AppDatabase.borrow(connection), '
      'AppDatabase.withPool(pool) or AppDatabase.open(config). Running the '
      'callback without a transaction would look like it worked and leave '
      'every statement in it separately committed.',
    );
  }

  /// Shared body of the connection- and pool-backed transaction paths.
  ///
  /// The commit hub is notified only after the transaction returned, and the
  /// pending writes are discarded on any error, so a `watch(localWrites)`
  /// listener never sees a rolled-back write.
  Future<R> _openOn<R>(
    Future<R> Function(TSelf db) action,
    Future<R> Function(Future<R> Function(MssqlTransaction tx) callback) open,
  ) async {
    MssqlTransaction? tx;
    try {
      final result = await open((MssqlTransaction opened) async {
        tx = opened;
        return await action(fork(opened));
      });
      if (tx != null) changes.commitPending(tx!);
      return result;
    } catch (_) {
      if (tx != null) changes.discardPending(tx!);
      rethrow;
    }
  }

  /// Executes a built [MssqlSelectQuery] through this database's session.
  ///
  /// [dialect] defaults to whatever the server actually is, asked once and
  /// cached in [capabilities] — the same resolution the generated table
  /// queries use. Passing it explicitly pins the compilation, which is what
  /// a test or a cross-version snapshot wants.
  Future<List<MssqlRow>> query(
    MssqlSelectQuery query, {
    MssqlDialect? dialect,
    Duration? timeout,
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
  }) async {
    final statement = query.compile(dialect: dialect ?? await resolveDialect());
    return session.queryTypedRows(
      statement.sql,
      parameters: statement.parameters,
      options: options,
      timeout: timeout ?? options.timeout,
      cancellationToken: options.cancellationToken,
      retry: statement.readRetry,
    );
  }

  /// Executes a built [MssqlStatement] (INSERT/UPDATE/DELETE) and returns
  /// the affected row count.
  Future<int> execute(
    MssqlStatement statement, {
    Duration? timeout,
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
  }) => session.execute(
    statement.sql,
    parameters: statement.parameters,
    options: options,
    timeout: timeout ?? options.timeout,
    cancellationToken: options.cancellationToken,
  );

  /// What the server is, asked once per [capabilities] cache.
  ///
  /// The same resolution the generated table queries use, so a builder query
  /// run through [query] cannot compile 2012 paging against a database whose
  /// compatibility level refuses it.
  Future<MssqlDialect> resolveDialect() => capabilities.resolve(session);

  /// A [MssqlQueryContext] for the current session, for table queries that
  /// need one.
  ///
  /// Generated table queries call this to get their execution context. The
  /// dialect is resolved lazily — the first call asks the server, subsequent
  /// calls reuse the cached value.
  MssqlQueryContext<T> contextFor<T>(
    MssqlTableBinding<T> binding, {
    MssqlDialect? dialect,
  }) {
    return MssqlQueryContext<T>(
      session: session,
      binding: binding,
      dialect: dialect,
      clock: clock,
      changes: changes,
      capabilities: capabilities,
      observer: observer,
      observerOptions: observerOptions,
    );
  }
}

/// A database with no generated table getters, for query-builder-only use.
///
/// Generated `AppDatabase` is the type users with a schema actually construct.
/// This exists so [MssqlAppDatabase.borrow] / [MssqlAppDatabase.open] still
/// have a concrete type when no generator output is in the program.
final class MssqlUntypedDatabase
    extends MssqlAppDatabase<MssqlUntypedDatabase> {
  MssqlUntypedDatabase(
    super.session, {
    super.clock,
    super.owned,
    super.pool,
    super.changes,
    super.capabilities,
    super.observer,
    super.observerOptions,
  });

  @override
  MssqlUntypedDatabase fork(MssqlSession session) => MssqlUntypedDatabase(
    session,
    clock: clock,
    changes: changes,
    capabilities: capabilities,
    observer: observer,
    observerOptions: observerOptions,
  );
}
