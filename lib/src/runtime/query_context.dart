import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../expression.dart';
import '../query.dart';
import 'binding.dart';
import 'capability_cache.dart';
import 'observer.dart';
import 'scope.dart';
import 'watch.dart';

/// Which server clock the runtime uses for timestamp columns.
///
/// SQL Server offers both: `SYSUTCDATETIME()` returns UTC, `SYSDATETIME()`
/// returns the server's local time, and `SYSDATETIMEOFFSET()` carries the
/// offset. A `datetime2` column has no offset of its own, so the choice of
/// clock *is* the choice of timezone for every stamped row — and mixing two
/// clocks makes a `deleted_at` comparison between two rows meaningless.
///
/// The default is [serverUtc]: a single, unambiguous clock. [serverLocal] is
/// an explicit opt-in for applications whose server timezone is fixed and
/// whose existing data is already in local time.
@immutable
class MssqlClock {
  const MssqlClock._(this._sql, {this.isUtc = true});

  /// The server's UTC clock: `SYSUTCDATETIME()`.
  ///
  /// The default because UTC is the only clock that stays consistent when a
  /// server moves or a database is restored onto a machine in another
  /// timezone. A `datetime2` column stamped with UTC can be compared against
  /// any other UTC value without negotiation.
  static const MssqlClock serverUtc = MssqlClock._('SYSUTCDATETIME()');

  /// The server's local clock: `SYSDATETIME()`.
  ///
  /// Explicit opt-in. Use only when the server's timezone is fixed and
  /// existing data is already in local time; migrating old data from local
  /// to UTC is a data migration, not something the ORM can do by changing a
  /// flag.
  static const MssqlClock serverLocal = MssqlClock._(
    'SYSDATETIME()',
    isUtc: false,
  );

  /// The SQL text that produces the current timestamp.
  final String _sql;

  /// Whether this clock is UTC.
  final bool isUtc;

  /// The SQL expression to write into a `SET` or `VALUES` clause.
  MssqlExpression get expression => MssqlRaw(_sql);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MssqlClock && isUtc == other.isUtc;

  @override
  int get hashCode => isUtc.hashCode;

  @override
  String toString() =>
      isUtc ? 'MssqlClock.serverUtc' : 'MssqlClock.serverLocal';
}

/// Builds the [MssqlCondition] list a query carries for a given binding and
/// scope selection, **once**.
///
/// One place, used by every terminal — read, exists, count, write, include,
/// relation aggregate, through/pivot — so the same scopes apply the same way
/// everywhere. The soft-delete filter is separate from the named scopes
/// because [MssqlScopeSelection] keeps them separate.
///
/// An [MssqlScope] carries a *factory*: `MssqlCondition? Function()`, so a
/// tenant scope reads whatever the application's ambient tenant is at the
/// moment it runs. Calling that factory once per statement would let a
/// `page()` and its `total` count, or a read and its includes, land on two
/// different tenants across an `await` — the second half of a page would be
/// scoped to somebody else. So one instance of this class resolves each
/// factory exactly once and hands the same list out for every statement of
/// the operation that created it. **Create one per terminal call, not one
/// per statement, and never cache one on a long-lived object**: a
/// process-lifetime instance would freeze the first tenant it ever saw.
class MssqlScopeCompiler {
  MssqlScopeCompiler(this.binding, this.selection);

  final MssqlTableBinding<Object?> binding;
  final MssqlScopeSelection selection;

  List<MssqlCondition>? _read;
  List<MssqlCondition>? _global;

  /// Every predicate a read carries: the soft-delete filter and the scopes
  /// that are still on.
  ///
  /// Resolved on first use and then fixed for the life of this instance.
  List<MssqlCondition> get readConditions {
    final cached = _read;
    if (cached != null) return cached;
    final out = <MssqlCondition>[];
    final soft = binding.softDelete?.conditionFor(selection.trashed);
    if (soft != null) out.add(soft);
    out.addAll(globalConditions);
    return _read = List<MssqlCondition>.unmodifiable(out);
  }

  /// Every predicate *except* the soft-delete filter.
  ///
  /// Used by `forceDelete`, `restore` and `_softDelete`, which handle the
  /// soft-delete column themselves and must not have the alive/deleted filter
  /// applied a second time. Tenant and other global scopes still constrain
  /// them.
  ///
  /// Resolved on first use and then fixed, and the same resolution backs
  /// [readConditions], so the two can never disagree about the tenant.
  List<MssqlCondition> get globalConditions =>
      _global ??= List<MssqlCondition>.unmodifiable(_resolveScopes());

  List<MssqlCondition> _resolveScopes() {
    final out = <MssqlCondition>[];
    for (final scope in binding.scopes) {
      if (selection.isOff(scope.name)) continue;
      final condition = scope.build();
      if (condition != null) out.add(condition);
    }
    return out;
  }
}

/// Everything a terminal needs to execute a query against one table: the
/// session, the binding, the clock, the dialect and the observer.
///
/// The context is long-lived — a generated `db.orders` getter is cached, so
/// its context outlives any one query. What must *not* outlive one operation
/// is the scope resolution, because a tenant factory reads ambient state:
/// each terminal calls [scopeCompiler] once and threads that
/// [MssqlScopeCompiler] through every statement it runs, so `page` and its
/// `count`, and a read and its includes, cannot see two different tenants
/// across an `await`. The dialect *is* cached, in a shared
/// [MssqlCapabilityCache], because the server's version does not change
/// under the application.
@immutable
class MssqlQueryContext<TRow> {
  MssqlQueryContext({
    required this.session,
    required this.binding,
    MssqlDialect? dialect,
    this.clock = MssqlClock.serverUtc,
    this.changes,
    this.capabilities,
    this.observer,
    this.observerOptions = const MssqlObserverOptions(),
  }) : dialect = dialect ?? MssqlDialect.sql2012,
       _fixedDialect = dialect;

  final MssqlSession session;
  final MssqlTableBinding<TRow> binding;
  final MssqlDialect dialect;
  final MssqlClock clock;
  final MssqlDialect? _fixedDialect;

  /// The dialect this context was pinned to, or null when it asks the
  /// server.
  ///
  /// Exposed so a rebind — `at(schema:, table:)` — can carry the pin rather
  /// than turning a pinned context into a resolving one.
  MssqlDialect? get fixedDialect => _fixedDialect;

  /// Shared dialect resolution for this database, or the process-wide cache.
  final MssqlCapabilityCache? capabilities;

  /// Optional ORM-level observer for compile / mapping / relation-load.
  ///
  /// Session observers see each statement; this one sees one entity read
  /// after includes have run.
  final MssqlQueryObserver? observer;

  final MssqlObserverOptions observerOptions;

  /// Committed-write hub for [MssqlWatchStrategy.localWrites], or null when
  /// this context was not created by an [MssqlAppDatabase].
  final MssqlChangeHub? changes;

  /// The dialect of the current database, asking the server at most once.
  ///
  /// [dialect] is the compile-time default when the server has not been
  /// asked yet. Terminals await this so a 2008-compatible database does not
  /// receive `OFFSET … FETCH`.
  Future<MssqlDialect> resolveDialect() {
    final fixed = _fixedDialect;
    if (fixed != null) return Future<MssqlDialect>.value(fixed);
    return (capabilities ?? MssqlCapabilityCache.shared).resolve(session);
  }

  /// The same context on [session], so a snapshot transaction can run the
  /// page and its count without rebuilding bindings.
  MssqlQueryContext<TRow> withSession(MssqlSession session) =>
      MssqlQueryContext<TRow>(
        session: session,
        binding: binding,
        dialect: _fixedDialect,
        clock: clock,
        changes: changes,
        capabilities: capabilities,
        observer: observer,
        observerOptions: observerOptions,
      );

  /// A fresh scope snapshot for this context's binding.
  ///
  /// Created per call, never cached on the context: the context belongs to a
  /// generated table getter that is itself cached for the life of the
  /// database, so a cached snapshot would freeze the first tenant the
  /// process ever saw. A terminal calls this **once** and threads the result
  /// through every statement it runs — see [MssqlScopeCompiler].
  MssqlScopeCompiler scopeCompiler(MssqlScopeSelection selection) =>
      MssqlScopeCompiler(binding, selection);

  /// The base `SELECT` for this table, with scope conditions applied.
  ///
  /// [scopes] is the operation's snapshot. Pass it whenever the operation
  /// runs more than one statement — a page and its count, a read and its
  /// includes — so both halves are scoped to the same tenant. Omitting it
  /// takes a fresh snapshot, which is correct only for a single-statement
  /// call.
  MssqlQuery baseQuery(
    MssqlScopeSelection selection, {
    MssqlScopeCompiler? scopes,
  }) {
    var query = MssqlQuery.fromParts(
      binding.nameParts,
      ref: binding.sourceRef,
    ).select(binding.columns.map<MssqlExpression>((c) => Col(c.name)).toList());
    for (final condition
        in (scopes ?? scopeCompiler(selection)).readConditions) {
      query = query.where(condition);
    }
    return query;
  }

  /// A `SELECT` with no projection, only scope conditions — for `exists` and
  /// `count`, which do not need the full column list.
  ///
  /// [scopes] carries the operation's snapshot, as in [baseQuery].
  MssqlQuery scopedQuery(
    MssqlScopeSelection selection, {
    MssqlScopeCompiler? scopes,
  }) {
    var query = MssqlQuery.fromParts(binding.nameParts, ref: binding.sourceRef);
    for (final condition
        in (scopes ?? scopeCompiler(selection)).readConditions) {
      query = query.where(condition);
    }
    return query;
  }

  /// Global-scope-only query (no soft-delete filter), for `forceDelete`,
  /// `restore` and `_softDelete`.
  ///
  /// [scopes] carries the operation's snapshot, as in [baseQuery].
  MssqlQuery globalScopedQuery(
    MssqlScopeSelection selection, {
    MssqlScopeCompiler? scopes,
  }) {
    var query = MssqlQuery.fromParts(binding.nameParts, ref: binding.sourceRef);
    for (final condition
        in (scopes ?? scopeCompiler(selection)).globalConditions) {
      query = query.where(condition);
    }
    return query;
  }
}
