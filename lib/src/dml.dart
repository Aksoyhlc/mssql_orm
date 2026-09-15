import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'dialect.dart';
import 'expression.dart';
import 'query.dart';
import 'runtime/exception.dart';
import 'statement.dart';

/// The `DEFAULT` keyword, as an assignable operand.
///
/// A column's default is not a value this side can compute: it may be
/// `NEWSEQUENTIALID()`, a sequence, or a function over other columns. Binding
/// `null` instead is the mistake this exists to prevent — it writes NULL over
/// the default rather than asking for it, and on a NOT NULL column it turns a
/// working insert into a constraint violation.
///
/// Only legal where SQL Server accepts the keyword: the `VALUES` list of an
/// `INSERT` and the `SET` list of an `UPDATE`. In a predicate the server
/// rejects it; there is no meaningful `WHERE [c] = DEFAULT`.
@immutable
class MssqlDefault extends MssqlExpression {
  const MssqlDefault();

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      'DEFAULT';
}

/// Which pseudo-table an `OUTPUT` column is read from.
enum MssqlOutputSource {
  /// The row as it stands after the write. Populated by `INSERT` and `UPDATE`.
  inserted('INSERTED'),

  /// The row as it stood before the write. Populated by `UPDATE` and `DELETE`.
  deleted('DELETED');

  const MssqlOutputSource(this.prefix);

  /// The pseudo-table's name, as SQL Server spells it.
  final String prefix;
}

/// One column of an `OUTPUT` clause.
@immutable
class MssqlOutputColumn {
  const MssqlOutputColumn(this.source, this.column, {this.as});

  /// The column's value after the write.
  const MssqlOutputColumn.inserted(String column, {String? as})
    : this(MssqlOutputSource.inserted, column, as: as);

  /// The column's value before the write.
  const MssqlOutputColumn.deleted(String column, {String? as})
    : this(MssqlOutputSource.deleted, column, as: as);

  final MssqlOutputSource source;
  final String column;

  /// The result name. Null keeps the column's own name.
  ///
  /// Not usable with `OUTPUT … INTO`: the target's column list decides where
  /// each value lands, and SQL Server rejects an alias there.
  final String? as;

  String get sql {
    final base = '${source.prefix}.${MssqlSql.quoteIdentifier(column)}';
    final alias = as;
    return alias == null ? base : '$base AS ${MssqlSql.quoteIdentifier(alias)}';
  }
}

/// Where an `OUTPUT … INTO` clause puts its rows.
///
/// `INTO` is not an optimisation. A table carrying an enabled trigger makes
/// SQL Server reject a bare `OUTPUT` outright (error 334), so capturing the
/// written keys into a table variable and reading the stored rows back from
/// it is the only readback such a table has.
@immutable
class MssqlOutputTarget {
  /// A real table or table-valued variable named like one.
  MssqlOutputTarget.table(
    MssqlSource source, {
    Iterable<String> columns = const <String>[],
  }) : quoted = source.quoted,
       columns = List<String>.unmodifiable(columns);

  /// A `DECLARE @name TABLE (…)` variable in the same batch.
  ///
  /// The name is checked against SQL Server's rule for a regular variable
  /// rather than quoted, because `@` is part of the name and a quoted
  /// identifier is not a variable.
  MssqlOutputTarget.variable(
    String name, {
    Iterable<String> columns = const <String>[],
  }) : quoted = _checkedVariable(name),
       columns = List<String>.unmodifiable(columns);

  /// The target as it is written, already quoted or already prefixed with `@`.
  final String quoted;

  /// The target's column list, in the order the output columns fill it.
  final List<String> columns;

  static final RegExp _variable = RegExp(r'^@[A-Za-z_][A-Za-z0-9_]*$');

  static String _checkedVariable(String name) {
    final full = name.startsWith('@') ? name : '@$name';
    if (!_variable.hasMatch(full)) {
      throw ArgumentError.value(
        name,
        'name',
        'Is not a SQL Server variable name. Use letters, digits and '
            'underscores, starting with a letter or an underscore.',
      );
    }
    return full;
  }

  String get sql => columns.isEmpty
      ? quoted
      : '$quoted (${columns.map(MssqlSql.quoteIdentifier).join(', ')})';
}

/// An `OUTPUT` clause on an `INSERT`, `UPDATE` or `DELETE`.
///
/// This is how a write reports what it did without a second statement racing
/// against other writers: the rows come from the write itself, so nothing can
/// change them in between.
@immutable
class MssqlOutputClause {
  MssqlOutputClause(Iterable<MssqlOutputColumn> columns, {this.into})
    : columns = List<MssqlOutputColumn>.unmodifiable(columns) {
    if (this.columns.isEmpty) {
      throw ArgumentError.value(
        columns,
        'columns',
        'An OUTPUT clause needs at least one column.',
      );
    }
    final target = into;
    if (target == null) return;
    for (final column in this.columns) {
      if (column.as == null) continue;
      throw ArgumentError.value(
        columns,
        'columns',
        'OUTPUT … INTO takes no column aliases; "${column.as}" would have '
            'nowhere to go. The target\'s column list decides the order.',
      );
    }
    if (target.columns.isNotEmpty &&
        target.columns.length != this.columns.length) {
      throw ArgumentError.value(
        into,
        'into',
        'The target names ${target.columns.length} columns but the clause '
            'outputs ${this.columns.length}.',
      );
    }
  }

  /// Every named column, read from `INSERTED`.
  factory MssqlOutputClause.inserted(
    Iterable<String> columns, {
    MssqlOutputTarget? into,
  }) => MssqlOutputClause(
    columns.map((name) => MssqlOutputColumn.inserted(name)),
    into: into,
  );

  /// Every named column, read from `DELETED`.
  factory MssqlOutputClause.deleted(
    Iterable<String> columns, {
    MssqlOutputTarget? into,
  }) => MssqlOutputClause(
    columns.map((name) => MssqlOutputColumn.deleted(name)),
    into: into,
  );

  final List<MssqlOutputColumn> columns;

  /// Null returns the rows to the caller; non-null diverts them into a table.
  final MssqlOutputTarget? into;

  /// Whether the rows come back as a result set rather than going into a table.
  bool get returnsRows => into == null;

  String get sql {
    final target = into;
    return 'OUTPUT ${columns.map((c) => c.sql).join(', ')}'
        '${target == null ? '' : ' INTO ${target.sql}'}';
  }
}

/// A single-table `INSERT`.
@immutable
class MssqlInsert {
  MssqlInsert._(
    this.source,
    this.assignments,
    this.output,
    this.serverDefaults,
  );

  factory MssqlInsert.into(String identifier) => MssqlInsert._(
    MssqlSource(identifier),
    const <String, Object?>{},
    null,
    false,
  );

  /// The parts-based form; see [MssqlSource.parts].
  factory MssqlInsert.intoParts(List<String> parts) => MssqlInsert._(
    MssqlSource.parts(parts),
    const <String, Object?>{},
    null,
    false,
  );

  final MssqlSource source;
  final Map<String, Object?> assignments;

  /// What the statement reports about the rows it wrote, if anything.
  final MssqlOutputClause? output;

  /// Whether this is an `INSERT … DEFAULT VALUES`.
  final bool serverDefaults;

  MssqlInsert values(Map<String, Object?> columns) => MssqlInsert._(
    source,
    Map<String, Object?>.unmodifiable(<String, Object?>{
      ...assignments,
      ...columns,
    }),
    output,
    serverDefaults,
  );

  /// `INSERT INTO … DEFAULT VALUES`: every column takes its own default.
  ///
  /// The only way to insert into a table whose columns are all identity,
  /// computed or defaulted. Writing `VALUES ()` is not legal T-SQL, and
  /// binding nulls instead would write nulls rather than defaults.
  MssqlInsert defaultValues() =>
      MssqlInsert._(source, assignments, output, true);

  /// Reports the written rows through an `OUTPUT` clause.
  MssqlInsert returning(MssqlOutputClause clause) =>
      MssqlInsert._(source, assignments, clause, serverDefaults);

  /// Builds `INSERT INTO (...) SELECT ...` from a composable query.
  MssqlInsertSelect using(Iterable<String> columns, MssqlSelectQuery query) =>
      MssqlInsertSelect._(source, columns, query, const <MssqlCte>[], null);

  MssqlStatement compile({MssqlDialect dialect = MssqlDialect.sql2012}) {
    if (serverDefaults && assignments.isNotEmpty) {
      throw StateError(
        'INSERT INTO ${source.quoted} says DEFAULT VALUES and also names '
        '${assignments.length} columns; the two contradict. Drop '
        'defaultValues(), and pass const MssqlDefault() for the columns that '
        'should take their default.',
      );
    }
    if (!serverDefaults && assignments.isEmpty) {
      throw StateError(
        'INSERT INTO ${source.quoted} has no values. Call values(), or '
        'defaultValues() if every column is server-generated.',
      );
    }
    final parameters = MssqlParameterAllocator();
    final out = StringBuffer('INSERT INTO ${source.quoted}');
    if (!serverDefaults) {
      final names = <String>[];
      final bound = <String>[];
      for (final entry in assignments.entries) {
        names.add(Col(entry.key).compile(parameters, dialect));
        bound.add(_operandSql(entry.value, parameters, dialect));
      }
      out.write(' (${names.join(', ')})');
      // OUTPUT sits between the column list and VALUES, which is also the
      // order the allocator has to see the parameters in.
      if (output != null) out.write(' ${output!.sql}');
      out.write(' VALUES (${bound.join(', ')})');
    } else {
      if (output != null) out.write(' ${output!.sql}');
      out.write(' DEFAULT VALUES');
    }
    return MssqlStatement.fromAllocator(out.toString(), parameters);
  }
}

/// An `INSERT ... SELECT` statement.
@immutable
class MssqlInsertSelect {
  MssqlInsertSelect._(
    this.source,
    Iterable<String> columns,
    this.query,
    Iterable<MssqlCte> ctes,
    this.output,
  ) : columns = List<String>.unmodifiable(columns),
      ctes = List<MssqlCte>.unmodifiable(ctes) {
    if (this.columns.isEmpty) {
      throw ArgumentError.value(
        columns,
        'columns',
        'INSERT ... SELECT needs at least one target column.',
      );
    }
    final seen = <String>{};
    for (final column in this.columns) {
      final lower = column.toLowerCase();
      if (!seen.add(lower)) {
        throw ArgumentError.value(
          column,
          'columns',
          'A target column may only be named once.',
        );
      }
    }
  }

  final MssqlSource source;
  final List<String> columns;
  final MssqlSelectQuery query;

  /// The `WITH` clause of the whole statement.
  final List<MssqlCte> ctes;

  final MssqlOutputClause? output;

  /// Adds a common table expression to the statement.
  ///
  /// Declared here rather than on [query] because T-SQL puts `WITH` at the
  /// start of the *statement*, before `INSERT` — not between `INSERT` and
  /// `SELECT`, which is where a query that carried its own would end up.
  MssqlInsertSelect withExpression(MssqlCte cte) {
    for (final existing in ctes) {
      if (existing.name.toLowerCase() == cte.name.toLowerCase()) {
        throw ArgumentError.value(
          cte.name,
          'cte',
          'The WITH clause already names an expression "${existing.name}". '
              'Two expressions of one name cannot both be referred to.',
        );
      }
    }
    return MssqlInsertSelect._(source, columns, query, <MssqlCte>[
      ...ctes,
      cte,
    ], output);
  }

  /// Reports the written rows through an `OUTPUT` clause.
  MssqlInsertSelect returning(MssqlOutputClause clause) =>
      MssqlInsertSelect._(source, columns, query, ctes, clause);

  MssqlStatement compile({MssqlDialect dialect = MssqlDialect.sql2012}) {
    if (query is MssqlQuery && (query as MssqlQuery).ctes.isNotEmpty) {
      throw StateError(
        'The SELECT of INSERT INTO ${source.quoted} carries its own WITH '
        'clause, which SQL Server accepts only at the very start of a '
        'statement — before INSERT, not between INSERT and SELECT. Move it '
        'with MssqlInsertSelect.withExpression(); the expression stays '
        'visible to the SELECT.',
      );
    }
    final projected = query.projectionCount;
    if (projected != null && projected != columns.length) {
      throw StateError(
        'INSERT INTO ${source.quoted} names ${columns.length} target columns '
        '(${columns.join(', ')}) but the query projects $projected. Each '
        'target takes the projected expression in the same position, so the '
        'two lists must have the same length and the same order; SQL Server '
        'then converts each value to its target column\'s type, and refuses '
        'the pairs it cannot convert.',
      );
    }
    final parameters = MssqlParameterAllocator();
    final out = StringBuffer();
    if (ctes.isNotEmpty) {
      final written = ctes.map((c) => c.compile(parameters, dialect));
      out.write('WITH ${written.join(', ')} ');
    }
    final names = columns
        .map((name) => Col(name).compile(parameters, dialect))
        .join(', ');
    out.write('INSERT INTO ${source.quoted} ($names)');
    if (output != null) out.write(' ${output!.sql}');
    out.write(' ${query.compileInto(parameters, dialect)}');
    return MssqlStatement.fromAllocator(out.toString(), parameters);
  }
}

/// SQL Server upsert without `MERGE`.
///
/// The first update covers the common path. If no row exists, the guarded
/// insert takes a serializable key-range lock for the duration of that
/// statement. If another writer wins the race, the final update applies this
/// upsert's values to the row it created. A unique index over [matching] is
/// still required: it defines what "the same row" means to the database.
@immutable
class MssqlUpsert {
  MssqlUpsert._(
    this.source,
    Map<String, Object?> matching,
    Map<String, Object?> insertValues,
    Map<String, Object?> updateValues,
  ) : matching = Map<String, Object?>.unmodifiable(matching),
      insertValues = Map<String, Object?>.unmodifiable(insertValues),
      updateValues = Map<String, Object?>.unmodifiable(updateValues) {
    if (this.matching.isEmpty) {
      throw ArgumentError.value(
        matching,
        'matching',
        'Upsert needs at least one conflict-key column.',
      );
    }
    if (this.insertValues.isEmpty) {
      throw ArgumentError.value(
        insertValues,
        'insertValues',
        'Upsert needs values for the insert path.',
      );
    }
    final inserted = this.insertValues.keys.map((e) => e.toLowerCase()).toSet();
    final missing = this.matching.keys.where(
      (key) => !inserted.contains(key.toLowerCase()),
    );
    if (missing.isNotEmpty) {
      throw ArgumentError.value(
        insertValues,
        'insertValues',
        'The insert path is missing matching columns: ${missing.join(', ')}.',
      );
    }
    for (final match in this.matching.entries) {
      final inserted = this.insertValues.entries.firstWhere(
        (entry) => entry.key.toLowerCase() == match.key.toLowerCase(),
      );
      if (!_sameUpsertValue(match.value, inserted.value)) {
        throw ArgumentError.value(
          insertValues,
          'insertValues',
          'The insert value for ${match.key} must equal its matching value.',
        );
      }
    }
  }

  factory MssqlUpsert.into(
    String identifier, {
    required Map<String, Object?> matching,
    required Map<String, Object?> insertValues,
    required Map<String, Object?> updateValues,
  }) => MssqlUpsert._(
    MssqlSource(identifier),
    matching,
    insertValues,
    updateValues,
  );

  /// The parts-based form; see [MssqlSource.parts].
  factory MssqlUpsert.intoParts(
    List<String> parts, {
    required Map<String, Object?> matching,
    required Map<String, Object?> insertValues,
    required Map<String, Object?> updateValues,
  }) => MssqlUpsert._(
    MssqlSource.parts(parts),
    matching,
    insertValues,
    updateValues,
  );

  final MssqlSource source;
  final Map<String, Object?> matching;
  final Map<String, Object?> insertValues;
  final Map<String, Object?> updateValues;

  MssqlStatement compile({MssqlDialect dialect = MssqlDialect.sql2012}) {
    final parameters = MssqlParameterAllocator();

    String matchSql() => matching.entries
        .map((entry) {
          final column = Col(entry.key).compile(parameters, dialect);
          return entry.value == null
              ? '$column IS NULL'
              : '$column = ${_operandSql(entry.value, parameters, dialect)}';
        })
        .join(' AND ');

    String updateSql() => updateValues.entries
        .map(
          (entry) =>
              '${Col(entry.key).compile(parameters, dialect)} = '
              '${_operandSql(entry.value, parameters, dialect)}',
        )
        .join(', ');

    final insertColumns = insertValues.keys
        .map((name) => Col(name).compile(parameters, dialect))
        .join(', ');
    final insertOperands = insertValues.values
        .map((value) => _operandSql(value, parameters, dialect))
        .join(', ');

    final out = StringBuffer();
    if (updateValues.isNotEmpty) {
      out
        ..write('UPDATE ${source.quoted} SET ${updateSql()} ')
        ..write('WHERE ${matchSql()}; ')
        ..write('IF @@ROWCOUNT = 0 BEGIN ');
    }
    out
      ..write('INSERT INTO ${source.quoted} ($insertColumns) ')
      ..write('SELECT $insertOperands WHERE NOT EXISTS (SELECT 1 FROM ')
      ..write(
        '${source.quoted} WITH (UPDLOCK, HOLDLOCK) WHERE ${matchSql()});',
      );
    if (updateValues.isNotEmpty) {
      out
        ..write(' IF @@ROWCOUNT = 0 UPDATE ${source.quoted} ')
        ..write('SET ${updateSql()} WHERE ${matchSql()}; END');
    }
    return MssqlStatement.fromAllocator(out.toString(), parameters);
  }
}

bool _sameUpsertValue(Object? left, Object? right) {
  if (left is MssqlValue && right is MssqlValue) {
    return left.type == right.type &&
        left.value == right.value &&
        left.size == right.size &&
        left.precision == right.precision &&
        left.scale == right.scale;
  }
  return left == right;
}

/// Writes an assigned value.
///
/// A plain value is bound as a parameter, which is what almost every write
/// wants. An [MssqlExpression] is compiled instead, so a column can be set
/// from the server's own clock (`SYSDATETIME()`), from its own current value
/// (`[Hits] + @n`), or from its declared default ([MssqlDefault]) — none of
/// which can travel as a parameter.
String _operandSql(
  Object? value,
  MssqlParameterAllocator parameters,
  MssqlDialect dialect,
) => value is MssqlExpression
    ? value.compile(parameters, dialect)
    : parameters.bind(value);

/// `UPDATE` and `DELETE` both refuse to compile without a predicate.
///
/// A caller who means the whole table says so with `allRows()`, which is
/// explicit and greppable. Rewriting a table by accident becomes impossible
/// rather than one forgotten line away.
void _checkPredicate({
  required List<MssqlCondition> conditions,
  required bool all,
  required String operation,
  required String target,
}) {
  if (conditions.isEmpty && !all) {
    throw MssqlUnsafeWriteException(target, operation);
  }
  if (conditions.isNotEmpty && all) {
    throw StateError(
      '$operation on $target has both where() and allRows(); they contradict. '
      'allRows() means every row, so it cannot be narrowed.',
    );
  }
}

/// A single-table `UPDATE`.
@immutable
class MssqlUpdate {
  MssqlUpdate._(
    this.source,
    this.assignments,
    this.conditions,
    this.all,
    this.output,
  );

  factory MssqlUpdate.table(String identifier) => MssqlUpdate._(
    MssqlSource(identifier),
    const <String, Object?>{},
    const <MssqlCondition>[],
    false,
    null,
  );

  /// The parts-based form; see [MssqlSource.parts].
  factory MssqlUpdate.tableParts(List<String> parts) => MssqlUpdate._(
    MssqlSource.parts(parts),
    const <String, Object?>{},
    const <MssqlCondition>[],
    false,
    null,
  );

  final MssqlSource source;
  final Map<String, Object?> assignments;
  final List<MssqlCondition> conditions;
  final bool all;

  /// What the statement reports about the rows it wrote, if anything.
  final MssqlOutputClause? output;

  MssqlUpdate set(Map<String, Object?> columns) => MssqlUpdate._(
    source,
    Map<String, Object?>.unmodifiable(<String, Object?>{
      ...assignments,
      ...columns,
    }),
    conditions,
    all,
    output,
  );

  MssqlUpdate where(MssqlCondition condition) => MssqlUpdate._(
    source,
    assignments,
    <MssqlCondition>[...conditions, condition],
    all,
    output,
  );

  /// Every row. Deliberate, and greppable.
  MssqlUpdate allRows() =>
      MssqlUpdate._(source, assignments, conditions, true, output);

  /// Reports the written rows through an `OUTPUT` clause.
  MssqlUpdate returning(MssqlOutputClause clause) =>
      MssqlUpdate._(source, assignments, conditions, all, clause);

  MssqlStatement compile({MssqlDialect dialect = MssqlDialect.sql2012}) {
    if (assignments.isEmpty) {
      throw StateError(
        'UPDATE ${source.quoted} sets no columns. Call set() first.',
      );
    }
    _checkPredicate(
      conditions: conditions,
      all: all,
      operation: 'UPDATE',
      target: source.quoted,
    );
    final parameters = MssqlParameterAllocator();
    final sets = <String>[];
    for (final entry in assignments.entries) {
      sets.add(
        '${Col(entry.key).compile(parameters, dialect)} = '
        '${_operandSql(entry.value, parameters, dialect)}',
      );
    }
    final out = StringBuffer('UPDATE ${source.quoted} SET ${sets.join(', ')}');
    // OUTPUT comes after SET and before WHERE, which is also the order the
    // allocator numbers the parameters in.
    if (output != null) out.write(' ${output!.sql}');
    if (conditions.isNotEmpty) {
      out.write(' WHERE ${and(conditions).compile(parameters, dialect)}');
    }
    return MssqlStatement.fromAllocator(out.toString(), parameters);
  }
}

/// A single-table `DELETE`.
@immutable
class MssqlDelete {
  MssqlDelete._(this.source, this.conditions, this.all, this.output);

  factory MssqlDelete.from(String identifier) => MssqlDelete._(
    MssqlSource(identifier),
    const <MssqlCondition>[],
    false,
    null,
  );

  /// The parts-based form; see [MssqlSource.parts].
  factory MssqlDelete.fromParts(List<String> parts) => MssqlDelete._(
    MssqlSource.parts(parts),
    const <MssqlCondition>[],
    false,
    null,
  );

  final MssqlSource source;
  final List<MssqlCondition> conditions;
  final bool all;

  /// What the statement reports about the rows it removed, if anything.
  final MssqlOutputClause? output;

  MssqlDelete where(MssqlCondition condition) => MssqlDelete._(
    source,
    <MssqlCondition>[...conditions, condition],
    all,
    output,
  );

  /// Every row. Deliberate, and greppable.
  MssqlDelete allRows() => MssqlDelete._(source, conditions, true, output);

  /// Reports the removed rows through an `OUTPUT` clause.
  MssqlDelete returning(MssqlOutputClause clause) =>
      MssqlDelete._(source, conditions, all, clause);

  MssqlStatement compile({MssqlDialect dialect = MssqlDialect.sql2012}) {
    _checkPredicate(
      conditions: conditions,
      all: all,
      operation: 'DELETE',
      target: source.quoted,
    );
    final parameters = MssqlParameterAllocator();
    final out = StringBuffer('DELETE FROM ${source.quoted}');
    if (output != null) out.write(' ${output!.sql}');
    if (conditions.isNotEmpty) {
      out.write(' WHERE ${and(conditions).compile(parameters, dialect)}');
    }
    return MssqlStatement.fromAllocator(out.toString(), parameters);
  }
}
