import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../expression.dart';
import '../operators.dart';
import 'binding.dart';
import 'exception.dart';
import 'query_context.dart';
import 'relation.dart';
import 'transaction_support.dart';
import 'watch.dart';
import 'write_commands.dart';

/// What to do when a graph contains a write cycle.
///
/// A cycle of required foreign keys cannot be inserted in one pass. The only
/// sound second pass is "insert with the closing FKs null, then UPDATE", which
/// needs nullable columns.
enum MssqlCycleWrite {
  /// The default: a cycle is a modelling error until the caller says how
  /// to break it.
  refuse,

  /// Insert closing FKs as null, then UPDATE them. Refused when any
  /// closing column is NOT NULL.
  nullThenUpdate,
}

/// One row to insert, plus the relations the caller named for it.
///
/// Only [related] edges are written. A hasMany that is not listed is not
/// touched, and existing child rows are never deleted or overwritten.
@immutable
class MssqlGraphInsert<TRow> {
  const MssqlGraphInsert(this.values, {this.related = const []});

  final MssqlWriteAssignments values;
  final List<MssqlGraphRelation> related;
}

/// One named relation and the graph nodes to write along it.
@immutable
class MssqlGraphRelation {
  const MssqlGraphRelation(this.relation, this.nodes);

  final MssqlRelation<Object?, Object?> relation;
  final List<MssqlGraphInsert<Object?>> nodes;
}

/// Explicit multi-table insert: belongsTo first, parent identity, then
/// children, one transaction, no cascade delete.
@immutable
class MssqlGraphWriter<TRow> {
  MssqlGraphWriter(
    this.session, {
    required this.binding,
    required this.dialect,
    this.clock = MssqlClock.serverUtc,
    this.changes,
  });

  final MssqlSession session;
  final MssqlTableBinding<TRow> binding;
  final MssqlDialect dialect;
  final MssqlClock clock;
  final MssqlChangeHub? changes;

  /// Inserts [graph] and returns the stored root with defaults applied.
  ///
  /// Failures roll every write back. Existing counterpart rows are not
  /// updated or deleted: this is insert, not sync.
  Future<TRow> createGraph(
    MssqlGraphInsert<TRow> graph, {
    MssqlCycleWrite cycle = MssqlCycleWrite.refuse,
  }) {
    Future<TRow> run(MssqlSession s) async {
      final row =
          await MssqlGraphWriter<TRow>(
            s,
            binding: binding,
            dialect: dialect,
            clock: clock,
            changes: changes,
          )._writeNode(
            binding.erase(),
            graph.values,
            graph.related,
            cycle,
            <String>{},
            <_CycleFix>[],
          );
      return row as TRow;
    }

    return _transact(run);
  }

  Future<Object?> _writeNode(
    MssqlTableBinding<Object?> target,
    MssqlWriteAssignments values,
    List<MssqlGraphRelation> related,
    MssqlCycleWrite cycle,
    Set<String> writing,
    List<_CycleFix> fixes,
  ) async {
    final name = target.qualifiedName;
    writing.add(name);
    try {
      var assignments = values;
      final cyclic = <MssqlGraphRelation>[];
      for (final edge in related) {
        _assertOwned(edge.relation);
        switch (edge.relation.kind) {
          case MssqlRelationKind.belongsTo:
          case MssqlRelationKind.morphTo:
            if (edge.nodes.length != 1) {
              throw StateError(
                'createGraph relation "${edge.relation.name}" is '
                '${edge.relation.kind.name} and needs exactly one node, '
                'not ${edge.nodes.length}.',
              );
            }
            final other = edge.relation.targetBinding.qualifiedName;
            if (writing.contains(other)) {
              _refuseOrAllowCycle(target, edge.relation, cycle, name, other);
              cyclic.add(edge);
              continue;
            }
            final parent = await _writeNode(
              edge.relation.targetBinding.erase(),
              edge.nodes.single.values,
              edge.nodes.single.related,
              cycle,
              writing,
              fixes,
            );
            assignments = _fillFromParent(
              assignments,
              target,
              edge.relation,
              parent,
            );
          case MssqlRelationKind.hasOne:
          case MssqlRelationKind.hasMany:
          case MssqlRelationKind.morphOne:
          case MssqlRelationKind.morphMany:
          case MssqlRelationKind.belongsToMany:
          case MssqlRelationKind.morphToMany:
          case MssqlRelationKind.hasOneThrough:
          case MssqlRelationKind.hasManyThrough:
            break;
        }
      }
      final row = await _insert(target, assignments);
      for (final edge in cyclic) {
        fixes.add(
          _CycleFix(
            holder: target,
            child: row,
            relation: edge.relation,
            waitingFor: edge.relation.targetBinding.qualifiedName,
          ),
        );
      }
      for (final edge in related) {
        switch (edge.relation.kind) {
          case MssqlRelationKind.hasOne:
          case MssqlRelationKind.morphOne:
            if (edge.nodes.length > 1) {
              throw StateError(
                'createGraph relation "${edge.relation.name}" is '
                '${edge.relation.kind.name} and accepts at most one node.',
              );
            }
            if (edge.nodes.isEmpty) continue;
            await _writeChild(
              target,
              row,
              edge.relation,
              edge.nodes.single,
              cycle,
              writing,
              fixes,
            );
          case MssqlRelationKind.hasMany:
          case MssqlRelationKind.morphMany:
            for (final node in edge.nodes) {
              await _writeChild(
                target,
                row,
                edge.relation,
                node,
                cycle,
                writing,
                fixes,
              );
            }
          case MssqlRelationKind.belongsToMany:
          case MssqlRelationKind.morphToMany:
            for (final node in edge.nodes) {
              await _writePivotChild(
                target,
                row,
                edge.relation,
                node,
                cycle,
                writing,
                fixes,
              );
            }
          case MssqlRelationKind.belongsTo:
          case MssqlRelationKind.morphTo:
          case MssqlRelationKind.hasOneThrough:
          case MssqlRelationKind.hasManyThrough:
            break;
        }
      }
      for (final fix in List<_CycleFix>.of(fixes)) {
        if (fix.waitingFor == name) {
          await _applyCycleFix(fix, row, target);
          fixes.remove(fix);
        }
      }
      return row;
    } finally {
      writing.remove(name);
    }
  }

  void _refuseOrAllowCycle(
    MssqlTableBinding<Object?> holder,
    MssqlRelation<Object?, Object?> relation,
    MssqlCycleWrite cycle,
    String from,
    String to,
  ) {
    if (cycle == MssqlCycleWrite.refuse) {
      throw StateError(
        'createGraph cycle between $from and $to on "${relation.name}". '
        'Pass cycle: MssqlCycleWrite.nullThenUpdate to insert the closing '
        'keys as null and UPDATE them after, or break the cycle in the '
        'graph you passed.',
      );
    }
    for (final name in relation.localColumns) {
      final column = holder.column(name)!;
      if (!column.nullable) {
        throw StateError(
          'createGraph cycle on "${relation.name}" cannot use '
          'nullThenUpdate: $from.$name is NOT NULL. Make the closing '
          'key nullable, or insert the two rows yourself.',
        );
      }
    }
  }

  Future<void> _applyCycleFix(
    _CycleFix fix,
    Object? ancestor,
    MssqlTableBinding<Object?> ancestorBinding,
  ) async {
    if (!fix.holder.hasPrimaryKey) {
      throw StateError(
        'createGraph nullThenUpdate on ${fix.holder.qualifiedName} needs '
        'a primary key to UPDATE the deferred foreign keys.',
      );
    }
    final parentCols = ancestorBinding.columnsOf(ancestor);
    final childCols = fix.holder.columnsOf(fix.child);
    final values = <String, MssqlWriteValue>{};
    for (var i = 0; i < fix.relation.localColumns.length; i++) {
      final column = fix.holder.column(fix.relation.localColumns[i])!;
      final value = _lookup(parentCols, fix.relation.foreignColumns[i]);
      values[column.name] = MssqlBoundValue(column.bind(value));
    }
    await MssqlWriteEngine<Object?>(
      session,
      binding: fix.holder,
      dialect: dialect,
      changes: changes,
    ).updateWhere(
      operation: 'createGraph.cycle',
      values: MssqlWriteAssignments(values),
      where: <MssqlCondition>[
        for (final name in fix.holder.primaryKey)
          Col(name).eq(fix.holder.column(name)!.bind(_lookup(childCols, name))),
      ],
    );
  }

  Future<void> _writeChild(
    MssqlTableBinding<Object?> parentBinding,
    Object? parent,
    MssqlRelation<Object?, Object?> relation,
    MssqlGraphInsert<Object?> node,
    MssqlCycleWrite cycle,
    Set<String> writing,
    List<_CycleFix> fixes,
  ) async {
    final filled = _fillFromLocal(
      node.values,
      relation.targetBinding.erase(),
      relation,
      parentBinding,
      parent,
    );
    await _writeNode(
      relation.targetBinding.erase(),
      filled,
      node.related,
      cycle,
      writing,
      fixes,
    );
  }

  Future<void> _writePivotChild(
    MssqlTableBinding<Object?> parentBinding,
    Object? parent,
    MssqlRelation<Object?, Object?> relation,
    MssqlGraphInsert<Object?> node,
    MssqlCycleWrite cycle,
    Set<String> writing,
    List<_CycleFix> fixes,
  ) async {
    final through = relation.through;
    if (through == null) {
      throw StateError(
        'createGraph relation "${relation.name}" is ${relation.kind.name} '
        'and needs a declared pivot.',
      );
    }
    final child = await _writeNode(
      relation.targetBinding.erase(),
      node.values,
      node.related,
      cycle,
      writing,
      fixes,
    );
    final values = <String, MssqlWriteValue>{};
    final parentCols = parentBinding.columnsOf(parent);
    final childCols = relation.targetBinding.columnsOf(child);
    for (var i = 0; i < through.nearColumns.length; i++) {
      final column = through.binding.column(through.nearColumns[i])!;
      final value = _lookup(parentCols, relation.localColumns[i]);
      if (value == null) {
        throw StateError(
          'createGraph pivot "${relation.name}" needs parent column '
          '"${relation.localColumns[i]}".',
        );
      }
      values[column.name] = MssqlBoundValue(column.bind(value));
    }
    for (var i = 0; i < through.farColumns.length; i++) {
      final column = through.binding.column(through.farColumns[i])!;
      final value = _lookup(childCols, relation.foreignColumns[i]);
      if (value == null) {
        throw StateError(
          'createGraph pivot "${relation.name}" needs child column '
          '"${relation.foreignColumns[i]}".',
        );
      }
      values[column.name] = MssqlBoundValue(column.bind(value));
    }
    final typeColumn = through.typeColumn;
    final typeValue = through.typeValue;
    if (typeColumn != null && typeValue != null) {
      final column = through.binding.column(typeColumn)!;
      values[column.name] = MssqlBoundValue(column.bind(typeValue));
    }
    await MssqlWriteEngine<Object?>(
      session,
      binding: through.binding,
      dialect: dialect,
      changes: changes,
    ).insertRow(MssqlWriteAssignments(values), readRow: false);
  }

  Future<Object?> _insert(
    MssqlTableBinding<Object?> target,
    MssqlWriteAssignments values,
  ) async {
    final engine = MssqlWriteEngine<Object?>(
      session,
      binding: target,
      dialect: dialect,
      changes: changes,
    );
    var stamped = values;
    final stamps = target.timestamps;
    for (final name in <String?>[stamps.createdColumn, stamps.updatedColumn]) {
      if (name == null) continue;
      final column = target.column(name);
      if (column == null || !column.writable) continue;
      final current = stamped[name];
      final unset =
          current == null ||
          (current is MssqlBoundValue && current.value.value == null);
      if (!unset) continue;
      stamped = stamped.withValue(name, MssqlServerValue(clock.expression));
    }
    final outcome = await engine.insertRow(stamped);
    switch (engine.insertReadback) {
      case MssqlWriteReadback.storedRow:
      case MssqlWriteReadback.keyCapture:
        if (outcome.rows.isEmpty) {
          throw StateError(
            'createGraph on ${target.qualifiedName} stored a row but '
            'reported none back.',
          );
        }
        return target.fromRow(outcome.rows.first);
      case MssqlWriteReadback.identityOnly:
        if (outcome.rows.isEmpty) {
          throw MssqlReadbackUnavailableException(
            table: target.qualifiedName,
            operation: 'createGraph',
            reason: 'SCOPE_IDENTITY() returned no value',
          );
        }
        final identity = target.column(target.identityColumn!)!;
        final id = outcome.rows.first.at(0);
        final found = await session.queryTypedRows(
          'SELECT * FROM ${target.quoted} WHERE '
          '${MssqlSql.quoteIdentifier(identity.name)} = @id',
          parameters: <String, Object?>{'id': identity.bind(id)},
        );
        if (found.isEmpty) {
          throw StateError(
            'createGraph on ${target.qualifiedName} inserted identity $id '
            'but could not read the stored row back.',
          );
        }
        return target.fromRow(found.first);
      case MssqlWriteReadback.none:
        throw MssqlReadbackUnavailableException(
          table: target.qualifiedName,
          operation: 'createGraph',
          reason:
              'the insert did not read the stored row, so child foreign '
              'keys cannot be filled from the parent identity',
        );
    }
  }

  MssqlWriteAssignments _fillFromParent(
    MssqlWriteAssignments child,
    MssqlTableBinding<Object?> childBinding,
    MssqlRelation<Object?, Object?> relation,
    Object? parent,
  ) {
    final parentCols = relation.targetBinding.columnsOf(parent);
    var out = child;
    for (var i = 0; i < relation.localColumns.length; i++) {
      final column = childBinding.column(relation.localColumns[i])!;
      final value = _lookup(parentCols, relation.foreignColumns[i]);
      if (value == null) {
        throw StateError(
          'createGraph "${relation.name}" needs '
          '${relation.targetBinding.qualifiedName}.'
          '${relation.foreignColumns[i]} on the belongsTo parent.',
        );
      }
      _rejectOverwrite(out, column.name, value, relation.name);
      out = out.withValue(column.name, MssqlBoundValue(column.bind(value)));
    }
    return out;
  }

  MssqlWriteAssignments _fillFromLocal(
    MssqlWriteAssignments child,
    MssqlTableBinding<Object?> childBinding,
    MssqlRelation<Object?, Object?> relation,
    MssqlTableBinding<Object?> parentBinding,
    Object? parent,
  ) {
    final parentCols = parentBinding.columnsOf(parent);
    var out = child;
    for (var i = 0; i < relation.localColumns.length; i++) {
      final column = childBinding.column(relation.foreignColumns[i])!;
      final value = _lookup(parentCols, relation.localColumns[i]);
      if (value == null) {
        throw StateError(
          'createGraph "${relation.name}" needs '
          '${parentBinding.qualifiedName}.${relation.localColumns[i]} '
          'on the parent.',
        );
      }
      _rejectOverwrite(out, column.name, value, relation.name);
      out = out.withValue(column.name, MssqlBoundValue(column.bind(value)));
    }
    final morph = relation.morph;
    if (morph?.typeValue != null) {
      final column = childBinding.column(morph!.typeColumn)!;
      out = out.withValue(
        column.name,
        MssqlBoundValue(column.bind(morph.typeValue)),
      );
    }
    return out;
  }

  void _rejectOverwrite(
    MssqlWriteAssignments values,
    String column,
    Object? incoming,
    String relation,
  ) {
    final current = values[column];
    if (current is MssqlBoundValue &&
        current.value.value != null &&
        current.value.value != incoming) {
      throw StateError(
        'createGraph "$relation" would overwrite $column='
        '${current.value.value} with $incoming. Pass a child whose '
        'foreign key is unset.',
      );
    }
  }

  void _assertOwned(MssqlRelation<Object?, Object?> relation) {
    switch (relation.kind) {
      case MssqlRelationKind.hasOneThrough:
      case MssqlRelationKind.hasManyThrough:
        throw StateError(
          'createGraph relation "${relation.name}" is '
          '${relation.kind.name}: there is no owned write surface. Insert '
          'the intermediate row yourself.',
        );
      case MssqlRelationKind.belongsTo:
      case MssqlRelationKind.hasOne:
      case MssqlRelationKind.hasMany:
      case MssqlRelationKind.belongsToMany:
      case MssqlRelationKind.morphTo:
      case MssqlRelationKind.morphOne:
      case MssqlRelationKind.morphMany:
      case MssqlRelationKind.morphToMany:
        return;
    }
  }

  Future<R> _transact<R>(Future<R> Function(MssqlSession session) body) async {
    return mssqlRunAtomic<R>(
      session: session,
      body: body,
      changes: changes,
      unavailableMessage:
          'createGraph on ${binding.qualifiedName} needs a transaction, and '
          'this session cannot open one (a pooled handle is the usual case). '
          'Open a connection or an explicit transaction, then retry.',
    );
  }
}

class _CycleFix {
  const _CycleFix({
    required this.holder,
    required this.child,
    required this.relation,
    required this.waitingFor,
  });

  final MssqlTableBinding<Object?> holder;
  final Object? child;
  final MssqlRelation<Object?, Object?> relation;
  final String waitingFor;
}

Object? _lookup(Map<String, Object?> columns, String name) {
  if (columns.containsKey(name)) return columns[name];
  final lower = name.toLowerCase();
  for (final entry in columns.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}
