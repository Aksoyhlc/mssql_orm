import 'package:meta/meta.dart';

import '../expression.dart';
import '../operators.dart';
import 'binding.dart';
import 'exception.dart';
import 'scope.dart';

/// How a to-one relation is fetched.
///
/// To-many stays [batch] always: a join would multiply parent rows. [join]
/// is opt-in for to-one so a missing counterpart stays a LEFT JOIN null
/// rather than an absent IN-list key, and two children for one parent is a
/// cardinality error rather than `children.first`.
enum MssqlIncludeStrategy {
  /// One `WHERE fk IN (…)` per relation, grouped in memory. The default.
  batch,

  /// Parent keys LEFT JOINed to the target. To-one only.
  join,
}

/// What to do when a morphTo type column names a table the map does not have.
enum MssqlMorphUnknown {
  /// The default: an unknown discriminator is a modelling error.
  error,

  /// Skip those parents and report a warning. Explicit opt-in.
  ignore,
}

/// Map key [MssqlTableBinding.applyRelations] uses for truncated names.
///
/// Generated `withRelations` reads this and does not treat it as a relation
/// that was loaded. A collision with a real relation named this way is
/// refused at generation time.
const String mssqlTruncatedRelationsKey = '__mssql_truncated';

/// A child row plus the pivot row that linked it, for belongsToMany.
///
/// The target order is the child's, not the pivot's: grouping by parent
/// must not reshuffle what `orderBy` asked for on the target.
@immutable
class MssqlPivoted<TChild, TPivot> {
  const MssqlPivoted({required this.row, required this.pivot});

  final TChild row;
  final TPivot pivot;
}

/// The relation shapes, matching the vocabulary Eloquent uses.
///
/// The pairs that look redundant are not. [hasOne] and [hasMany] are the same
/// foreign key in the same direction; what differs is whether the other side
/// can hold more than one row per parent, which a unique constraint on its
/// foreign key columns settles. Every `morph*` and `*Through` shape is
/// declared rather than derived, because no foreign key expresses them.
enum MssqlRelationKind {
  /// A foreign key on this table points at another's primary key.
  /// Eloquent: `belongsTo`.
  belongsTo,

  /// A foreign key on another table points back at this one, and that side is
  /// unique, so there is at most one. Eloquent: `hasOne`.
  hasOne,

  /// A foreign key on another table points back at this one. Eloquent:
  /// `hasMany`.
  hasMany,

  /// Through a pivot table carrying both sides' keys. Eloquent:
  /// `belongsToMany`.
  belongsToMany,

  /// A → B → C, where C is reached through B and there is one. Eloquent:
  /// `hasOneThrough`.
  hasOneThrough,

  /// A → B → C, many. Eloquent: `hasManyThrough`.
  hasManyThrough,

  /// This table carries a type column and an id column naming one of several
  /// possible parents. Eloquent: `morphTo`.
  morphTo,

  /// The inverse of [morphTo], with one child. Eloquent: `morphOne`.
  morphOne,

  /// The inverse of [morphTo], with many. Eloquent: `morphMany`.
  morphMany,

  /// Through a pivot whose rows also carry a type column. Eloquent:
  /// `morphToMany`.
  morphToMany,
}

/// The middle table of a [MssqlRelationKind.belongsToMany],
/// [MssqlRelationKind.hasManyThrough] or [MssqlRelationKind.morphToMany].
///
/// Loading through one costs two queries per relation instead of one: the
/// pivot is read for the parents' keys, then the target for the pivot's. Still
/// a fixed number, still no N+1.
@immutable
class MssqlRelationThrough {
  MssqlRelationThrough({
    required this.binding,
    required List<String> nearColumns,
    required List<String> farColumns,
    this.typeColumn,
    this.typeValue,
  }) : nearColumns = List<String>.unmodifiable(nearColumns),
       farColumns = List<String>.unmodifiable(farColumns);

  /// The pivot or intermediate table.
  final MssqlTableBinding<Object?> binding;

  /// Columns on the middle table matching the parent's local columns.
  final List<String> nearColumns;

  /// Columns on the middle table matching the target's foreign columns.
  final List<String> farColumns;

  /// For a polymorphic pivot, the column naming the parent's type…
  final String? typeColumn;

  /// …and the value that means this parent table.
  final String? typeValue;
}

/// How a polymorphic relation finds its other side.
///
/// SQL Server cannot express one of these as a foreign key — a column pointing
/// at several tables cannot be constrained — so it is declared rather than
/// discovered. That is not a limitation of this package; it is what makes the
/// pattern polymorphic.
@immutable
class MssqlMorph {
  MssqlMorph({
    required this.typeColumn,
    required this.idColumn,
    this.typeValue,
    this.unknown = MssqlMorphUnknown.error,
    Map<String, MssqlTableBinding<Object?>> targets =
        const <String, MssqlTableBinding<Object?>>{},
  }) : targets = Map<String, MssqlTableBinding<Object?>>.unmodifiable(targets);

  /// The column holding the other side's type name.
  final String typeColumn;

  /// The column holding the other side's key.
  final String idColumn;

  /// For [MssqlRelationKind.morphOne] and [MssqlRelationKind.morphMany]: the
  /// value that means "this table".
  final String? typeValue;

  /// For [MssqlRelationKind.morphTo]: which table each type name denotes.
  ///
  /// A type the map does not cover is [MssqlMorphUnknown.error] by default.
  /// [MssqlMorphUnknown.ignore] skips those parents and reports a warning:
  /// a polymorphic column can legitimately hold a type this application
  /// does not model, but that has to be said rather than assumed.
  final Map<String, MssqlTableBinding<Object?>> targets;

  /// What to do with a discriminator the [targets] map does not name.
  final MssqlMorphUnknown unknown;
}

/// One relation between two tables, derived from a foreign key.
///
/// Generated code declares these; nothing here is guessed at runtime.
@immutable
class MssqlRelation<TParent, TChild> {
  MssqlRelation({
    required this.name,
    required this.kind,
    required this.targetBinding,
    required List<String> localColumns,
    required List<String> foreignColumns,
    List<MssqlOrder> orderBy = const <MssqlOrder>[],
    List<MssqlCondition> where = const <MssqlCondition>[],
    List<MssqlRelation<TChild, Object?>> nested = const [],
    this.perParentLimit,
    this.rowLimit,
    this.strategy = MssqlIncludeStrategy.batch,
    this.scope = const MssqlScopeSelection.empty(),
    this.through,
    this.morph,
  }) : localColumns = List<String>.unmodifiable(localColumns),
       foreignColumns = List<String>.unmodifiable(foreignColumns),
       orderBy = List<MssqlOrder>.unmodifiable(orderBy),
       where = List<MssqlCondition>.unmodifiable(where),
       nested = List<MssqlRelation<TChild, Object?>>.unmodifiable(nested) {
    if (this.localColumns.length != this.foreignColumns.length) {
      throw ArgumentError(
        'Relation "$name" pairs ${this.localColumns.length} local columns with '
        '${this.foreignColumns.length} foreign ones.',
      );
    }
    if (this.localColumns.isEmpty) {
      throw ArgumentError('Relation "$name" names no columns.');
    }
    if (needsThrough && through == null) {
      throw ArgumentError(
        'Relation "$name" is ${kind.name} and needs a through table.',
      );
    }
    if (needsMorph && morph == null) {
      throw ArgumentError(
        'Relation "$name" is ${kind.name} and needs a morph declaration.',
      );
    }
    if (perParentLimit != null && perParentLimit! <= 0) {
      throw ArgumentError.value(
        perParentLimit,
        'takePerParent',
        'Relation "$name" needs a positive per-parent limit. Zero or '
            'negative would look like "loaded and none".',
      );
    }
    if (rowLimit != null && rowLimit! <= 0) {
      throw ArgumentError.value(
        rowLimit,
        'maxLoadedRows',
        'Relation "$name" needs a positive load ceiling.',
      );
    }
    if (strategy == MssqlIncludeStrategy.join && !isToOne) {
      throw ArgumentError(
        'Relation "$name" is ${kind.name}; join strategy is only for to-one. '
        'A to-many join would multiply parent rows, so it stays split.',
      );
    }
    if (strategy == MssqlIncludeStrategy.join &&
        (needsThrough || kind == MssqlRelationKind.morphTo)) {
      throw ArgumentError(
        'Relation "$name" cannot use join strategy: through and morphTo '
        'loads are already more than one table.',
      );
    }
  }

  /// The field name on the parent row.
  final String name;

  final MssqlRelationKind kind;

  /// What to read the other side out of.
  final MssqlTableBinding<TChild> targetBinding;

  /// Columns on the parent, paired positionally with [foreignColumns].
  final List<String> localColumns;

  /// Columns on the target.
  final List<String> foreignColumns;

  /// How to order the loaded children. Meaningless for a to-one relation.
  final List<MssqlOrder> orderBy;

  /// Extra predicates on the target (and, for through, not on the pivot).
  final List<MssqlCondition> where;

  /// Per-parent ceiling, applied with `ROW_NUMBER() OVER (PARTITION BY …)`.
  ///
  /// Distinct from [rowLimit], which is a ceiling on the whole load.
  /// Without a partition, the first parent in a batch can consume the
  /// entire limit and leave the rest looking empty.
  final int? perParentLimit;

  /// A ceiling on the *whole* load, not per parent.
  ///
  /// Hitting it marks the relation truncated rather than returning a short
  /// list that looks complete. The getter then throws
  /// [MssqlRelationTruncatedException] instead of handing the partial set
  /// back as if it were the whole.
  final int? rowLimit;

  /// [MssqlIncludeStrategy.batch] unless a to-one caller asked for a join.
  final MssqlIncludeStrategy strategy;

  /// Target (and pivot) scope selection: trash and named scopes.
  final MssqlScopeSelection scope;

  /// Relations to load one level further down.
  final List<MssqlRelation<TChild, Object?>> nested;

  /// The middle table, for the shapes that have one.
  final MssqlRelationThrough? through;

  /// The type/id columns, for the polymorphic shapes.
  final MssqlMorph? morph;

  bool get isToOne => const <MssqlRelationKind>{
    MssqlRelationKind.belongsTo,
    MssqlRelationKind.hasOne,
    MssqlRelationKind.hasOneThrough,
    MssqlRelationKind.morphTo,
    MssqlRelationKind.morphOne,
  }.contains(kind);

  /// Same handle with the child type forgotten.
  ///
  /// [MssqlRelation] is invariant in [TChild], so a list of mixed
  /// counterparts (`customer` and `lines`) cannot be given a single child
  /// argument. The object is unchanged; only the static type is.
  MssqlRelation<TParent, Object?> get asInclude =>
      this as MssqlRelation<TParent, Object?>;

  bool get needsThrough => const <MssqlRelationKind>{
    MssqlRelationKind.belongsToMany,
    MssqlRelationKind.hasOneThrough,
    MssqlRelationKind.hasManyThrough,
    MssqlRelationKind.morphToMany,
  }.contains(kind);

  bool get needsMorph => const <MssqlRelationKind>{
    MssqlRelationKind.morphTo,
    MssqlRelationKind.morphOne,
    MssqlRelationKind.morphMany,
  }.contains(kind);

  /// This relation with an ordering.
  MssqlRelation<TParent, TChild> ordered(List<MssqlOrder> terms) =>
      _copy(orderBy: terms);

  /// This relation with extra target predicates, ANDed.
  MssqlRelation<TParent, TChild> filtered(List<MssqlCondition> extra) =>
      _copy(where: <MssqlCondition>[...where, ...extra]);

  /// Per-parent limit via `ROW_NUMBER() OVER (PARTITION BY fk …)`.
  MssqlRelation<TParent, TChild> takePerParent(int rows) =>
      _copy(perParentLimit: rows);

  /// Ceiling on the whole load. Hitting it is truncated, not a short list.
  MssqlRelation<TParent, TChild> maxLoadedRows(int rows) =>
      _copy(rowLimit: rows);

  /// Explicit to-one LEFT JOIN instead of `IN (…)` batching.
  MssqlRelation<TParent, TChild> joined() =>
      _copy(strategy: MssqlIncludeStrategy.join);

  /// Target scope: include soft-deleted children.
  MssqlRelation<TParent, TChild> withTrashed() =>
      _copy(scope: scope.withTrashed());

  /// Target scope: only soft-deleted children.
  MssqlRelation<TParent, TChild> onlyTrashed() =>
      _copy(scope: scope.onlyTrashed());

  /// Entity include always maps a full child row. A DTO belongs on the
  /// parent query's [select], not here: dropping columns would make
  /// `fromRow` invent nulls for fields the SELECT never returned.
  MssqlRelation<TParent, TChild> select(List<MssqlExpression> _) {
    throw StateError(
      'Relation "$name" cannot project a subset of columns: the child is '
      'mapped as a full ${targetBinding.qualifiedName} row. Use a parent '
      'MssqlProjection when the result should be a DTO, not an entity graph.',
    );
  }

  /// This relation, then one of the target's own.
  MssqlRelation<TParent, TChild> then<TNested>(
    MssqlRelation<TChild, TNested> relation,
  ) => _copy(
    nested: <MssqlRelation<TChild, Object?>>[...nested, relation.asInclude],
  );

  /// Nested includes of the target, merged with any already present.
  MssqlRelation<TParent, TChild> withNested(
    Iterable<MssqlRelation<TChild, Object?>> relations,
  ) => _copy(
    nested: mergeIncludes<TChild>(
      nested,
      List<MssqlRelation<TChild, Object?>>.of(relations),
    ),
  );

  MssqlRelation<TParent, TChild> _copy({
    List<MssqlOrder>? orderBy,
    List<MssqlCondition>? where,
    int? perParentLimit,
    int? rowLimit,
    MssqlIncludeStrategy? strategy,
    MssqlScopeSelection? scope,
    List<MssqlRelation<TChild, Object?>>? nested,
  }) => MssqlRelation<TParent, TChild>(
    name: name,
    kind: kind,
    targetBinding: targetBinding,
    localColumns: localColumns,
    foreignColumns: foreignColumns,
    orderBy: orderBy ?? this.orderBy,
    where: where ?? this.where,
    perParentLimit: perParentLimit ?? this.perParentLimit,
    rowLimit: rowLimit ?? this.rowLimit,
    strategy: strategy ?? this.strategy,
    scope: scope ?? this.scope,
    nested: nested ?? this.nested,
    through: through,
    morph: morph,
  );

  @override
  String toString() =>
      'MssqlRelation($name: ${kind.name} -> ${targetBinding.qualifiedName})';
}

/// The key of one row, for grouping loaded children against their parents.
///
/// A composite key needs a value type: a `List` compares by identity, so it
/// cannot be a map key.
@immutable
class MssqlRelationKey {
  MssqlRelationKey(List<Object?> values)
    : values = List<Object?>.unmodifiable(values);

  final List<Object?> values;

  bool get hasNull => values.any((v) => v == null);

  @override
  bool operator ==(Object other) {
    if (other is! MssqlRelationKey) return false;
    if (other.values.length != values.length) return false;
    for (var i = 0; i < values.length; i++) {
      if (other.values[i] != values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(values);

  @override
  String toString() => 'MssqlRelationKey(${values.join(', ')})';
}

/// Builds the predicate that fetches children for one batch of parent keys.
///
/// A single column becomes `IN (…)`. A composite key cannot, so it becomes
/// OR-ed equality groups — `(A = @a0 AND B = @b0) OR …` — which is the same
/// query shape and the same number of round trips.
MssqlCondition relationPredicate(
  List<String> foreignColumns,
  List<MssqlRelationKey> keys,
) {
  if (keys.isEmpty) {
    throw ArgumentError.value(
      keys,
      'keys',
      'Cannot build a predicate for none.',
    );
  }
  if (foreignColumns.length == 1) {
    return Col(
      foreignColumns.single,
    ).inList(keys.map((k) => k.values.single).toList());
  }
  return or(<MssqlCondition>[
    for (final key in keys)
      and(<MssqlCondition>[
        for (var i = 0; i < foreignColumns.length; i++)
          Col(foreignColumns[i]).eq(key.values[i]),
      ]),
  ]);
}

/// SQL Server accepts 2100 parameters in one statement. 2000 leaves room for
/// whatever else the query binds and keeps the arithmetic obvious.
const int relationParameterCeiling = 2000;

/// Splits [keys] into batches that stay under the parameter ceiling.
///
/// Hitting the ceiling would otherwise surface as a server error on whichever
/// customer happened to have too many orders.
List<List<MssqlRelationKey>> batchKeys(
  List<MssqlRelationKey> keys,
  int columnsPerKey, {
  int extraParameters = 0,
}) {
  if (columnsPerKey <= 0) {
    throw ArgumentError.value(
      columnsPerKey,
      'columnsPerKey',
      'A relation key needs at least one column.',
    );
  }
  final budget = (relationParameterCeiling - extraParameters).clamp(
    1,
    relationParameterCeiling,
  );
  final perBatch = (budget ~/ columnsPerKey).clamp(1, 100000);
  final out = <List<MssqlRelationKey>>[];
  for (var start = 0; start < keys.length; start += perBatch) {
    final end = start + perBatch < keys.length ? start + perBatch : keys.length;
    out.add(keys.sublist(start, end));
  }
  return out;
}

/// Groups rows by [columns] using each column's codec key, not Dart `==`.
///
/// A `uniqueidentifier` or a collated string compared as Dart values can
/// split one SQL key into two map keys; the codec is the same object the
/// predicate binds with.
MssqlRelationKey relationKeyOf<T>(
  MssqlTableBinding<T> binding,
  List<String> columns,
  Map<String, Object?> values,
) {
  return MssqlRelationKey(<Object?>[
    for (final name in columns) _codecKey(binding, name, values[name]),
  ]);
}

Object? _codecKey<T>(
  MssqlTableBinding<T> binding,
  String column,
  Object? value,
) {
  if (value == null) return null;
  final bound = binding.column(column);
  if (bound == null) return value;
  return bound.keyValue(value);
}

/// Merges two include lists by relation name.
///
/// The same path is folded so `include(customer)` then `include(customer.then(x))`
/// is one load. Conflicting filter, order, limit, strategy or trash scope is
/// an error rather than a silent pick.
List<MssqlRelation<TParent, Object?>> mergeIncludes<TParent>(
  List<MssqlRelation<TParent, Object?>> current,
  List<MssqlRelation<TParent, Object?>> extra, {
  String path = '',
}) {
  if (extra.isEmpty) return current;
  final byName = <String, MssqlRelation<TParent, Object?>>{
    for (final relation in current) relation.name: relation,
  };
  for (final relation in extra) {
    final here = path.isEmpty ? relation.name : '$path.${relation.name}';
    final existing = byName[relation.name];
    if (existing == null) {
      byName[relation.name] = relation;
      continue;
    }
    _assertCompatible(here, existing, relation);
    byName[relation.name] = existing.withNested(relation.nested);
  }
  return byName.values.toList(growable: false);
}

void _assertCompatible<TParent>(
  String path,
  MssqlRelation<TParent, Object?> a,
  MssqlRelation<TParent, Object?> b,
) {
  if (a.kind != b.kind ||
      a.targetBinding.qualifiedName != b.targetBinding.qualifiedName) {
    throw MssqlIncludeConflictException(
      path: path,
      reason: 'different target or kind',
    );
  }
  if (!_sameList(a.where, b.where)) {
    throw MssqlIncludeConflictException(path: path, reason: 'different where');
  }
  if (!_sameList(a.orderBy, b.orderBy)) {
    throw MssqlIncludeConflictException(
      path: path,
      reason: 'different orderBy',
    );
  }
  if (a.perParentLimit != b.perParentLimit) {
    throw MssqlIncludeConflictException(
      path: path,
      reason: 'different takePerParent',
    );
  }
  if (a.rowLimit != b.rowLimit) {
    throw MssqlIncludeConflictException(
      path: path,
      reason: 'different maxLoadedRows',
    );
  }
  if (a.strategy != b.strategy) {
    throw MssqlIncludeConflictException(
      path: path,
      reason: 'different strategy',
    );
  }
  if (a.scope != b.scope) {
    throw MssqlIncludeConflictException(
      path: path,
      reason: 'different trash/scope selection',
    );
  }
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
