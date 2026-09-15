import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../expression.dart';
import '../operators.dart';
import 'binding.dart';
import 'exception.dart';
import 'query_context.dart';
import 'relation.dart';
import 'scope.dart';
import 'transaction_support.dart';
import 'watch.dart';
import 'write_commands.dart';

/// Explicit writes against one relation of one parent row.
///
/// Not a change tracker and not a cascade: [create] fills the foreign key
/// on insert, [associate] / [dissociate] rewrite declared key columns, and
/// [attach] / [detach] / [sync] speak only to a declared pivot. Target rows
/// that are not the parent are never deleted here — a missing counterpart
/// after [detach] is a dangling child the caller still owns.
@immutable
class MssqlRelationMutation<TParent, TChild> {
  MssqlRelationMutation({
    required this.session,
    required this.dialect,
    required this.clock,
    required this.parentBinding,
    required this.parent,
    required this.relation,
    this.scope = const MssqlScopeSelection.empty(),
    this.changes,
  });

  final MssqlSession session;
  final MssqlDialect dialect;
  final MssqlClock clock;
  final MssqlTableBinding<TParent> parentBinding;
  final TParent parent;
  final MssqlRelation<TParent, TChild> relation;
  final MssqlScopeSelection scope;
  final MssqlChangeHub? changes;

  /// Inserts [child] with this parent's key written onto the foreign key.
  ///
  /// `belongsTo` is associate, not create: the foreign key lives on the
  /// parent. `hasOneThrough` / `hasManyThrough` have no owned write surface.
  /// A belongs-to-many insert stores the child and the pivot in one
  /// transaction so a failed link does not leave an orphan row the caller
  /// never asked to keep.
  Future<TChild> create(
    TChild child, {
    Map<String, Object?> pivot = const <String, Object?>{},
  }) {
    switch (relation.kind) {
      case MssqlRelationKind.hasOne:
      case MssqlRelationKind.hasMany:
      case MssqlRelationKind.morphOne:
      case MssqlRelationKind.morphMany:
        return _insertChild(child);
      case MssqlRelationKind.belongsToMany:
      case MssqlRelationKind.morphToMany:
        return _transact((s) async {
          final written = await copy(s)._insertChild(child);
          await copy(s)._attachRow(written, pivot);
          return written;
        });
      case MssqlRelationKind.belongsTo:
      case MssqlRelationKind.morphTo:
        throw StateError(
          'create() on "${relation.name}" is ${relation.kind.name}: the '
          'foreign key lives on ${parentBinding.qualifiedName}. Call '
          'associate() for an existing counterpart, or insert the child '
          'table directly.',
        );
      case MssqlRelationKind.hasOneThrough:
      case MssqlRelationKind.hasManyThrough:
        throw StateError(
          'create() on "${relation.name}" is ${relation.kind.name}: there '
          'is no owned foreign key or declared pivot to write. Insert the '
          'intermediate row yourself.',
        );
    }
  }

  /// Points this parent at [related], or [related] at this parent.
  ///
  /// `belongsTo` / `morphTo` rewrite the parent's key columns. `hasOne` /
  /// `hasMany` / morph-one/many rewrite the child's. Pivot shapes use
  /// [attach] instead: associating would have to invent a pivot row.
  Future<void> associate(TChild related) async {
    switch (relation.kind) {
      case MssqlRelationKind.belongsTo:
      case MssqlRelationKind.morphTo:
        await _updateParentKeys(_parentKeyAssignments(related));
        return;
      case MssqlRelationKind.hasOne:
      case MssqlRelationKind.hasMany:
      case MssqlRelationKind.morphOne:
      case MssqlRelationKind.morphMany:
        await _updateChildKeys(related, _childKeyAssignments());
        return;
      case MssqlRelationKind.belongsToMany:
      case MssqlRelationKind.morphToMany:
      case MssqlRelationKind.hasOneThrough:
      case MssqlRelationKind.hasManyThrough:
        throw StateError(
          'associate() on "${relation.name}" is ${relation.kind.name}. '
          'Use attach() for a declared pivot; through relations have no '
          'single key to rewrite.',
        );
    }
  }

  /// Clears the declared foreign key. Does not delete any row.
  ///
  /// [related] is required for a to-many: nulling every child's key would
  /// be a silent mass write. A non-nullable key column is refused rather
  /// than written as NULL.
  Future<void> dissociate({TChild? related}) async {
    switch (relation.kind) {
      case MssqlRelationKind.belongsTo:
      case MssqlRelationKind.morphTo:
        await _updateParentKeys(_nullParentKeys());
        return;
      case MssqlRelationKind.hasOne:
      case MssqlRelationKind.morphOne:
        if (related != null) {
          await _updateChildKeys(related, _nullChildKeys());
          return;
        }
        await _nullMatchingChildren();
        return;
      case MssqlRelationKind.hasMany:
      case MssqlRelationKind.morphMany:
        if (related == null) {
          throw StateError(
            'dissociate() on to-many "${relation.name}" needs the child '
            'row whose foreign key to clear. Passing none would null every '
            'matching child. delete() is a different decision and is not '
            'implied here.',
          );
        }
        await _updateChildKeys(related, _nullChildKeys());
        return;
      case MssqlRelationKind.belongsToMany:
      case MssqlRelationKind.morphToMany:
        throw StateError(
          'dissociate() on "${relation.name}" is a pivot relation. Use '
          'detach() to remove the link row without touching the target.',
        );
      case MssqlRelationKind.hasOneThrough:
      case MssqlRelationKind.hasManyThrough:
        throw StateError(
          'dissociate() on "${relation.name}" is ${relation.kind.name}: '
          'there is no owned foreign key to clear.',
        );
    }
  }

  /// Inserts a pivot row linking [related] to this parent.
  ///
  /// [pivot] may name extra columns on the declared middle table. Near, far
  /// and morph type columns are taken from the two rows and refused as
  /// extras — a second value for the same key would silently disagree.
  /// The target row is not inserted and not deleted.
  Future<void> attach(
    TChild related, {
    Map<String, Object?> pivot = const <String, Object?>{},
  }) => _attachRow(related, pivot);

  /// Removes the pivot row for [related]. The target row stays.
  Future<void> detach(TChild related) async {
    final through = _requirePivot('detach');
    final parentKey = _parentLocalValues();
    final childKey = _childForeignValues(related);
    await _pivotEngine(session).deleteWhere(
      operation: 'detach',
      where: <MssqlCondition>[
        _pivotNear(through, parentKey),
        _pivotFar(through, childKey),
        ..._pivotType(through),
      ],
      scopes: _pivotScopes(through),
    );
  }

  /// Removes every pivot row for this parent. Target rows stay.
  Future<void> detachAll() async {
    final through = _requirePivot('detachAll');
    await _pivotEngine(session).deleteWhere(
      operation: 'detachAll',
      where: <MssqlCondition>[
        _pivotNear(through, _parentLocalValues()),
        ..._pivotType(through),
      ],
      scopes: _pivotScopes(through),
    );
  }

  /// Makes the pivot match [related] and nothing else.
  ///
  /// Existing extra pivot columns on a key that stays are left alone:
  /// sync is about membership, not about wiping unknown attributes.
  /// Target rows that drop out of the set are not deleted.
  ///
  /// More than one statement always runs inside a transaction, so a
  /// failed insert cannot keep a partial detach.
  Future<void> sync(Iterable<TChild> related, {bool detaching = true}) {
    _requirePivot('sync');
    return _transact((s) => copy(s)._sync(related, detaching: detaching));
  }

  /// This mutation against another session, for a transaction body.
  MssqlRelationMutation<TParent, TChild> copy(MssqlSession session) =>
      MssqlRelationMutation<TParent, TChild>(
        session: session,
        dialect: dialect,
        clock: clock,
        parentBinding: parentBinding,
        parent: parent,
        relation: relation,
        scope: scope,
      );

  Future<void> _sync(
    Iterable<TChild> related, {
    required bool detaching,
  }) async {
    final through = relation.through!;
    final desired = <MssqlRelationKey>{
      for (final child in related) _childForeignKey(child),
    };
    for (final key in desired) {
      if (key.hasNull) {
        throw ArgumentError.value(
          key,
          'related',
          'sync("${relation.name}") got a child whose key is null. A '
              'pivot cannot name a row it cannot identify.',
        );
      }
    }
    final existing = await _existingFarKeys(through);
    if (detaching) {
      final extra = existing.where((k) => !desired.contains(k)).toList();
      if (extra.isNotEmpty) {
        await _pivotEngine(session).deleteWhere(
          operation: 'sync',
          where: <MssqlCondition>[
            _pivotNear(through, _parentLocalValues()),
            ..._pivotType(through),
            relationPredicate(through.farColumns, extra),
          ],
          scopes: _pivotScopes(through),
        );
      }
    }
    final missing = <MssqlRelationKey>[
      for (final key in desired)
        if (!existing.contains(key)) key,
    ];
    for (final key in missing) {
      await _insertPivot(through, far: key.values, extra: const {});
    }
  }

  Future<Set<MssqlRelationKey>> _existingFarKeys(
    MssqlRelationThrough through,
  ) async {
    final context = MssqlQueryContext<Object?>(
      session: session,
      binding: through.binding,
      dialect: dialect,
      clock: clock,
    );
    var query = context.scopedQuery(relation.scope).select(<MssqlExpression>[
      for (final name in through.farColumns) Col(name),
    ]);
    query = query.where(_pivotNear(through, _parentLocalValues()));
    for (final condition in _pivotType(through)) {
      query = query.where(condition);
    }
    final statement = query.compile(dialect: dialect);
    final rows = await session.queryTypedRows(
      statement.sql,
      parameters: statement.parameters,
    );
    return <MssqlRelationKey>{
      for (final row in rows)
        MssqlRelationKey(<Object?>[
          for (var i = 0; i < through.farColumns.length; i++) row.at(i),
        ]),
    };
  }

  Future<void> _attachRow(TChild related, Map<String, Object?> extra) async {
    final through = _requirePivot('attach');
    await _insertPivot(
      through,
      far: _childForeignValues(related),
      extra: extra,
    );
  }

  Future<void> _insertPivot(
    MssqlRelationThrough through, {
    required List<Object?> far,
    required Map<String, Object?> extra,
  }) async {
    final near = _parentLocalValues();
    final reserved = <String>{
      ...through.nearColumns.map((c) => c.toLowerCase()),
      ...through.farColumns.map((c) => c.toLowerCase()),
      if (through.typeColumn != null) through.typeColumn!.toLowerCase(),
    };
    final values = <String, MssqlWriteValue>{};
    for (var i = 0; i < through.nearColumns.length; i++) {
      final column = _requireColumn(through.binding, through.nearColumns[i]);
      values[column.name] = MssqlBoundValue(column.bind(near[i]));
    }
    for (var i = 0; i < through.farColumns.length; i++) {
      final column = _requireColumn(through.binding, through.farColumns[i]);
      values[column.name] = MssqlBoundValue(column.bind(far[i]));
    }
    if (through.typeValue != null) {
      final column = _requireColumn(through.binding, through.typeColumn!);
      values[column.name] = MssqlBoundValue(column.bind(through.typeValue));
    }
    for (final entry in extra.entries) {
      if (reserved.contains(entry.key.toLowerCase())) {
        throw ArgumentError.value(
          entry.key,
          'pivot',
          'attach("${relation.name}") already fills "${entry.key}" from '
              'the two rows. Extra pivot values cannot rename the link.',
        );
      }
      final column = through.binding.column(entry.key);
      if (column == null) {
        throw ArgumentError.value(
          entry.key,
          'pivot',
          '${through.binding.qualifiedName} has no column "${entry.key}".',
        );
      }
      if (!column.writable) {
        throw ArgumentError.value(
          entry.key,
          'pivot',
          '"${entry.key}" is not writable on '
              '${through.binding.qualifiedName}.',
        );
      }
      values[column.name] = MssqlBoundValue(column.bind(entry.value));
    }
    await _pivotEngine(session).insertRow(
      _stampInsert(through.binding, MssqlWriteAssignments(values)),
      readRow: false,
    );
  }

  Future<TChild> _insertChild(TChild child) async {
    final binding = relation.targetBinding;
    _checkDecimal(binding);
    final source = Map<String, Object?>.of(binding.columnsOf(child));
    _writeChildForeignKeys(source);
    final assignments = _stampInsert(binding, _assignments(binding, source));
    final outcome = await _engine(binding, session).insertRow(assignments);
    if (outcome.rows.isNotEmpty) {
      return binding.fromRow(outcome.rows.first);
    }
    return child;
  }

  void _writeChildForeignKeys(Map<String, Object?> child) {
    final parent = parentBinding.columnsOf(this.parent);
    for (var i = 0; i < relation.localColumns.length; i++) {
      final local = relation.localColumns[i];
      final foreign = relation.foreignColumns[i];
      final value = _lookup(parent, local);
      if (value == null) {
        throw StateError(
          'create("${relation.name}") needs parent column "$local", which '
          'is null on this ${parentBinding.qualifiedName} row.',
        );
      }
      final existing = _lookup(child, foreign);
      if (existing != null && existing != value) {
        throw StateError(
          'create("${relation.name}") would overwrite $foreign=$existing '
          'with the parent\'s $local=$value. Pass a child whose foreign '
          'key is unset, or associate() an existing row.',
        );
      }
      _put(child, foreign, value);
    }
    final morph = relation.morph;
    if (morph?.typeValue != null) {
      _put(child, morph!.typeColumn, morph.typeValue);
    }
  }

  Future<void> _updateParentKeys(MssqlWriteAssignments values) async {
    _checkDecimal(parentBinding);
    final parent = parentBinding.columnsOf(this.parent);
    await _engine(parentBinding, session).updateWhere(
      operation: 'associate',
      values: _stampUpdate(parentBinding, values),
      where: _keyWhere(parentBinding, parent),
      scopes: MssqlScopeCompiler(parentBinding, scope).readConditions,
    );
  }

  Future<void> _updateChildKeys(
    TChild related,
    MssqlWriteAssignments values,
  ) async {
    final binding = relation.targetBinding;
    _checkDecimal(binding);
    final child = binding.columnsOf(related);
    await _engine(binding, session).updateWhere(
      operation: 'associate',
      values: _stampUpdate(binding, values),
      where: _keyWhere(binding, child),
      scopes: MssqlScopeCompiler(binding, relation.scope).readConditions,
    );
  }

  Future<void> _nullMatchingChildren() async {
    final binding = relation.targetBinding;
    _checkDecimal(binding);
    await _engine(binding, session).updateWhere(
      operation: 'dissociate',
      values: _stampUpdate(binding, _nullChildKeys()),
      where: <MssqlCondition>[_childMatchesParent()],
      scopes: MssqlScopeCompiler(binding, relation.scope).readConditions,
    );
  }

  MssqlWriteAssignments _parentKeyAssignments(TChild related) {
    final child = relation.targetBinding.columnsOf(related);
    final values = <String, MssqlWriteValue>{};
    for (var i = 0; i < relation.localColumns.length; i++) {
      final local = _requireColumn(parentBinding, relation.localColumns[i]);
      final value = _lookup(child, relation.foreignColumns[i]);
      values[local.name] = MssqlBoundValue(local.bind(value));
    }
    final morph = relation.morph;
    if (morph != null && relation.kind == MssqlRelationKind.morphTo) {
      final typeColumn = _requireColumn(parentBinding, morph.typeColumn);
      values[typeColumn.name] = MssqlBoundValue(
        typeColumn.bind(_morphTypeOf(related)),
      );
    }
    return MssqlWriteAssignments(values);
  }

  MssqlWriteAssignments _childKeyAssignments() {
    final parent = parentBinding.columnsOf(this.parent);
    final binding = relation.targetBinding;
    final values = <String, MssqlWriteValue>{};
    for (var i = 0; i < relation.foreignColumns.length; i++) {
      final foreign = _requireColumn(binding, relation.foreignColumns[i]);
      final value = _lookup(parent, relation.localColumns[i]);
      values[foreign.name] = MssqlBoundValue(foreign.bind(value));
    }
    final morph = relation.morph;
    if (morph?.typeValue != null) {
      final typeColumn = _requireColumn(binding, morph!.typeColumn);
      values[typeColumn.name] = MssqlBoundValue(
        typeColumn.bind(morph.typeValue),
      );
    }
    return MssqlWriteAssignments(values);
  }

  MssqlWriteAssignments _nullParentKeys() {
    final values = <String, MssqlWriteValue>{};
    for (final name in relation.localColumns) {
      final column = _requireNullable(parentBinding, name, 'dissociate');
      values[column.name] = MssqlBoundValue(column.nullValue);
    }
    final morph = relation.morph;
    if (morph != null && relation.kind == MssqlRelationKind.morphTo) {
      final typeColumn = _requireNullable(
        parentBinding,
        morph.typeColumn,
        'dissociate',
      );
      values[typeColumn.name] = MssqlBoundValue(typeColumn.nullValue);
    }
    return MssqlWriteAssignments(values);
  }

  MssqlWriteAssignments _nullChildKeys() {
    final binding = relation.targetBinding;
    final values = <String, MssqlWriteValue>{};
    for (final name in relation.foreignColumns) {
      final column = _requireNullable(binding, name, 'dissociate');
      values[column.name] = MssqlBoundValue(column.nullValue);
    }
    final morph = relation.morph;
    if (morph?.typeValue != null) {
      final typeColumn = _requireNullable(
        binding,
        morph!.typeColumn,
        'dissociate',
      );
      values[typeColumn.name] = MssqlBoundValue(typeColumn.nullValue);
    }
    return MssqlWriteAssignments(values);
  }

  MssqlCondition _childMatchesParent() {
    final parent = parentBinding.columnsOf(this.parent);
    final parts = <MssqlCondition>[
      for (var i = 0; i < relation.foreignColumns.length; i++)
        Col(relation.foreignColumns[i]).eq(
          _requireColumn(
            relation.targetBinding,
            relation.foreignColumns[i],
          ).bind(_lookup(parent, relation.localColumns[i])),
        ),
    ];
    final morph = relation.morph;
    if (morph?.typeValue != null) {
      parts.add(Col(morph!.typeColumn).eq(morph.typeValue));
    }
    return parts.length == 1 ? parts.first : and(parts);
  }

  String _morphTypeOf(TChild related) {
    final morph = relation.morph!;
    final qualified = relation.targetBinding.qualifiedName;
    for (final entry in morph.targets.entries) {
      if (entry.value.qualifiedName.toLowerCase() == qualified.toLowerCase()) {
        return entry.key;
      }
    }
    // morphTo associate of a concrete child whose binding is the target.
    final childBinding = relation.targetBinding;
    for (final entry in morph.targets.entries) {
      if (identical(entry.value, childBinding) ||
          entry.value.qualifiedName.toLowerCase() ==
              childBinding.qualifiedName.toLowerCase()) {
        return entry.key;
      }
    }
    throw StateError(
      'associate("${relation.name}") cannot name a morph type for '
      '$qualified: it is not in the declared targets map.',
    );
  }

  List<Object?> _parentLocalValues() {
    final parent = parentBinding.columnsOf(this.parent);
    return <Object?>[
      for (final name in relation.localColumns) _requireValue(parent, name),
    ];
  }

  List<Object?> _childForeignValues(TChild child) {
    final columns = relation.targetBinding.columnsOf(child);
    return <Object?>[
      for (final name in relation.foreignColumns) _requireValue(columns, name),
    ];
  }

  MssqlRelationKey _childForeignKey(TChild child) =>
      MssqlRelationKey(_childForeignValues(child));

  MssqlCondition _pivotNear(
    MssqlRelationThrough through,
    List<Object?> parentKey,
  ) {
    final parts = <MssqlCondition>[
      for (var i = 0; i < through.nearColumns.length; i++)
        Col(through.nearColumns[i]).eq(
          _requireColumn(
            through.binding,
            through.nearColumns[i],
          ).bind(parentKey[i]),
        ),
    ];
    return parts.length == 1 ? parts.first : and(parts);
  }

  MssqlCondition _pivotFar(
    MssqlRelationThrough through,
    List<Object?> childKey,
  ) {
    final parts = <MssqlCondition>[
      for (var i = 0; i < through.farColumns.length; i++)
        Col(through.farColumns[i]).eq(
          _requireColumn(
            through.binding,
            through.farColumns[i],
          ).bind(childKey[i]),
        ),
    ];
    return parts.length == 1 ? parts.first : and(parts);
  }

  List<MssqlCondition> _pivotType(MssqlRelationThrough through) {
    if (through.typeValue == null) return const <MssqlCondition>[];
    return <MssqlCondition>[Col(through.typeColumn!).eq(through.typeValue)];
  }

  List<MssqlCondition> _pivotScopes(MssqlRelationThrough through) =>
      MssqlScopeCompiler(through.binding, relation.scope).readConditions;

  MssqlRelationThrough _requirePivot(String method) {
    final through = relation.through;
    if (through == null ||
        (relation.kind != MssqlRelationKind.belongsToMany &&
            relation.kind != MssqlRelationKind.morphToMany)) {
      throw StateError(
        '$method() on "${relation.name}" needs a declared belongsToMany '
        'or morphToMany pivot. hasManyThrough is not a pivot: it is a '
        'path through another entity, and writing it would delete or '
        'invent rows this relation does not own.',
      );
    }
    return through;
  }

  List<MssqlCondition> _keyWhere<T>(
    MssqlTableBinding<T> binding,
    Map<String, Object?> columns,
  ) {
    if (!binding.hasPrimaryKey) {
      throw StateError(
        '"${relation.name}" write needs a primary key on '
        '${binding.qualifiedName}.',
      );
    }
    return <MssqlCondition>[
      for (final name in binding.primaryKey)
        Col(
          name,
        ).eq(_requireColumn(binding, name).bind(_requireValue(columns, name))),
    ];
  }

  Object? _requireValue(Map<String, Object?> columns, String name) {
    final value = _lookup(columns, name);
    if (value == null) {
      throw StateError(
        '"${relation.name}" write needs a value for "$name", which is '
        'null on this row.',
      );
    }
    return value;
  }

  MssqlWriteAssignments _assignments<T>(
    MssqlTableBinding<T> binding,
    Map<String, Object?> source,
  ) {
    final values = <String, MssqlWriteValue>{};
    for (final column in binding.writableColumns) {
      if (!_contains(source, column.name)) continue;
      values[column.name] = MssqlBoundValue(
        column.bind(_lookup(source, column.name)),
      );
    }
    return MssqlWriteAssignments(values);
  }

  MssqlWriteAssignments _stampInsert<T>(
    MssqlTableBinding<T> binding,
    MssqlWriteAssignments values,
  ) {
    var out = values;
    final stamps = binding.timestamps;
    for (final name in <String?>[stamps.createdColumn, stamps.updatedColumn]) {
      if (name == null) continue;
      final column = binding.column(name);
      if (column == null || !column.writable) continue;
      final current = out[name];
      final unset =
          current == null ||
          (current is MssqlBoundValue && current.value.value == null);
      if (!unset) continue;
      out = out.withValue(name, MssqlServerValue(clock.expression));
    }
    return out;
  }

  MssqlWriteAssignments _stampUpdate<T>(
    MssqlTableBinding<T> binding,
    MssqlWriteAssignments values,
  ) {
    final name = binding.timestamps.updatedColumn;
    if (name == null || values.isEmpty) return values;
    final column = binding.column(name);
    if (column == null || !column.writable) return values;
    return values.withValue(name, MssqlServerValue(clock.expression));
  }

  MssqlWriteEngine<T> _engine<T>(
    MssqlTableBinding<T> binding,
    MssqlSession session,
  ) => MssqlWriteEngine<T>(
    session,
    binding: binding,
    dialect: dialect,
    changes: changes,
  );

  MssqlWriteEngine<Object?> _pivotEngine(MssqlSession session) =>
      _engine(relation.through!.binding, session);

  void _checkDecimal<T>(MssqlTableBinding<T> binding) {
    final hasExact = binding.columns.any(
      (c) => const <MssqlType>{
        MssqlType.decimal,
        MssqlType.numeric,
        MssqlType.money,
        MssqlType.smallMoney,
      }.contains(c.type),
    );
    if (hasExact && binding.decimalMode != session.config.decimalMode) {
      throw MssqlBindingMismatchException(
        '${binding.qualifiedName} was generated for '
        'MssqlDecimalMode.${binding.decimalMode.name}, but the '
        'connection uses MssqlDecimalMode.${session.config.decimalMode.name}.',
      );
    }
  }

  MssqlBoundColumn _requireColumn<T>(
    MssqlTableBinding<T> binding,
    String name,
  ) {
    final column = binding.column(name);
    if (column == null) {
      throw StateError(
        '${binding.qualifiedName} has no column "$name" named by '
        'relation "${relation.name}".',
      );
    }
    return column;
  }

  MssqlBoundColumn _requireNullable<T>(
    MssqlTableBinding<T> binding,
    String name,
    String method,
  ) {
    final column = _requireColumn(binding, name);
    if (!column.nullable) {
      throw StateError(
        '$method("${relation.name}") would set "$name" to NULL, but '
        '${binding.qualifiedName}.$name is NOT NULL. Clear the link by '
        'pointing it at another row, or change the schema.',
      );
    }
    return column;
  }

  Future<R> _transact<R>(Future<R> Function(MssqlSession session) body) async {
    return mssqlRunAtomic<R>(
      session: session,
      body: body,
      changes: changes,
      unavailableMessage:
          '"${relation.name}" needs a transaction for a multi-statement '
          'write, and this session cannot open one (a pooled handle is the '
          'usual case). Open a connection or an explicit transaction, then '
          'retry.',
    );
  }
}

Object? _lookup(Map<String, Object?> columns, String name) {
  final direct = columns[name];
  if (direct != null || columns.containsKey(name)) return direct;
  final lower = name.toLowerCase();
  for (final entry in columns.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

bool _contains(Map<String, Object?> columns, String name) {
  if (columns.containsKey(name)) return true;
  final lower = name.toLowerCase();
  return columns.keys.any((key) => key.toLowerCase() == lower);
}

void _put(Map<String, Object?> columns, String name, Object? value) {
  final lower = name.toLowerCase();
  for (final key in columns.keys) {
    if (key.toLowerCase() == lower) {
      columns[key] = value;
      return;
    }
  }
  columns[name] = value;
}
