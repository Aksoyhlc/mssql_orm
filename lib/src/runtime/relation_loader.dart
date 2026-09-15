import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../expression.dart';
import '../operators.dart';
import '../query.dart';
import '../window.dart';
import 'binding.dart';
import 'exception.dart';
import 'query_context.dart';
import 'relation.dart';
import 'retry.dart';
import 'scope.dart';

/// One relation's load: children grouped by parent key, plus truncation.
class MssqlRelationLoad<TChild> {
  MssqlRelationLoad(this.grouped, {this.truncated = false, this.limit});

  final Map<MssqlRelationKey, List<TChild>> grouped;
  final bool truncated;
  final int? limit;
}

/// Loads related rows for a batch of parents, without N+1.
///
/// One query per relation, not one per parent: the parents' keys are collected,
/// the target is read with `WHERE <fk> IN (…)` (or a to-one LEFT JOIN), and
/// the results are grouped in memory. Nested includes reuse this loader, so
/// depth is another query per level rather than a second implementation.
///
/// Lazy loading is absent: Dart has no synchronous blocking I/O, so
/// `user.orders` could only be a method call anyway, and lazy loading is where
/// N+1 comes from.
class MssqlRelationLoader {
  MssqlRelationLoader(
    this.session, {
    required this.dialect,
    this.options = MssqlQueryOptions.defaults,
  }) : _scopeCache = <String, MssqlScopeCompiler>{};

  MssqlRelationLoader._(
    this.session, {
    required this.dialect,
    required this.options,
    required Map<String, MssqlScopeCompiler> scopeCache,
  }) : _scopeCache = scopeCache;

  final MssqlSession session;
  final MssqlDialect dialect;

  /// The execution settings of the operation that asked for the include.
  ///
  /// A timeout or a cancellation the caller set on `db.orders.options(...)`
  /// has to reach the include statements too, or a cancelled read would keep
  /// loading children and a bounded read would hang on an unbounded one.
  final MssqlQueryOptions options;

  MssqlCancellationToken? get cancellationToken => options.cancellationToken;

  /// One scope snapshot per (table, selection) for the life of this loader.
  ///
  /// A loader spans every level of an include tree and every key batch
  /// within a level. Resolving a child table's tenant scope once per batch
  /// would let two batches of the same relation land on two tenants; the
  /// snapshot is therefore keyed by table and selection and reused.
  final Map<String, MssqlScopeCompiler> _scopeCache;

  /// Resolves every included binding's ambient scopes before parent I/O.
  void snapshotScopes(Iterable<MssqlRelation<Object?, Object?>> relations) {
    for (final relation in relations) {
      _snapshotRelation(relation);
    }
  }

  /// The same scope snapshot against a transaction-scoped session.
  MssqlRelationLoader withSession(MssqlSession session) =>
      identical(session, this.session)
      ? this
      : MssqlRelationLoader._(
          session,
          dialect: dialect,
          options: options,
          scopeCache: _scopeCache,
        );

  void _snapshotRelation(MssqlRelation<Object?, Object?> relation) {
    final morph = relation.kind == MssqlRelationKind.morphTo
        ? relation.morph
        : null;
    if (morph == null) {
      _scopes(relation.targetBinding, relation.scope).readConditions;
    } else {
      for (final binding in morph.targets.values) {
        _scopes(binding, const MssqlScopeSelection.empty()).readConditions;
      }
    }
    final through = relation.through;
    if (through != null) {
      _scopes(
        through.binding,
        const MssqlScopeSelection.empty(),
      ).readConditions;
    }
    for (final nested in relation.nested) {
      _snapshotRelation(nested);
    }
  }

  MssqlScopeCompiler _scopes(
    MssqlTableBinding<Object?> binding,
    MssqlScopeSelection selection,
  ) => _scopeCache.putIfAbsent(
    '${binding.qualifiedName}|$selection',
    () => MssqlScopeCompiler(binding, selection),
  );

  /// Attaches [include] onto [parents] and returns new rows in the same order.
  ///
  /// Same-path includes are merged; conflicting filter/limit/strategy throw
  /// [MssqlIncludeConflictException]. [applyRelations] records loaded names,
  /// including loaded-null and loaded-empty; truncated names travel under
  /// [mssqlTruncatedRelationsKey].
  Future<List<TParent>> attach<TParent>(
    MssqlTableBinding<TParent> binding,
    List<TParent> parents,
    List<MssqlRelation<TParent, Object?>> include, {
    void Function(String warning)? onWarning,
  }) async {
    if (parents.isEmpty || include.isEmpty) return parents;
    // `hasRelations` and `withRelations` rather than reading
    // `applyRelations` directly. Dart's generics are reified and class type
    // parameters are covariant, so a nested include reaches here with
    // `TParent` erased to `Object?` while the binding is really an
    // `MssqlTableBinding<LineRow>`: reading the field then asks the runtime
    // to see a `LineRow Function(LineRow, …)` as an
    // `Object? Function(Object?, …)` and it refuses. Those two members exist
    // on the binding for exactly this reason.
    if (!binding.hasRelations) {
      throw StateError(
        '${binding.qualifiedName} has no generated relations, so include() '
        'has nothing to load. Regenerate the table if it has foreign keys.',
      );
    }
    final merged = mergeIncludes<TParent>(
      <MssqlRelation<TParent, Object?>>[],
      include,
    );
    final loaded = <String, Map<MssqlRelationKey, List<Object?>>>{};
    final truncated = <String, int>{};

    for (final relation in merged) {
      _checkDecimal(relation.targetBinding);
      if (relation.through != null) {
        _checkDecimal(relation.through!.binding);
      }
      final result = await load<TParent, Object?>(
        relation,
        parents,
        (parent) => binding.namedColumnsOf(parent, relation.localColumns),
        parentBinding: binding,
        onWarning: onWarning,
      );
      loaded[relation.name] = result.grouped;
      if (result.truncated) {
        truncated[relation.name] = result.limit ?? relation.rowLimit ?? 0;
      }
    }

    return <TParent>[
      for (final parent in parents)
        binding.withRelations(parent, <String, Object?>{
              for (final relation in merged)
                relation.name: _pick(
                  relation,
                  loaded[relation.name]!,
                  _parentValuesForPick(binding, relation, parent),
                  parentBinding: binding,
                ),
              if (truncated.isNotEmpty) mssqlTruncatedRelationsKey: truncated,
            })
            as TParent,
    ];
  }

  /// Loads [relation] for [parents] and returns, per parent key, its children.
  Future<MssqlRelationLoad<TChild>> load<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    List<TParent> parents,
    Map<String, Object?> Function(TParent parent) parentColumns, {
    MssqlTableBinding<TParent>? parentBinding,
    void Function(String warning)? onWarning,
  }) async {
    if (parents.isEmpty) {
      return MssqlRelationLoad<TChild>(<MssqlRelationKey, List<TChild>>{});
    }

    late final MssqlRelationLoad<TChild> result;
    if (relation.kind == MssqlRelationKind.morphTo) {
      result = await _loadMorphTo(
        relation,
        parents,
        parentColumns,
        parentBinding,
        onWarning,
      );
    } else if (relation.through != null) {
      result = await _loadThrough(
        relation,
        parents,
        parentColumns,
        parentBinding,
        onWarning,
      );
    } else if (relation.strategy == MssqlIncludeStrategy.join) {
      result = await _loadJoin(
        relation,
        parents,
        parentColumns,
        parentBinding,
        onWarning,
      );
    } else {
      result = await _loadDirect(
        relation,
        parents,
        parentColumns,
        parentBinding,
        onWarning,
      );
    }

    if (relation.nested.isEmpty) return result;
    final nested = await _loadNested(relation, result.grouped, onWarning);
    return MssqlRelationLoad<TChild>(
      nested,
      truncated: result.truncated,
      limit: result.limit,
    );
  }

  Future<Map<MssqlRelationKey, List<TChild>>> _loadNested<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    Map<MssqlRelationKey, List<TChild>> grouped,
    void Function(String warning)? onWarning,
  ) async {
    final children = <TChild>[for (final list in grouped.values) ...list];
    if (children.isEmpty) return grouped;
    final childBinding = relation.targetBinding;
    if (!childBinding.hasRelations) {
      throw StateError(
        'Relation "${relation.name}" includes nested relations, but '
        '${childBinding.qualifiedName} has no generated relations to attach. '
        'An include level is never skipped.',
      );
    }
    final attached = await attach<TChild>(
      childBinding,
      children,
      relation.nested,
      onWarning: onWarning,
    );
    var i = 0;
    return <MssqlRelationKey, List<TChild>>{
      for (final entry in grouped.entries)
        entry.key: <TChild>[
          for (var n = 0; n < entry.value.length; n++) attached[i++],
        ],
    };
  }

  Future<MssqlRelationLoad<TChild>> _loadDirect<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    List<TParent> parents,
    Map<String, Object?> Function(TParent parent) parentColumns,
    MssqlTableBinding<TParent>? parentBinding,
    void Function(String warning)? onWarning,
  ) async {
    final keys = _sqlKeys(
      parents,
      relation.localColumns,
      parentColumns,
      parentBinding,
    );
    if (keys.isEmpty) {
      return MssqlRelationLoad<TChild>(<MssqlRelationKey, List<TChild>>{});
    }

    final binding = relation.targetBinding;
    final extra = _filterParameterCount(relation, binding);
    final rows = <TChild>[];
    var remaining = relation.rowLimit;
    var truncated = false;

    for (final batch in batchKeys(
      keys,
      relation.localColumns.length,
      extraParameters: extra,
    )) {
      if (remaining != null && remaining <= 0) {
        truncated = true;
        break;
      }
      final fetched = await _readTarget(
        relation,
        binding,
        batch,
        remaining: remaining,
      );
      for (final row in fetched) {
        if (remaining != null && remaining <= 0) {
          truncated = true;
          break;
        }
        rows.add(row as TChild);
        if (remaining != null) remaining--;
      }
      if (relation.rowLimit != null &&
          remaining != null &&
          remaining <= 0 &&
          fetched.length >
              (relation.rowLimit! - rows.length + fetched.length)) {
        truncated = true;
      }
    }

    if (relation.rowLimit != null && remaining != null && remaining <= 0) {
      truncated = true;
      onWarning?.call(
        'Relation "${relation.name}" hit its maxLoadedRows('
        '${relation.rowLimit}) ceiling, so the loaded rows are incomplete.',
      );
    }

    final grouped = _groupChildren(relation, rows);
    _assertToOneCardinality(relation, grouped);
    return MssqlRelationLoad<TChild>(
      grouped,
      truncated: truncated,
      limit: relation.rowLimit,
    );
  }

  Future<MssqlRelationLoad<TChild>> _loadJoin<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    List<TParent> parents,
    Map<String, Object?> Function(TParent parent) parentColumns,
    MssqlTableBinding<TParent>? parentBinding,
    void Function(String warning)? onWarning,
  ) async {
    if (parentBinding == null) {
      throw StateError(
        'Relation "${relation.name}" uses join strategy, which needs the '
        'parent table binding so the LEFT JOIN has a FROM.',
      );
    }
    final keys = _sqlKeys(
      parents,
      relation.localColumns,
      parentColumns,
      parentBinding,
    );
    if (keys.isEmpty) {
      return MssqlRelationLoad<TChild>(<MssqlRelationKey, List<TChild>>{});
    }

    final child = relation.targetBinding;
    final childQuery = _targetQuery(relation, child);
    final extra = childQuery.compile(dialect: dialect).parameters.length;
    final grouped = <MssqlRelationKey, List<TChild>>{};
    var taken = 0;
    var truncated = false;

    for (final batch in batchKeys(
      keys,
      relation.localColumns.length,
      extraParameters: extra,
    )) {
      var query =
          MssqlQuery.fromParts(
            parentBinding.nameParts,
            as: '__p',
            ref: parentBinding.sourceRef,
          ).joinSub(
            MssqlJoinKind.left,
            childQuery,
            as: '__c',
            on: and(<MssqlCondition>[
              for (var i = 0; i < relation.localColumns.length; i++)
                Col(
                  '__c.${relation.foreignColumns[i]}',
                ).eqExpr(Col('__p.${relation.localColumns[i]}')),
            ]),
          );
      query = query.where(
        relationPredicate([
          for (final c in relation.localColumns) '__p.$c',
        ], batch),
      );
      query = query.select(<MssqlExpression>[
        for (var i = 0; i < relation.localColumns.length; i++)
          Col('__p.${relation.localColumns[i]}').as('__mssql_p$i'),
        for (final column in child.columns)
          Col('__c.${column.name}').as(column.name),
      ]);

      final statement = query.compile(dialect: dialect);
      final result = await session.queryTypedRows(
        statement.sql,
        parameters: statement.parameters,
        options: options,
        timeout: options.timeout,
        cancellationToken: cancellationToken,
        // Builder-compiled SELECT: safe to repeat, so a dropped connection
        // mid-include is recovered rather than failing the whole read. A
        // relation filter carrying raw SQL takes it back to never.
        retry: statement.readRetry,
      );
      for (final row in result) {
        final parentValues = <String, Object?>{
          for (var i = 0; i < relation.localColumns.length; i++)
            relation.localColumns[i]: row['__mssql_p$i'],
        };
        final parentKey = _groupKey(
          parentBinding,
          relation.localColumns,
          parentValues,
        );
        final childPk = child.primaryKey.isEmpty
            ? relation.foreignColumns
            : child.primaryKey;
        final missing = childPk.every((name) => row[name] == null);
        if (missing) {
          grouped.putIfAbsent(parentKey, () => <TChild>[]);
          continue;
        }
        if (relation.rowLimit != null && taken >= relation.rowLimit!) {
          truncated = true;
          continue;
        }
        grouped
            .putIfAbsent(parentKey, () => <TChild>[])
            .add(child.rowFrom(row) as TChild);
        taken++;
      }
    }

    if (truncated) {
      onWarning?.call(
        'Relation "${relation.name}" hit its maxLoadedRows('
        '${relation.rowLimit}) ceiling, so the loaded rows are incomplete.',
      );
    }
    _assertToOneCardinality(relation, grouped);
    return MssqlRelationLoad<TChild>(
      grouped,
      truncated: truncated,
      limit: relation.rowLimit,
    );
  }

  Future<MssqlRelationLoad<TChild>> _loadThrough<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    List<TParent> parents,
    Map<String, Object?> Function(TParent parent) parentColumns,
    MssqlTableBinding<TParent>? parentBinding,
    void Function(String warning)? onWarning,
  ) async {
    final through = relation.through!;
    final parentKeys = _sqlKeys(
      parents,
      relation.localColumns,
      parentColumns,
      parentBinding,
    );
    if (parentKeys.isEmpty) {
      return MssqlRelationLoad<TChild>(<MssqlRelationKey, List<TChild>>{});
    }

    final pivotRows = await _readBinding(
      through.binding,
      through.nearColumns,
      parentKeys,
      extra: through.typeValue == null
          ? null
          : Col(through.typeColumn!).eq(through.typeValue),
      scope: relation.scope,
    );

    final links =
        <({MssqlRelationKey near, MssqlRelationKey far, Object? pivot})>[];
    final farKeys = <MssqlRelationKey>{};
    for (final row in pivotRows) {
      final values = through.binding.namedColumnsOf(row, [
        ...through.nearColumns,
        ...through.farColumns,
      ]);
      final near = _groupKey(through.binding, through.nearColumns, values);
      final farRaw = MssqlRelationKey(<Object?>[
        for (final column in through.farColumns) values[column],
      ]);
      if (farRaw.hasNull) continue;
      final far = _groupKey(through.binding, through.farColumns, values);
      links.add((near: near, far: far, pivot: row));
      farKeys.add(farRaw);
    }
    if (farKeys.isEmpty) {
      return MssqlRelationLoad<TChild>(<MssqlRelationKey, List<TChild>>{});
    }

    final targets = await _readBinding(
      relation.targetBinding,
      relation.foreignColumns,
      farKeys.toList(),
      orderBy: _uniqueOrder(relation),
      extra: relation.where.isEmpty ? null : and(relation.where),
      scope: relation.scope,
      windowLimit: relation.perParentLimit,
      windowPartition: relation.foreignColumns,
    );

    final byFar = <MssqlRelationKey, List<TChild>>{};
    final farOrder = <MssqlRelationKey>[];
    for (final row in targets) {
      final values = relation.targetBinding.namedColumnsOf(
        row,
        relation.foreignColumns,
      );
      final key = _groupKey(
        relation.targetBinding,
        relation.foreignColumns,
        values,
      );
      byFar.putIfAbsent(key, () => <TChild>[]).add(row as TChild);
      if (!farOrder.contains(key)) {
        farOrder.add(key);
      }
    }

    // Parent → children in *target* order, not pivot insertion order.
    final farRank = <MssqlRelationKey, int>{
      for (var i = 0; i < farOrder.length; i++) farOrder[i]: i,
    };
    final linksByNear =
        <MssqlRelationKey, List<({MssqlRelationKey far, Object? pivot})>>{};
    for (final link in links) {
      linksByNear.putIfAbsent(link.near, () => []).add((
        far: link.far,
        pivot: link.pivot,
      ));
    }
    for (final list in linksByNear.values) {
      list.sort((a, b) {
        final ra = farRank[a.far] ?? 1 << 30;
        final rb = farRank[b.far] ?? 1 << 30;
        return ra.compareTo(rb);
      });
    }

    final out = <MssqlRelationKey, List<TChild>>{};
    var taken = 0;
    var truncated = false;
    for (final entry in linksByNear.entries) {
      final list = <TChild>[];
      var perParent = 0;
      for (final link in entry.value) {
        for (final row in byFar[link.far] ?? <TChild>[]) {
          if (relation.rowLimit != null && taken >= relation.rowLimit!) {
            truncated = true;
            break;
          }
          if (relation.perParentLimit != null &&
              perParent >= relation.perParentLimit!) {
            break;
          }
          list.add(row);
          taken++;
          perParent++;
        }
      }
      if (list.isNotEmpty) out[entry.key] = list;
    }
    if (truncated) {
      onWarning?.call(
        'Relation "${relation.name}" hit its maxLoadedRows('
        '${relation.rowLimit}) ceiling, so the loaded rows are incomplete.',
      );
    }
    _assertToOneCardinality(relation, out);
    return MssqlRelationLoad<TChild>(
      out,
      truncated: truncated,
      limit: relation.rowLimit,
    );
  }

  Future<MssqlRelationLoad<TChild>> _loadMorphTo<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    List<TParent> parents,
    Map<String, Object?> Function(TParent parent) parentColumns,
    MssqlTableBinding<TParent>? parentBinding,
    void Function(String warning)? onWarning,
  ) async {
    final morph = relation.morph!;
    // A morphTo needs two columns of the parent — the discriminator and the
    // key — while `parentColumns` only supplies `relation.localColumns`,
    // which for a morph is the key alone. Reading the pair from the parent
    // binding is the difference between loading the relation and silently
    // loading nothing: the discriminator came back null for every row, so
    // every row was skipped by the `continue` below and not one per-type
    // query ever ran.
    final wanted = <String>{morph.typeColumn, morph.idColumn}.toList();
    if (parentBinding == null) {
      throw StateError(
        'Relation "${relation.name}" is a morphTo, so loading it needs '
        '"${morph.typeColumn}" and "${morph.idColumn}" from the parent row, '
        'and this load was given no parent binding to read them through. '
        'Load it through a repository or an entity query rather than calling '
        'load() directly.',
      );
    }
    final byType = <String, List<MssqlRelationKey>>{};
    for (final parent in parents) {
      final values = parentBinding.namedColumnsOf(parent, wanted);
      final type = values[morph.typeColumn];
      final id = values[morph.idColumn];
      // A row that names neither is not a broken row: a nullable morph is
      // how "this comment is attached to nothing" is spelled.
      if (type == null || id == null) continue;
      byType
          .putIfAbsent(type.toString(), () => <MssqlRelationKey>[])
          .add(MssqlRelationKey(<Object?>[id]));
    }

    final out = <MssqlRelationKey, List<TChild>>{};
    var taken = 0;
    var truncated = false;
    for (final entry in byType.entries) {
      final binding = morph.targets[entry.key];
      if (binding == null) {
        switch (morph.unknown) {
          case MssqlMorphUnknown.error:
            throw StateError(
              'Relation "${relation.name}" found type "${entry.key}", which '
              'is not in its morph map. Add the target, or set unknown: '
              'ignore if this application does not model that type.',
            );
          case MssqlMorphUnknown.ignore:
            onWarning?.call(
              'Relation "${relation.name}" found type "${entry.key}", which '
              'is not in its morph map, so those rows were left unloaded.',
            );
            continue;
        }
      }
      _checkDecimal(binding);
      final keyColumns = binding.primaryKey.isEmpty
          ? relation.foreignColumns
          : binding.primaryKey;
      final unique = <MssqlRelationKey>{};
      final keys = <MssqlRelationKey>[];
      for (final key in entry.value) {
        if (unique.add(key)) keys.add(key);
      }
      final rows = await _readBinding(binding, keyColumns, keys);
      for (final row in rows) {
        if (relation.rowLimit != null && taken >= relation.rowLimit!) {
          truncated = true;
          break;
        }
        final values = binding.namedColumnsOf(row, keyColumns);
        final key = MssqlRelationKey(<Object?>[
          entry.key,
          for (final column in keyColumns) values[column],
        ]);
        out.putIfAbsent(key, () => <TChild>[]).add(row as TChild);
        taken++;
      }
    }
    if (truncated) {
      onWarning?.call(
        'Relation "${relation.name}" hit its maxLoadedRows('
        '${relation.rowLimit}) ceiling, so the loaded rows are incomplete.',
      );
    }
    return MssqlRelationLoad<TChild>(
      out,
      truncated: truncated,
      limit: relation.rowLimit,
    );
  }

  Future<List<Object?>> _readTarget<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    MssqlTableBinding<TChild> binding,
    List<MssqlRelationKey> keys, {
    int? remaining,
  }) {
    return _readBinding(
      binding,
      relation.foreignColumns,
      keys,
      extra: _targetExtra(relation),
      orderBy: _uniqueOrder(relation),
      scope: relation.scope,
      windowLimit: relation.perParentLimit,
      windowPartition: relation.foreignColumns,
      remaining: remaining,
    );
  }

  MssqlCondition? _targetExtra<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
  ) {
    final parts = <MssqlCondition>[...relation.where];
    final morph = relation.morph;
    if (morph?.typeValue != null) {
      parts.add(Col(morph!.typeColumn).eq(morph.typeValue));
    }
    if (parts.isEmpty) return null;
    if (parts.length == 1) return parts.first;
    return and(parts);
  }

  MssqlQuery _targetQuery<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    MssqlTableBinding<TChild> binding,
  ) {
    final context = MssqlQueryContext<TChild>(
      session: session,
      binding: binding,
      dialect: dialect,
    );
    var query = context.baseQuery(
      relation.scope,
      scopes: _scopes(binding, relation.scope),
    );
    final extra = _targetExtra(relation);
    if (extra != null) query = query.where(extra);
    return query;
  }

  int _filterParameterCount<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    MssqlTableBinding<TChild> binding,
  ) {
    return _targetQuery(
      relation,
      binding,
    ).compile(dialect: dialect).parameters.length;
  }

  Future<List<Object?>> _readBinding<T>(
    MssqlTableBinding<T> binding,
    List<String> columns,
    List<MssqlRelationKey> keys, {
    MssqlCondition? extra,
    List<MssqlOrder> orderBy = const <MssqlOrder>[],
    MssqlScopeSelection scope = const MssqlScopeSelection.empty(),
    int? windowLimit,
    List<String>? windowPartition,
    int? remaining,
  }) async {
    final context = MssqlQueryContext<T>(
      session: session,
      binding: binding,
      dialect: dialect,
    );
    final snapshot = _scopes(binding, scope);
    final extraCount = () {
      var q = context.baseQuery(scope, scopes: snapshot);
      if (extra != null) q = q.where(extra);
      return q.compile(dialect: dialect).parameters.length;
    }();
    final out = <Object?>[];
    for (final batch in batchKeys(
      keys,
      columns.length,
      extraParameters: extraCount,
    )) {
      if (remaining != null && remaining <= 0) break;
      var query = context
          .baseQuery(scope, scopes: snapshot)
          .where(relationPredicate(columns, batch));
      if (extra != null) query = query.where(extra);
      if (windowLimit != null) {
        // The ordering goes on the window and on the outer query, never on
        // the inner one: the per-parent limit turns it into a derived
        // table, and SQL Server refuses ORDER BY there without TOP — which
        // is what it did, so takePerParent could not compile at all.
        query = _applyPerParentWindow(
          query,
          binding,
          partition: windowPartition ?? columns,
          orderBy: orderBy,
          limit: windowLimit,
        );
      } else if (orderBy.isNotEmpty) {
        query = query.orderBy(orderBy);
      }
      final statement = query.compile(dialect: dialect);
      final rows = await session.queryTypedRows(
        statement.sql,
        parameters: statement.parameters,
        options: options,
        timeout: options.timeout,
        cancellationToken: cancellationToken,
        // Builder-compiled SELECT: safe to repeat, so a dropped connection
        // mid-include is recovered rather than failing the whole read. A
        // relation filter carrying raw SQL takes it back to never.
        retry: statement.readRetry,
      );
      for (final row in rows) {
        if (remaining != null && remaining <= 0) break;
        out.add(binding.rowFrom(row));
      }
    }
    return out;
  }

  MssqlQuery _applyPerParentWindow<T>(
    MssqlQuery inner,
    MssqlTableBinding<T> binding, {
    required List<String> partition,
    required List<MssqlOrder> orderBy,
    required int limit,
  }) {
    final ordering = orderBy.isEmpty
        ? _primaryKeyOrder(binding)
        : _withPrimaryKeyTieBreak(binding, orderBy);
    final window = MssqlWindow(
      partitionBy: <MssqlExpression>[for (final name in partition) Col(name)],
      orderBy: ordering,
    );
    final numbered = inner.select(<MssqlExpression>[
      for (final column in binding.columns) Col(column.name),
      MssqlWindowExpression.rowNumber(window).as('__mssql_rn'),
    ]);
    // `__mssql_rn` is projected by the derived table and dropped by the
    // outer one, so the helper column never reaches the caller. The outer
    // query repeats the ordering: the row number decides *which* children
    // survive the limit, and this decides what order they arrive in.
    return MssqlQuery.fromSub(numbered, as: '__rel')
        .select(<MssqlExpression>[
          for (final column in binding.columns) Col(column.name),
        ])
        .where(Col('__mssql_rn').lte(limit))
        .orderBy(ordering);
  }

  List<MssqlOrder> _uniqueOrder<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
  ) {
    if (relation.orderBy.isNotEmpty) {
      return _withPrimaryKeyTieBreak(relation.targetBinding, relation.orderBy);
    }
    if (relation.perParentLimit != null) {
      return _primaryKeyOrder(relation.targetBinding);
    }
    return const <MssqlOrder>[];
  }

  List<MssqlOrder> _primaryKeyOrder<T>(MssqlTableBinding<T> binding) {
    if (!binding.hasPrimaryKey) {
      throw StateError(
        '${binding.qualifiedName} has no primary key, so takePerParent and '
        'child ordering cannot be unique. Add an explicit orderBy that '
        'uniquely identifies a child row.',
      );
    }
    return <MssqlOrder>[for (final name in binding.primaryKey) Col(name).asc()];
  }

  List<MssqlOrder> _withPrimaryKeyTieBreak<T>(
    MssqlTableBinding<T> binding,
    List<MssqlOrder> orderBy,
  ) {
    if (!binding.hasPrimaryKey) return orderBy;
    return mssqlWithKeyTieBreak(orderBy, binding.primaryKey);
  }

  List<MssqlRelationKey> _sqlKeys<TParent>(
    List<TParent> parents,
    List<String> columns,
    Map<String, Object?> Function(TParent parent) parentColumns,
    MssqlTableBinding<TParent>? parentBinding,
  ) {
    final unique = <MssqlRelationKey>{};
    final keys = <MssqlRelationKey>[];
    for (final parent in parents) {
      final values = parentColumns(parent);
      final raw = MssqlRelationKey(<Object?>[
        for (final column in columns) values[column],
      ]);
      if (raw.hasNull) continue;
      final group = parentBinding == null
          ? raw
          : _groupKey(parentBinding, columns, values);
      if (unique.add(group)) keys.add(raw);
    }
    return keys;
  }

  Map<MssqlRelationKey, List<TChild>> _groupChildren<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    List<TChild> rows,
  ) {
    final grouped = <MssqlRelationKey, List<TChild>>{};
    for (final row in rows) {
      final values = relation.targetBinding.namedColumnsOf(
        row,
        relation.foreignColumns,
      );
      final key = _groupKey(
        relation.targetBinding,
        relation.foreignColumns,
        values,
      );
      grouped.putIfAbsent(key, () => <TChild>[]).add(row);
    }
    return grouped;
  }

  MssqlRelationKey _groupKey<T>(
    MssqlTableBinding<T> binding,
    List<String> columns,
    Map<String, Object?> values,
  ) => relationKeyOf(binding, columns, values);

  void _assertToOneCardinality<TParent, TChild>(
    MssqlRelation<TParent, TChild> relation,
    Map<MssqlRelationKey, List<TChild>> grouped,
  ) {
    if (!relation.isToOne) return;
    for (final entry in grouped.entries) {
      if (entry.value.length > 1) {
        throw StateError(
          'Relation "${relation.name}" is ${relation.kind.name} but key '
          '${entry.key} matched ${entry.value.length} rows. A to-one load '
          'refuses to pick the first silently; make the foreign key unique, '
          'or load it as hasMany.',
        );
      }
    }
  }

  Object? _pick<TParent>(
    MssqlRelation<TParent, Object?> relation,
    Map<MssqlRelationKey, List<Object?>> grouped,
    Map<String, Object?> parentValues, {
    required MssqlTableBinding<TParent> parentBinding,
  }) {
    final morph = relation.kind == MssqlRelationKind.morphTo
        ? relation.morph
        : null;
    final key = morph == null
        ? _groupKey(parentBinding, relation.localColumns, parentValues)
        : MssqlRelationKey(<Object?>[
            parentValues[morph.typeColumn]?.toString(),
            for (final column in relation.localColumns) parentValues[column],
          ]);
    final children = grouped[key] ?? const <Object?>[];
    return relation.isToOne
        ? (children.isEmpty ? null : children.first)
        : children;
  }

  Map<String, Object?> _parentValuesForPick<TParent>(
    MssqlTableBinding<TParent> binding,
    MssqlRelation<TParent, Object?> relation,
    TParent parent,
  ) {
    final morph = relation.kind == MssqlRelationKind.morphTo
        ? relation.morph
        : null;
    final columns = morph == null
        ? relation.localColumns
        : <String>{morph.typeColumn, ...relation.localColumns}.toList();
    return binding.namedColumnsOf(parent, columns);
  }

  void _checkDecimal<T>(MssqlTableBinding<T> binding) {
    final hasExactNumeric = binding.columns.any(
      (c) => const <MssqlType>{
        MssqlType.decimal,
        MssqlType.numeric,
        MssqlType.money,
        MssqlType.smallMoney,
      }.contains(c.type),
    );
    if (!hasExactNumeric) return;
    if (binding.decimalMode == session.config.decimalMode) return;
    throw MssqlBindingMismatchException(
      '${binding.qualifiedName} was generated for '
      'MssqlDecimalMode.${binding.decimalMode.name}, but the connection '
      'uses MssqlDecimalMode.${session.config.decimalMode.name}. Relation '
      'loads use the same codec as the rest of the query; match the '
      'connection configuration, or regenerate for the other mode.',
    );
  }
}
