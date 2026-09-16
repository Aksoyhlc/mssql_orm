import 'dart:async';

import 'package:mssql_native/mssql_native.dart';

import '../cte.dart';
import '../dialect.dart';
import '../expression.dart';
import '../operators.dart';
import '../projection.dart';
import '../query.dart';
import '../statement.dart';
import '../subquery.dart';
import '../typed_column.dart';
import '../window.dart';
import 'binding.dart';
import 'bulk_write.dart';
import 'concurrency.dart';
import 'cursor.dart';
import 'exception.dart';
import 'graph_write.dart';
import 'observer.dart';
import 'page.dart';
import 'projected_query.dart';
import 'query_context.dart';
import 'query_state.dart';
import 'relation.dart';
import 'relation_filter.dart';
import 'relation_loader.dart';
import 'relation_write.dart';
import 'repository.dart';
import 'run_query.dart';
import 'scope.dart';
import 'watch.dart';
import 'write_commands.dart';

/// Abstract base for generated table queries, preserving the concrete query
/// type through every entity-preserving call.
///
/// `S` is the generated self type (`OrdersQuery extends MssqlEntityQuery<Order,
/// OrdersFields, OrdersQuery>`), so `where`, `orderBy`, `withTrashed` and every
/// other narrowing method return `S` rather than a widened base. IDE
/// completion sees the real type after each call, and a user extension
/// (`extension OrderScopes on OrdersQuery`) stays in the pipeline.
///
/// Generated code supplies the binding, the fields instance, `whereX`
/// equality shortcuts, and the `rebuild` that returns `S`. Terminals here
/// delegate to the same session and mapper the repository uses — a second
/// executor would drift.
abstract class MssqlEntityQuery<
  TRow,
  TFields,
  S extends MssqlEntityQuery<TRow, TFields, S>
> {
  MssqlEntityQuery(
    this.context, [
    this.state = const MssqlQueryState.empty(),
    List<MssqlRelation<TRow, Object?>> included = const [],
  ]) : included = List<MssqlRelation<TRow, Object?>>.unmodifiable(included);

  /// The execution context: session, binding, dialect, clock.
  final MssqlQueryContext<TRow> context;

  /// The immutable query state: scope selection, predicates, ordering.
  final MssqlQueryState state;

  /// Relations this query will load after the parent rows, in call order.
  ///
  /// Stored on the query rather than on [MssqlQueryState] because
  /// [MssqlRelation] is invariant in its parent type and a `List` of
  /// `MssqlRelation<Object?, Object?>` cannot hold `MssqlRelation<Order, …>`
  /// without a cast that fails at runtime.
  final List<MssqlRelation<TRow, Object?>> included;

  /// Typed SQL columns for callbacks, not a row and not a string lookup.
  ///
  /// Generated queries return `OrdersFields` so `where((o) => o.status.eq(…))`
  /// infers `o` and `eq`'s operand. A `Map<String, Column>` would throw away
  /// the type that makes `total.contains` a compile error.
  TFields get fields;

  /// The table binding shared with the repository.
  MssqlTableBinding<TRow> get binding => context.binding;

  /// The session shared with the repository.
  MssqlSession get session => context.session;

  /// The dialect this query compiles against.
  ///
  /// The compile-time default until a terminal asks the server. Use
  /// [_resolvedDialect] at execution so a 2008-compatible database does
  /// not receive `OFFSET … FETCH`.
  MssqlDialect get dialect => context.dialect;

  Future<MssqlDialect> _resolvedDialect() => context.resolveDialect();

  /// Rebuilds this query with new state, returning the same type `S`.
  ///
  /// Generated code overrides [recreate] so the concrete type and the
  /// include list survive every call. This default keeps includes.
  S rebuild(MssqlQueryState state) => recreate(state, included);

  /// Generated: `OrdersQuery(context, state, included)`.
  S recreate(
    MssqlQueryState state,
    List<MssqlRelation<TRow, Object?>> included,
  );

  /// Generated: `OrdersQuery(context, state, included)` over another
  /// [context].
  ///
  /// Separate from [recreate] because [recreate] reuses the captured
  /// context, and rebinding the table needs a new one. Only [at] calls it.
  S recreateAt(
    MssqlQueryContext<TRow> context,
    MssqlQueryState state,
    List<MssqlRelation<TRow, Object?>> included,
  );

  /// This query over another schema or table name.
  ///
  /// What a tenant-per-schema deployment needs: the same generated types
  /// pointed at `tenant2.Orders`. The binding is rebound and the fields
  /// resolve against the new source, so a predicate written after this call
  /// compiles to `[tenant2].[Orders].[Col]` rather than to the table the
  /// code was generated from.
  ///
  /// Relation *targets* are not moved. A foreign key names one table, and
  /// assuming every related table lives in the same tenant schema would be
  /// a guess about the deployment; call [at] on the related query too, or
  /// generate against the schema you mean.
  ///
  /// Refused once the query carries predicates, ordering or includes: those
  /// were built from the old source and would silently name a table this
  /// statement does not have. Rebind first, then narrow.
  S at({String? schema, String? table}) {
    if (schema == null && table == null) return _self;
    if (state.where.isNotEmpty ||
        state.orderBy.isNotEmpty ||
        state.ctes.isNotEmpty ||
        included.isNotEmpty) {
      throw StateError(
        'at(schema:, table:) has to come before where / orderBy / include '
        'on ${binding.qualifiedName}. Those were built from this table\'s '
        'columns and would still name it after the rebind, so the '
        'statement would refer to a source it does not have. Start the '
        'chain with at(...).',
      );
    }
    final rebound = binding.forTable(schema: schema, table: table);
    return recreateAt(
      MssqlQueryContext<TRow>(
        session: context.session,
        binding: rebound,
        dialect: context.fixedDialect,
        clock: context.clock,
        changes: context.changes,
        capabilities: context.capabilities,
        observer: context.observer,
        observerOptions: context.observerOptions,
      ),
      state,
      included,
    );
  }

  /// Loads [relations] after the parent rows, merging same paths.
  ///
  /// Conflicting filter, order, limit or strategy on one path is
  /// [MssqlIncludeConflictException]. Nested includes are recursive; a
  /// level is never skipped. Page sentinels must be dropped before this runs;
  /// see [dropPageSentinel].
  S include(
    Iterable<MssqlRelation<TRow, Object?>> Function(TFields fields) relations,
  ) {
    final extra = List<MssqlRelation<TRow, Object?>>.of(relations(fields));
    return recreate(state, mergeIncludes<TRow>(included, extra));
  }

  /// Keeps parents that have at least one matching related row.
  ///
  /// Correlated `EXISTS`, not a join: a customer with ten orders is still
  /// one customer. The handle's `where`/`withTrashed`/`then` filters are the
  /// same snapshot `include` would load.
  S whereHas<TChild>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
  ) {
    final rel = relation(fields);
    return where((_) => MssqlExistsSubquery(_existsQuery(rel), negated: false));
  }

  /// Keeps parents that have no matching related row.
  S whereDoesntHave<TChild>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
  ) {
    final rel = relation(fields);
    return where((_) => MssqlExistsSubquery(_existsQuery(rel), negated: true));
  }

  /// `whereHas` and `include` of the same handle, so the loaded children
  /// are the ones the filter named.
  S withWhereHas<TChild>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
  ) {
    final rel = relation(fields);
    return include(
      (_) => <MssqlRelation<TRow, Object?>>[rel.asInclude],
    ).whereHas((_) => rel);
  }

  /// Writes against one relation of [parent].
  ///
  /// Generated queries also expose `ordersOf(parent)` so the relation name
  /// is a completed member rather than a callback. The runtime object is
  /// the same either way.
  MssqlRelationMutation<TRow, TChild> related<TChild>(
    TRow parent,
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
  ) => MssqlRelationMutation<TRow, TChild>(
    session: session,
    dialect: dialect,
    clock: context.clock,
    parentBinding: binding,
    parent: parent,
    relation: relation(fields),
    scope: state.scope,
    changes: context.changes,
  );

  /// Parent rows plus a count of matching children, as a projection.
  ///
  /// Not a field on the entity: a count is not a column of the table, and
  /// stuffing it onto the row would make `fromRow` and equality lie.
  /// Default is `COUNT_BIG` so a busy relation cannot overflow `int`
  /// (error 8115). Pass `big: false` only when the count is known to fit
  /// in 32 bits.
  MssqlProjectedQuery<(TRow, int)> withCount<TChild>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation, {
    bool big = true,
  }) {
    return _withAggregate(
      relation,
      big ? MssqlAggregate.countBig(raw('*')) : MssqlAggregate.count(raw('*')),
      (value) => value == null ? 0 : (value as num).toInt(),
    );
  }

  /// Parent rows plus whether any matching child exists, as a `bit`.
  MssqlProjectedQuery<(TRow, bool)> withExists<TChild>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
  ) {
    final rel = relation(fields);
    final expr = existsValue(_existsQuery(rel));
    return _projectAdded(
      'withExists',
      expr,
      (value) => value == true || value == 1,
    );
  }

  /// Parent rows plus `SUM` of [operand] on matching children.
  ///
  /// [V] is the Dart type the operand's SQL type decodes to, and it is
  /// unbounded: a `V extends num` bound would exclude [MssqlDecimal] and so
  /// force the sum of a `decimal` or `money` column through `double`, which
  /// is the rounding exact decimal exists to prevent. So write
  /// `withSum<OrderLine, MssqlDecimal>(…)` for an exact column and
  /// `withSum<OrderLine, int>(…)` for an integer one. A [V] the value cannot
  /// become is a located error naming the aggregate, not a silent cast.
  ///
  /// An empty match is SQL NULL, not zero — "the sum of no rows" has no
  /// value — so the result is `V?`.
  MssqlProjectedQuery<(TRow, V?)> withSum<TChild, V>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
    MssqlExpression operand,
  ) {
    return _withAggregate(
      relation,
      MssqlAggregate.sum(operand),
      (v) => _decodeAggregate<V>('withSum', v),
    );
  }

  /// Parent rows plus an exact `AVG` of [operand] on matching children.
  ///
  /// `AVG` of an integer column is integer division in SQL Server, so this
  /// method casts to `decimal(38, exactScale)` first and hands back an
  /// [MssqlDecimal]. Which method you call is what answers the
  /// integer-division question — a flag whose result type the caller cannot
  /// see would not.
  MssqlProjectedQuery<(TRow, MssqlDecimal?)> withAvgExact<TChild>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
    MssqlExpression operand, {
    int exactScale = 6,
  }) {
    return _withAggregate(
      relation,
      MssqlAggregate.avg(
        operand,
        integers: MssqlIntegerAverage.exactDecimal,
        exactScale: exactScale,
      ),
      (v) => _decodeAggregate<MssqlDecimal>('withAvgExact', v),
    );
  }

  /// Parent rows plus `AVG` of [operand] with SQL Server's own integer
  /// rule kept: the remainder of an integer column is discarded.
  ///
  /// For a whole-unit average where the fraction is noise. Use
  /// [withAvgExact] when it is not.
  MssqlProjectedQuery<(TRow, V?)> withAvgTruncating<TChild, V>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
    MssqlExpression operand,
  ) {
    return _withAggregate(
      relation,
      MssqlAggregate.avg(operand, integers: MssqlIntegerAverage.truncating),
      (v) => _decodeAggregate<V>('withAvgTruncating', v),
    );
  }

  /// Parent rows plus `MIN` of [operand] on matching children.
  ///
  /// `MIN` keeps the operand's SQL type exactly, so [V] is the operand
  /// column's own Dart type. See [withSum] on why it is unbounded.
  MssqlProjectedQuery<(TRow, V?)> withMin<TChild, V>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
    MssqlExpression operand,
  ) {
    return _withAggregate(
      relation,
      MssqlAggregate.min(operand),
      (v) => _decodeAggregate<V>('withMin', v),
    );
  }

  /// Parent rows plus `MAX` of [operand] on matching children.
  ///
  /// `MAX` keeps the operand's SQL type exactly, so [V] is the operand
  /// column's own Dart type. See [withSum] on why it is unbounded.
  MssqlProjectedQuery<(TRow, V?)> withMax<TChild, V>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
    MssqlExpression operand,
  ) {
    return _withAggregate(
      relation,
      MssqlAggregate.max(operand),
      (v) => _decodeAggregate<V>('withMax', v),
    );
  }

  /// Decodes one aggregate value to [V], or says why it cannot.
  ///
  /// Only the widening SQL Server itself performs is applied — a `num` to
  /// `int` or `double` — and nothing else. In particular an [MssqlDecimal]
  /// is never turned into a `double` here: that conversion is lossy and has
  /// to be asked for by name.
  static V? _decodeAggregate<V>(String operation, Object? value) {
    if (value == null) return null;
    if (value is V) return value as V;
    if (value is num && V == int) return value.toInt() as V;
    if (value is num && V == double) return value.toDouble() as V;
    throw StateError(
      '$operation came back as ${value.runtimeType}, which is not $V. An '
      'exact column arrives as MssqlDecimal under MssqlDecimalMode.exact '
      'and as String under MssqlDecimalMode.text; name the type the '
      'connection decodes rather than one it would have to round to.',
    );
  }

  /// Several independent correlated aggregates on one parent SELECT.
  ///
  /// Each spec is its own subquery. Putting orders and lines in one join
  /// would make the order count equal the line count; this method will not.
  MssqlProjectedQuery<(TRow, Map<String, Object?>)> withAggregates(
    List<MssqlRelationAggregate<TRow>> Function(TFields fields) aggregates,
  ) {
    final specs = aggregates(fields);
    if (specs.isEmpty) {
      throw ArgumentError.value(
        specs,
        'aggregates',
        'withAggregates needs at least one relation aggregate.',
      );
    }
    final seen = <String>{};
    final extras = <MssqlProjectionColumn>[];
    for (final spec in specs) {
      final folded = spec.alias.toLowerCase();
      if (!seen.add(folded)) {
        throw ArgumentError.value(
          spec.alias,
          'aggregates',
          'withAggregates has two columns named "${spec.alias}".',
        );
      }
      extras.add(
        MssqlProjectionColumn(
          spec.alias,
          MssqlScalarSubquery(
            _existsQuery(spec.relation, projection: spec.expression),
          ),
        ),
      );
    }
    return select(
      MssqlProjection<(TRow, Map<String, Object?>)>(
        name: 'withAggregates',
        columns: <MssqlProjectionColumn>[
          for (final column in binding.columns)
            MssqlProjectionColumn(column.name, Col(column.name)),
          ...extras,
        ],
        map: (row) {
          final values = <String, Object?>{};
          for (var i = 0; i < extras.length; i++) {
            values[extras[i].alias] = row.at(binding.columns.length + i);
          }
          return (binding.fromRow(row), values);
        },
      ),
    );
  }

  MssqlProjectedQuery<(TRow, T)> _withAggregate<T, TChild>(
    MssqlRelation<TRow, TChild> Function(TFields fields) relation,
    MssqlExpression aggregate,
    T Function(Object? value) read,
  ) {
    final rel = relation(fields);
    final expr = MssqlScalarSubquery(_existsQuery(rel, projection: aggregate));
    return _projectAdded('withAggregate', expr, read);
  }

  MssqlProjectedQuery<(TRow, T)> _projectAdded<T>(
    String name,
    MssqlExpression extra,
    T Function(Object? value) read,
  ) {
    return select(
      MssqlProjection<(TRow, T)>(
        name: name,
        columns: <MssqlProjectionColumn>[
          for (final column in binding.columns)
            MssqlProjectionColumn(column.name, Col(column.name)),
          MssqlProjectionColumn('__rel_agg', extra),
        ],
        map: (row) =>
            (binding.fromRow(row), read(row.at(binding.columns.length))),
      ),
    );
  }

  MssqlQuery _existsQuery<TChild>(
    MssqlRelation<TRow, TChild> relation, {
    MssqlExpression? projection,
  }) => relationExistsQuery(
    relation,
    parent: binding,
    session: session,
    dialect: dialect,
    projection: projection,
  );

  // Writes

  /// Inserts [create], or returns the live row that already owns [key].
  ///
  /// Generated `getOrCreateByCode` is the usual call. This is the typed
  /// unique-key path; [MssqlRepository.firstOrCreate] is the predicate
  /// form and is not race-safe on its own.
  Future<TRow> getOrCreate({
    required MssqlUniqueMatch key,
    required MssqlWriteAssignments create,
    bool restoreExisting = false,
    bool includeDeleted = false,
  }) => _repository().getOrCreate(
    key: key,
    create: create,
    restoreExisting: restoreExisting,
    includeDeleted: includeDeleted,
  );

  /// Writes [patch] to every row this query currently matches.
  ///
  /// Patch is the main write: absent fields are not named. A full-row
  /// [MssqlRepository.update] is the unguarded alternative.
  /// [expectedVersion] requires a rowversion column.
  Future<int> updateValues(
    MssqlWriteAssignments patch, {
    Object? expectedVersion,
    int? expectAffected,
  }) => _repository().updateMatching(
    state.where,
    patch,
    expectedVersion: expectedVersion,
    expectAffected: expectAffected,
  );

  /// Inserts [values] and returns the stored row.
  ///
  /// Generated `create(OrderCreate)` is the usual call. Absent Create
  /// fields become SQL `DEFAULT`, which binding null would overwrite.
  Future<TRow> createValues(MssqlWriteAssignments values) =>
      _repository().insertAssignments(values);

  /// Batched insert of [rows]. Atomic by default; never switches to BCP.
  ///
  /// [strategy] is the caller's choice. Mapped stored rows need a key or
  /// identity; BCP refuses `returnRows: true`.
  Future<MssqlCreateManyResult<TRow>> createManyValues(
    List<MssqlWriteAssignments> rows, {
    MssqlCreateManyStrategy strategy = MssqlCreateManyStrategy.insertValues,
    MssqlBulkOptions bulk = const MssqlBulkOptions(),
    bool atomic = true,
    bool returnRows = true,
  }) async {
    final dialect = await _resolvedDialect();
    return _bulkWriter(dialect).createMany(
      rows,
      strategy: strategy,
      bulk: bulk,
      atomic: atomic,
      returnRows: returnRows,
    );
  }

  /// Staging JOIN update of [patches] by their keys.
  ///
  /// Carries this query's scope predicates, so a keyed batch update reaches
  /// exactly the rows a single-row `update()` on the same query would: not
  /// another tenant's, and not a soft-deleted one unless `withTrashed()`
  /// asked for it.
  Future<int> updateManyKeyed(
    List<MssqlKeyedPatch> patches, {
    int? expectAffected,
  }) async {
    final dialect = await _resolvedDialect();
    return _bulkWriter(
      dialect,
    ).updateMany(patches, expectAffected: expectAffected);
  }

  /// Groups [requests] by [keyColumn] and subtracts in one guarded UPDATE.
  Future<int> decrementQuantities({
    required String keyColumn,
    required String quantityColumn,
    required Iterable<({Object key, num amount})> requests,
  }) async {
    final dialect = await _resolvedDialect();
    return _bulkWriter(dialect).decrementQuantities(
      keyColumn: keyColumn,
      quantityColumn: quantityColumn,
      requests: requests,
    );
  }

  /// Explicit graph insert of [graph] in one transaction.
  ///
  /// Only listed relations are written. There is no cascade delete and no
  /// silent overwrite of existing counterparts.
  ///
  /// Scope predicates are not applied. A graph insert has no `WHERE` to filter,
  /// and the only read — the readback of the row just written — could hide that
  /// row rather than protect anything. A tenant column on a new row must be
  /// written, so it belongs in the Create values.
  Future<TRow> createGraphValues(
    MssqlGraphInsert<TRow> graph, {
    MssqlCycleWrite cycle = MssqlCycleWrite.refuse,
  }) async {
    final dialect = await _resolvedDialect();
    return MssqlGraphWriter<TRow>(
      session,
      binding: binding,
      dialect: dialect,
      clock: context.clock,
      changes: context.changes,
    ).createGraph(graph, cycle: cycle);
  }

  /// The batch writer for one call, carrying this query's scope snapshot.
  ///
  /// The snapshot is taken here, once per call, so every statement of a
  /// multi-batch write is filtered by the same tenant — see
  /// [MssqlScopeCompiler].
  MssqlBulkWriter<TRow> _bulkWriter(MssqlDialect dialect) =>
      MssqlBulkWriter<TRow>(
        session,
        binding: binding,
        dialect: dialect,
        clock: context.clock,
        changes: context.changes,
        scopes: context.scopeCompiler(state.scope).readConditions,
      );

  MssqlRepository<TRow, Never> _repository() => MssqlRepository<TRow, Never>(
    session,
    binding: binding,
    scope: state.scope,
    clock: context.clock,
    changes: context.changes,
    capabilities: context.capabilities,
    options: state.options,
  );

  // Narrowing

  /// Adds a predicate built from [fields], ANDed with those already present.
  ///
  /// OR stays inside the callback (`o.status.eq(a) | o.status.eq(b)`). A
  /// generated `whereXOrY` family would explode the API and still could not
  /// express grouped disjunction.
  S where(MssqlCondition Function(TFields fields) predicate) =>
      rebuild(state.where_(predicate(fields)));

  /// Adds [predicate] only when [test] is true.
  ///
  /// The callback is not invoked on the false branch, so a UI filter that
  /// is off does not accidentally widen a write.
  S whereIf(bool test, MssqlCondition Function(TFields fields) predicate) {
    if (!test) return _self;
    return where(predicate);
  }

  /// Adds [predicate] only when [value] is not null.
  ///
  /// The callback is not invoked for null, so `whereIfNotNull(id, …)` is
  /// safe in a search form where an empty box means "no filter".
  S whereIfNotNull<V>(
    V? value,
    MssqlCondition Function(TFields fields, V value) predicate,
  ) {
    if (value == null) return _self;
    return where((f) => predicate(f, value));
  }

  /// Adds [predicate] only when [values] is not empty.
  ///
  /// An empty IN is invalid SQL and must not silently become "match nothing"
  /// or "match everything". Skipping the callback is the intended reading of
  /// an empty filter.
  S whereInIfNotEmpty<V>(
    Iterable<V> values,
    MssqlCondition Function(TFields fields, List<V> values) predicate,
  ) {
    final list = List<V>.of(values);
    if (list.isEmpty) return _self;
    return where((f) => predicate(f, list));
  }

  /// Rebuilds this query through [build] only when [test] is true.
  S when(bool test, S Function(S query) build) {
    if (!test) return _self;
    return build(_self);
  }

  /// Adds a text search over [columns] when [term] has a non-whitespace
  /// character.
  ///
  /// Null, empty, and whitespace-only terms add no filter and do not call
  /// [columns]. A term that has content is used as typed — it is not
  /// trimmed — so a leading space the user entered is a leading space in
  /// SQL. `%`, `_` and `[` in the term are escaped by [MssqlLike]; they
  /// never become wildcards.
  ///
  /// [columns] must return [MssqlTextExpression]s. A numeric column is not
  /// cast to text here: that would hide `total.contains` the typed columns
  /// exist to forbid. Related to-one columns belong on [TFields] once
  /// relation joins are generated; this method does not invent aliases.
  S search(
    String? term,
    List<MssqlTextExpression> Function(TFields fields) columns, {
    MssqlLikePosition position = MssqlLikePosition.anywhere,
  }) {
    if (term == null || term.trim().isEmpty) return _self;
    final exprs = columns(fields);
    if (exprs.isEmpty) {
      throw ArgumentError.value(
        exprs,
        'columns',
        'search needs at least one text column.',
      );
    }
    MssqlCondition match(MssqlTextExpression expression) => switch (position) {
      MssqlLikePosition.anywhere => expression.contains(term),
      MssqlLikePosition.starting => expression.startsWith(term),
      MssqlLikePosition.ending => expression.endsWith(term),
      MssqlLikePosition.exact => expression.like(term),
    };
    if (exprs.length == 1) return where((_) => match(exprs.first));
    return where((_) => or(exprs.map(match)));
  }

  /// Replaces the ordering from a fields callback.
  ///
  /// `orderBy((o) => [o.placedAt.desc(), o.id.desc()])` is the form. A
  /// parallel `orderByColumn` family is not added.
  S orderBy(List<MssqlOrder> Function(TFields fields) ordering) =>
      rebuild(state.withOrderBy(ordering(fields)));

  /// Appends ordering, keeping what is already there.
  S thenBy(List<MssqlOrder> Function(TFields fields) ordering) =>
      rebuild(state.thenBy(ordering(fields)));

  /// Replaces the native execution options.
  S options(MssqlQueryOptions options) => rebuild(state.withOptions(options));

  /// Declares [cte] on this query's statement.
  ///
  /// Needed because SQL Server allows `WITH` only at the start of a
  /// statement, so a recursive walk cannot live inside `IN (…)`. Declaring
  /// it here and filtering on its columns keeps the result an ordinary
  /// query: scopes, ordering, includes and paging are applied by the same
  /// code as for every other query. Generated `descendantsOf` is the
  /// intended caller.
  S withTypedCte(MssqlTypedCte cte) => rebuild(state.withCte(cte));

  // Scope switches

  S withTrashed() => rebuild(state.withTrashed());
  S onlyTrashed() => rebuild(state.onlyTrashed());
  S withoutTrashed() => rebuild(state.withoutTrashed());
  S withoutScope(String name) => rebuild(state.withoutScope(name));

  S withoutGlobalScopes() => rebuild(state.withoutGlobalScopes(binding.scopes));

  /// The scope selection this query currently carries.
  MssqlScopeSelection get scopeSelection => state.scope;

  S get _self => this as S;

  /// `page` / `chunk` / `cursorPage`: used when the caller gave none, and as a
  /// tie-breaker when they gave some.
  ///
  /// A keyless table cannot invent an order — the generic builder will not
  /// guess a unique key it does not have.
  S ensureStableOrder() {
    if (!binding.hasPrimaryKey) {
      if (state.orderBy.isEmpty) {
        throw StateError(
          '${binding.qualifiedName} has no primary key, so a page needs an '
          'explicit unique orderBy. The generic builder will not guess one.',
        );
      }
      return _self;
    }
    if (state.orderBy.isEmpty) {
      return rebuild(
        state.withOrderBy(<MssqlOrder>[
          for (final name in binding.primaryKey) Col(name).asc(),
        ]),
      );
    }
    // Append only the key columns the caller's ordering does not already
    // name. `orderBy((o) => [o.id.desc()])` must not become
    // `ORDER BY [Id] DESC, [Id] ASC`: the second term is unreachable, so the
    // ordering would claim a tie-break it does not have, and cursorPage
    // builds its keyset predicate from this list term by term — the same
    // column twice with opposite directions gives `[Id] < @a AND … [Id] >
    // @a`, which matches no row at all.
    return rebuild(
      state.withOrderBy(
        mssqlWithKeyTieBreak(state.orderBy, binding.primaryKey),
      ),
    );
  }

  // Terminals

  /// Every matching row. There is no hidden limit.
  Future<List<TRow>> get() async {
    final dialect = await _resolvedDialect();
    final scopes = context.scopeCompiler(state.scope);
    final loader = _loaderFor(session, dialect);
    final mappingWatch = Stopwatch()..start();
    final rows = await _select(scopes: scopes).get(
      session,
      dialect: dialect,
      timeout: state.options.timeout,
      cancellationToken: state.options.cancellationToken,
      options: state.options,
    );
    final mapped = rows.map(binding.fromRow).toList(growable: false);
    mappingWatch.stop();
    final relationWatch = Stopwatch()..start();
    final attached = await _attachOn(
      session,
      mapped,
      dialect: dialect,
      loader: loader,
    );
    relationWatch.stop();
    _notifyRead(
      rowCount: attached.length,
      mappingElapsed: mappingWatch.elapsed,
      relationLoadElapsed: relationWatch.elapsed,
    );
    return attached;
  }

  /// The first matching row in the requested order, or null.
  Future<TRow?> first() async {
    final dialect = await _resolvedDialect();
    final scopes = context.scopeCompiler(state.scope);
    final loader = _loaderFor(session, dialect);
    final row = await _select(scopes: scopes).first(
      session,
      dialect: dialect,
      timeout: state.options.timeout,
      cancellationToken: state.options.cancellationToken,
      options: state.options,
    );
    if (row == null) return null;
    final attached = await _attachOn(
      session,
      <TRow>[binding.fromRow(row)],
      dialect: dialect,
      loader: loader,
    );
    return attached.single;
  }

  /// The first matching row, or [MssqlRowNotFoundException].
  Future<TRow> firstOrFail() async {
    final row = await first();
    if (row == null) {
      throw MssqlRowNotFoundException(binding.qualifiedName, null);
    }
    return row;
  }

  /// Exactly one matching row.
  ///
  /// Zero rows is [MssqlRowNotFoundException]; two or more is
  /// [MssqlCardinalityException]. `first()` is the ordered "take one"
  /// reading; this one is a uniqueness assertion.
  Future<TRow> single() async {
    final dialect = await _resolvedDialect();
    final scopes = context.scopeCompiler(state.scope);
    final loader = _loaderFor(session, dialect);
    final rows = await _probeTwo(dialect: dialect, scopes: scopes);
    if (rows.isEmpty) {
      throw MssqlRowNotFoundException(binding.qualifiedName, null);
    }
    if (rows.length > 1) {
      throw MssqlCardinalityException(binding.qualifiedName, 'single', 2);
    }
    return (await _attachOn(
      session,
      <TRow>[binding.fromRow(rows.first)],
      dialect: dialect,
      loader: loader,
    )).single;
  }

  /// At most one matching row, or null when none match.
  Future<TRow?> singleOrNull() async {
    final dialect = await _resolvedDialect();
    final scopes = context.scopeCompiler(state.scope);
    final loader = _loaderFor(session, dialect);
    final rows = await _probeTwo(dialect: dialect, scopes: scopes);
    if (rows.isEmpty) return null;
    if (rows.length > 1) {
      throw MssqlCardinalityException(binding.qualifiedName, 'singleOrNull', 2);
    }
    return (await _attachOn(
      session,
      <TRow>[binding.fromRow(rows.first)],
      dialect: dialect,
      loader: loader,
    )).single;
  }

  /// Projects this query through [projection], dropping entity writes.
  MssqlProjectedQuery<R> select<R>(MssqlProjection<R> projection) =>
      MssqlProjectedQuery<R>(
        session: session,
        dialect: dialect,
        projection: projection,
        timeout: state.options.timeout,
        options: state.options,
        capabilities: context.capabilities,
        build: _projected,
      );

  /// Two typed columns as a Dart record `(A, B)`.
  ///
  /// Named record shapes are generated DTOs; Dart will not map an arbitrary
  /// named record through a single generic.
  MssqlProjectedQuery<(A, B)> select2<A, B>(
    (MssqlExpression, MssqlExpression) Function(TFields fields) select,
  ) {
    final pair = select(fields);
    return this.select(
      MssqlProjection<(A, B)>(
        name: 'select2',
        columns: <MssqlProjectionColumn>[
          MssqlProjectionColumn('c0', pair.$1),
          MssqlProjectionColumn('c1', pair.$2),
        ],
        map: (row) => (
          MssqlProjection.decode<A>(
            row,
            0,
            projection: 'select2',
            column: 'c0',
            expression: pair.$1,
          ),
          MssqlProjection.decode<B>(
            row,
            1,
            projection: 'select2',
            column: 'c1',
            expression: pair.$2,
          ),
        ),
      ),
    );
  }

  /// Three typed columns as a Dart record `(A, B, C)`.
  MssqlProjectedQuery<(A, B, C)> select3<A, B, C>(
    (MssqlExpression, MssqlExpression, MssqlExpression) Function(TFields fields)
    select,
  ) {
    final t = select(fields);
    return this.select(
      MssqlProjection<(A, B, C)>(
        name: 'select3',
        columns: <MssqlProjectionColumn>[
          MssqlProjectionColumn('c0', t.$1),
          MssqlProjectionColumn('c1', t.$2),
          MssqlProjectionColumn('c2', t.$3),
        ],
        map: (row) => (
          MssqlProjection.decode<A>(
            row,
            0,
            projection: 'select3',
            column: 'c0',
            expression: t.$1,
          ),
          MssqlProjection.decode<B>(
            row,
            1,
            projection: 'select3',
            column: 'c1',
            expression: t.$2,
          ),
          MssqlProjection.decode<C>(
            row,
            2,
            projection: 'select3',
            column: 'c2',
            expression: t.$3,
          ),
        ),
      ),
    );
  }

  /// Four typed columns as a Dart record `(A, B, C, D)`.
  MssqlProjectedQuery<(A, B, C, D)> select4<A, B, C, D>(
    (MssqlExpression, MssqlExpression, MssqlExpression, MssqlExpression)
    Function(TFields fields)
    select,
  ) {
    final t = select(fields);
    return this.select(
      MssqlProjection<(A, B, C, D)>(
        name: 'select4',
        columns: <MssqlProjectionColumn>[
          MssqlProjectionColumn('c0', t.$1),
          MssqlProjectionColumn('c1', t.$2),
          MssqlProjectionColumn('c2', t.$3),
          MssqlProjectionColumn('c3', t.$4),
        ],
        map: (row) => (
          MssqlProjection.decode<A>(
            row,
            0,
            projection: 'select4',
            column: 'c0',
            expression: t.$1,
          ),
          MssqlProjection.decode<B>(
            row,
            1,
            projection: 'select4',
            column: 'c1',
            expression: t.$2,
          ),
          MssqlProjection.decode<C>(
            row,
            2,
            projection: 'select4',
            column: 'c2',
            expression: t.$3,
          ),
          MssqlProjection.decode<D>(
            row,
            3,
            projection: 'select4',
            column: 'c3',
            expression: t.$4,
          ),
        ),
      ),
    );
  }

  MssqlQuery _projected(List<MssqlExpression> columns) {
    var query = context
        .scopedQuery(state.scope, scopes: context.scopeCompiler(state.scope))
        .select(columns);
    for (final condition in state.where) {
      query = query.where(condition);
    }
    if (state.orderBy.isNotEmpty) {
      query = query.orderBy(state.orderBy);
    }
    return _withCtes(query);
  }

  /// The SQL and parameters this query would run, without running it.
  ///
  /// The inspection hook the API contract names: `sql` plus typed
  /// `parameters`, never SQL with values pasted into it. [dialect] defaults
  /// to the compile-time default rather than asking the server, because
  /// this method is synchronous; pass one explicitly to see what a
  /// particular target would receive.
  ///
  /// Includes are not part of it. They are separate statements run after
  /// the parent rows arrive, so there is no single statement to show.
  MssqlStatement compile({MssqlDialect? dialect}) =>
      _select().compile(dialect: dialect ?? this.dialect);

  /// Puts this query's common table expressions in front of [query].
  ///
  /// `WITH` is legal only at the start of a statement, so it goes on
  /// whichever query is about to be compiled — never on a subquery.
  MssqlQuery _withCtes(MssqlQuery query) {
    var out = query;
    for (final cte in state.ctes) {
      out = out.withTypedCte(cte);
    }
    return out;
  }

  /// The `SELECT` this query compiles to.
  ///
  /// [scopes] is the operation's scope snapshot. Every terminal that runs
  /// more than one statement resolves it once and passes it here and to
  /// [_countOn] / [_attachOn], so the page, the count and the includes are
  /// all scoped to the same tenant.
  MssqlQuery _select({List<MssqlOrder>? orderBy, MssqlScopeCompiler? scopes}) {
    var query = context.baseQuery(state.scope, scopes: scopes);
    for (final condition in state.where) {
      query = query.where(condition);
    }
    final orders = orderBy ?? state.orderBy;
    if (orders.isNotEmpty) {
      query = query.orderBy(orders);
    }
    return _withCtes(query);
  }

  Future<List<MssqlRow>> _probeTwo({
    required MssqlDialect dialect,
    required MssqlScopeCompiler scopes,
  }) async {
    return _select(scopes: scopes)
        .top(2)
        .get(
          session,
          dialect: dialect,
          timeout: state.options.timeout,
          cancellationToken: state.options.cancellationToken,
          options: state.options,
        );
  }

  /// How many rows this query currently matches.
  ///
  /// Shares the same filter and scope snapshot as [page]. Ordering is not
  /// applied: a count does not have a page.
  Future<int> count() => _countOn(session);

  /// One OFFSET page, and whether another follows.
  ///
  /// Fetches [size]+1 and drops the extra row before include, so relations
  /// are not loaded for a parent that is not on the page. [total] runs a
  /// second count over the same filter/scope; [consistency] snapshot puts
  /// both (and includes) in one SNAPSHOT transaction.
  Future<MssqlPage<TRow>> page({
    int size = 25,
    int offset = 0,
    bool total = false,
    MssqlReadConsistency consistency = MssqlReadConsistency.committed,
  }) async {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'Cannot be negative.');
    }
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive.');
    }
    final ordered = ensureStableOrder();
    final dialect = await _resolvedDialect();
    // One snapshot for the page, its includes and its total: a tenant scope
    // resolved twice could count one tenant's rows against another's page.
    final scopes = ordered.context.scopeCompiler(ordered.state.scope);
    final loader = ordered._loaderFor(session, dialect);
    return mssqlRunConsistent(
      session: session,
      consistency: consistency,
      body: (s) async {
        final fetched = await ordered
            ._select(scopes: scopes)
            .paged(offset: offset, rows: size + 1)
            .get(
              s,
              dialect: dialect,
              timeout: state.options.timeout,
              cancellationToken: state.options.cancellationToken,
              options: state.options,
            );
        final mapped = fetched.map(binding.fromRow).toList();
        final hasMore = mapped.length > size;
        final slice = ordered.dropPageSentinel(mapped, size);
        final parents = await ordered._attachOn(
          s,
          slice,
          dialect: dialect,
          loader: loader.withSession(s),
        );
        return MssqlPage<TRow>(
          rows: parents,
          offset: offset,
          requestedRows: size,
          hasMore: hasMore,
          total: total
              ? await ordered._countOn(s, dialect: dialect, scopes: scopes)
              : null,
        );
      },
    );
  }

  /// A keyset page. [after] and [before] are mutually exclusive.
  ///
  /// Composite ordering becomes nested AND/OR, not a tuple comparison.
  /// Reverse (`before`) results are returned in the caller's order.
  /// The cursor is an object; its keys are bound as parameters.
  Future<MssqlCursorPage<TRow>> cursorPage({
    int size = 25,
    MssqlCursor? after,
    MssqlCursor? before,
    MssqlReadConsistency consistency = MssqlReadConsistency.committed,
  }) async {
    if (after != null && before != null) {
      throw ArgumentError(
        'cursorPage cannot take after and before together. Ask for one '
        'direction per call.',
      );
    }
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive.');
    }
    final ordered = ensureStableOrder();
    final dialect = await _resolvedDialect();
    final orders = ordered.state.orderBy;
    MssqlKeyset.requireNamedColumns(orders, 'cursorPage()');
    final orderSig = MssqlKeyset.orderSignature(orders, dialect);
    final filterSig = MssqlKeyset.filterSignature(
      binding: binding.erase(),
      state: ordered.state,
      dialect: dialect,
    );
    if (after != null) {
      MssqlKeyset.check(
        after,
        orderSignature: orderSig,
        filterSignature: filterSig,
        keyCount: orders.length,
      );
    }
    if (before != null) {
      MssqlKeyset.check(
        before,
        orderSignature: orderSig,
        filterSignature: filterSig,
        keyCount: orders.length,
      );
    }
    final walking = before != null ? MssqlKeyset.reverseOrders(orders) : orders;
    final cursor = after ?? before;
    final scopes = ordered.context.scopeCompiler(ordered.state.scope);
    final loader = ordered._loaderFor(session, dialect);
    return mssqlRunConsistent(
      session: session,
      consistency: consistency,
      body: (s) async {
        var query = ordered._select(orderBy: walking, scopes: scopes);
        if (cursor != null) {
          query = query.where(MssqlKeyset.after(walking, cursor.keys));
        }
        final fetched = await query
            .top(size + 1)
            .get(
              s,
              dialect: dialect,
              timeout: state.options.timeout,
              cancellationToken: state.options.cancellationToken,
              options: state.options,
            );
        final hasExtra = fetched.length > size;
        final kept = hasExtra ? fetched.sublist(0, size) : fetched;
        var mapped = kept.map(binding.fromRow).toList();
        if (before != null) {
          mapped = mapped.reversed.toList();
        }
        final parents = await ordered._attachOn(
          s,
          mapped,
          dialect: dialect,
          loader: loader.withSession(s),
        );
        if (kept.isEmpty) {
          return MssqlCursorPage<TRow>(rows: parents, hasMore: false);
        }
        final firstRaw = before != null ? kept.last : kept.first;
        final lastRaw = before != null ? kept.first : kept.last;
        MssqlCursor make(MssqlRow row) => MssqlKeyset.encode(
          orderSignature: orderSig,
          filterSignature: filterSig,
          keys: MssqlKeyset.keysFromRow(row, orders),
        );
        return MssqlCursorPage<TRow>(
          rows: parents,
          hasMore: hasExtra,
          next: before != null || hasExtra ? make(lastRaw) : null,
          previous: after != null || (before != null && hasExtra)
              ? make(firstRaw)
              : null,
        );
      },
    );
  }

  /// Walks matching rows in keyset pages of [size], not OFFSET.
  ///
  /// Deleting a processed row does not skip the next one. A mutable
  /// order column is still not a snapshot; prefer the primary key last.
  Stream<List<TRow>> chunk({int size = 500}) => chunkById(size: size);

  /// Keyset chunk ordered by the primary key, or by the caller's unique
  /// `orderBy` on a keyless table.
  Stream<List<TRow>> chunkById({int size = 500}) async* {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive.');
    }
    final ordered = ensureStableOrder();
    final dialect = await _resolvedDialect();
    final orders = ordered.state.orderBy;
    MssqlKeyset.requireNamedColumns(orders, 'chunkById()');
    // One snapshot and one loader for the whole walk: two chunks of the same
    // iteration must not land on two tenants, and the caller's timeout and
    // cancellation have to reach every chunk and every include.
    final scopes = ordered.context.scopeCompiler(ordered.state.scope);
    final loader = ordered._loaderFor(session, dialect);
    List<Object?>? after;
    while (true) {
      var query = ordered._select(scopes: scopes);
      if (after != null) {
        query = query.where(MssqlKeyset.after(orders, after));
      }
      final fetched = await query
          .top(size)
          .get(
            session,
            dialect: dialect,
            timeout: state.options.timeout,
            cancellationToken: state.options.cancellationToken,
            options: state.options,
          );
      if (fetched.isEmpty) return;
      final mapped = fetched.map(binding.fromRow).toList(growable: false);
      yield await ordered._attachOn(
        session,
        mapped,
        dialect: dialect,
        loader: loader,
      );
      if (fetched.length < size) return;
      after = MssqlKeyset.keysFromRow(fetched.last, orders);
    }
  }

  /// [chunkById] as a row stream.
  Stream<TRow> lazy({int size = 500}) async* {
    await for (final batch in chunkById(size: size)) {
      for (final row in batch) {
        yield row;
      }
    }
  }

  /// Maps the native row stream. Does not buffer the whole result.
  ///
  /// Cancelling the subscription cancels the native operation.
  ///
  /// With no [include] this is the native row stream: rows are mapped as
  /// they arrive and nothing buffers the whole result.
  ///
  /// With [include] it becomes a keyset walk of [parentBatch] parents at a
  /// time, because a session cannot run an include query while one of its
  /// own result sets is still open. That keeps memory bounded to one batch
  /// plus its children, and it means this path orders by the primary key
  /// (see [chunkById]) rather than leaving the order to the server.
  Stream<TRow> stream({int parentBatch = 100}) async* {
    if (parentBatch <= 0) {
      throw ArgumentError.value(
        parentBatch,
        'parentBatch',
        'Must be positive.',
      );
    }
    final token = state.options.cancellationToken;
    if (included.isEmpty) {
      yield* _streamPlain(token);
      return;
    }
    // Includes cannot be loaded from inside an open row stream. A session
    // runs one operation at a time — the native driver holds the connection
    // for as long as rows are still arriving — so an include query issued
    // between two yields would queue behind a stream that cannot finish
    // until the consumer takes the next row, and the two would wait on each
    // other forever. Keyset chunks give the same bounded memory without the
    // deadlock: each chunk is a completed query, and the includes for it run
    // while no result set is open. The cost is that this path needs a stable
    // order, which `chunkById` supplies from the primary key.
    await for (final batch in chunkById(size: parentBatch)) {
      for (final parent in batch) {
        yield parent;
      }
    }
  }

  Stream<TRow> _streamPlain(MssqlCancellationToken? token) async* {
    final dialect = await _resolvedDialect();
    final compileWatch = Stopwatch()..start();
    final statement = _select().compile(dialect: dialect);
    compileWatch.stop();
    mssqlNoteCompileElapsed(session, compileWatch.elapsed);
    await for (final event in session.stream(
      statement.sql,
      parameters: statement.parameters,
      options: state.options,
      timeout: state.options.timeout,
      cancellationToken: token,
      batchRows: state.options.batchRows,
    )) {
      if (event is MssqlRowBatch) {
        for (final row in event.rows) {
          yield binding.fromRow(row);
        }
      }
    }
  }

  /// Re-runs this query when its tables may have changed.
  ///
  /// [MssqlWatchStrategy.localWrites] sees committed writes on this
  /// AppDatabase family only. [MssqlWatchStrategy.polling] also sees
  /// external writers. There is no CDC / change-tracking push.
  Stream<List<TRow>> watch({
    MssqlWatchStrategy strategy = MssqlWatchStrategy.localWrites,
    Duration interval = const Duration(seconds: 1),
    Iterable<String>? tables,
  }) {
    final watched = <String>{
      ...(tables ?? <String>[binding.qualifiedName]),
    };
    if (watched.isEmpty) {
      throw ArgumentError.value(
        tables,
        'tables',
        'watch() needs at least one table name when the query cannot '
            'infer dependencies.',
      );
    }
    return mssqlWatchRows<TRow>(
      strategy: strategy,
      interval: interval,
      tables: watched,
      hub: context.changes,
      read: get,
      same: (a, b) => mssqlRowsEqual(a, b, binding.toColumns),
    );
  }

  Future<int> _countOn(
    MssqlSession session, {
    MssqlDialect? dialect,
    MssqlScopeCompiler? scopes,
  }) async {
    final resolved = dialect ?? await _resolvedDialect();
    var query = context.scopedQuery(state.scope, scopes: scopes);
    for (final condition in state.where) {
      query = query.where(condition);
    }
    query = _withCtes(query);
    final rows = await query.countRows().get(
      session,
      dialect: resolved,
      timeout: state.options.timeout,
      cancellationToken: state.options.cancellationToken,
      options: state.options,
    );
    if (rows.isEmpty) return 0;
    return (rows.first.at(0)! as num).toInt();
  }

  Future<List<TRow>> _attachOn(
    MssqlSession session,
    List<TRow> parents, {
    MssqlDialect? dialect,
    MssqlRelationLoader? loader,
  }) async {
    if (included.isEmpty || parents.isEmpty) return parents;
    final resolved = dialect ?? await _resolvedDialect();
    final use =
        loader ??
        MssqlRelationLoader(session, dialect: resolved, options: state.options);
    return use.attach(binding, parents, included);
  }

  /// The relation loader for one operation.
  ///
  /// Held across the batches of a `page`, a `chunk` or a `stream` so every
  /// batch resolves each child table's scopes from the same snapshot, and so
  /// the operation's [MssqlQueryOptions] — timeout, cancellation, batch size
  /// — reach the include statements too.
  MssqlRelationLoader _loaderFor(MssqlSession session, MssqlDialect dialect) {
    final loader = MssqlRelationLoader(
      session,
      dialect: dialect,
      options: state.options,
    );
    loader.snapshotScopes(included);
    return loader;
  }

  void _notifyRead({
    required int rowCount,
    required Duration mappingElapsed,
    required Duration relationLoadElapsed,
  }) {
    final observer = context.observer;
    if (observer == null) return;
    try {
      observer(
        MssqlQueryEvent(
          sql: binding.qualifiedName,
          parameters: mssqlRedactParameters(
            const <String, Object?>{},
            includeValues: context.observerOptions.includeParameterValues,
          ),
          elapsed: mappingElapsed + relationLoadElapsed,
          kind: MssqlOrmQueryKind.query,
          inTransaction: session.inTransaction,
          rows: rowCount,
          mappingElapsed: mappingElapsed,
          relationLoadElapsed: relationLoadElapsed,
          queryName: state.options.queryName,
        ),
      );
    } catch (error, stack) {
      Zone.current.handleUncaughtError(error, stack);
    }
  }

  /// Drops the extra row a page fetched to learn [hasMore], before include.
  ///
  /// Including the sentinel would load relations for a parent that is not on
  /// the page. Call this, then [attachIncludes].
  List<TRow> dropPageSentinel(List<TRow> fetched, int pageSize) {
    if (pageSize <= 0) {
      throw ArgumentError.value(pageSize, 'pageSize', 'Must be positive.');
    }
    if (fetched.length <= pageSize) return fetched;
    return fetched.sublist(0, pageSize);
  }

  /// Loads this query's includes onto already-fetched [parents].
  Future<List<TRow>> attachIncludes(List<TRow> parents) => _attach(parents);

  /// Loads [relations] onto [rows] that were fetched without them.
  ///
  /// Rows that already carry a relation keep it; only missing names are
  /// fetched. There is no implicit "every declared relation" list — the
  /// callback says which paths to fill.
  Future<List<TRow>> loadMissing(
    List<TRow> rows,
    Iterable<MssqlRelation<TRow, Object?>> Function(TFields fields) relations,
  ) async {
    if (rows.isEmpty) return rows;
    final wanted = mergeIncludes<TRow>(
      <MssqlRelation<TRow, Object?>>[],
      List<MssqlRelation<TRow, Object?>>.of(relations(fields)),
    );
    final loadedOf = binding.isRelationLoaded;
    final missing = <MssqlRelation<TRow, Object?>>[
      for (final relation in wanted)
        if (loadedOf == null ||
            rows.any((row) => !loadedOf(row, relation.name)))
          relation,
    ];
    if (missing.isEmpty) return rows;
    final dialect = await _resolvedDialect();
    final loader = _loaderFor(session, dialect);
    if (loadedOf == null) {
      return loader.attach(binding, rows, missing);
    }
    // Per-row: only parents that lack the relation are queried for it.
    var current = rows;
    for (final relation in missing) {
      final need = <TRow>[
        for (final row in current)
          if (!loadedOf(row, relation.name)) row,
      ];
      if (need.isEmpty) continue;
      final attached = await loader.attach(
        binding,
        need,
        <MssqlRelation<TRow, Object?>>[relation],
      );
      var j = 0;
      current = <TRow>[
        for (final row in current)
          loadedOf(row, relation.name) ? row : attached[j++],
      ];
    }
    return current;
  }

  Future<List<TRow>> _attach(List<TRow> parents) => _attachOn(session, parents);
}
