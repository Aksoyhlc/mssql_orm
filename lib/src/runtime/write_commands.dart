import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../dml.dart';
import '../expression.dart';
import '../operators.dart';
import '../query.dart';
import '../statement.dart';
import 'binding.dart';
import 'exception.dart';
import 'observer.dart';
import 'watch.dart';

/// One column's contribution to a write.
///
/// The type exists so that "the caller did not mention this column" and "the
/// caller set this column to NULL" stay different things all the way down to
/// the SQL. A map of nullable values cannot tell them apart, and the
/// difference is the whole of a partial update: an absent column keeps what
/// the row already holds, a null column overwrites it.
@immutable
sealed class MssqlWriteValue {
  const MssqlWriteValue();
}

/// A value bound as a parameter, already encoded for its column's SQL type.
///
/// Built through [MssqlBoundColumn.bind] rather than from a raw Dart value:
/// the driver would otherwise infer `nvarchar` for a `varchar` column and
/// `float` for a `decimal` one, which changes what a comparison means and
/// takes the column's index out of play.
@immutable
final class MssqlBoundValue extends MssqlWriteValue {
  const MssqlBoundValue(this.value);

  final MssqlValue value;
}

/// SQL the server evaluates, such as `SYSDATETIME()` or `[Hits] + @n`.
@immutable
final class MssqlServerValue extends MssqlWriteValue {
  const MssqlServerValue(this.expression);

  final MssqlExpression expression;
}

/// The column's declared default, written as the `DEFAULT` keyword.
@immutable
final class MssqlDefaultValue extends MssqlWriteValue {
  const MssqlDefaultValue();
}

/// The columns one write names, and what each of them gets.
///
/// Ordered, because the SQL is written in this order and a reader comparing
/// two logs should not have to sort them first. Absence is meaningful: a
/// column that is not a key here is not named in the statement at all.
@immutable
class MssqlWriteAssignments {
  MssqlWriteAssignments(Map<String, MssqlWriteValue> values)
    : _values = Map<String, MssqlWriteValue>.unmodifiable(
        Map<String, MssqlWriteValue>.of(values),
      );

  /// No columns at all, which every write refuses.
  static final MssqlWriteAssignments empty = MssqlWriteAssignments(
    const <String, MssqlWriteValue>{},
  );

  final Map<String, MssqlWriteValue> _values;

  Iterable<String> get columns => _values.keys;

  Iterable<MapEntry<String, MssqlWriteValue>> get entries => _values.entries;

  int get length => _values.length;

  bool get isEmpty => _values.isEmpty;

  bool get isNotEmpty => _values.isNotEmpty;

  /// Whether [column] was named at all, ignoring case.
  ///
  /// Case-insensitive because a schema's own spelling and a caller's are
  /// routinely different, and a case-sensitive miss here would silently drop
  /// the column from the statement rather than report anything.
  bool contains(String column) {
    final lower = column.toLowerCase();
    return _values.keys.any((name) => name.toLowerCase() == lower);
  }

  MssqlWriteValue? operator [](String column) {
    final lower = column.toLowerCase();
    for (final entry in _values.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// This set with [column] set to [value], replacing any existing entry.
  MssqlWriteAssignments withValue(String column, MssqlWriteValue value) {
    final out = <String, MssqlWriteValue>{};
    var replaced = false;
    for (final entry in _values.entries) {
      if (entry.key.toLowerCase() == column.toLowerCase()) {
        out[entry.key] = value;
        replaced = true;
      } else {
        out[entry.key] = entry.value;
      }
    }
    if (!replaced) out[column] = value;
    return MssqlWriteAssignments(out);
  }

  /// This set without [column], if it was there.
  MssqlWriteAssignments without(String column) =>
      MssqlWriteAssignments(<String, MssqlWriteValue>{
        for (final entry in _values.entries)
          if (entry.key.toLowerCase() != column.toLowerCase())
            entry.key: entry.value,
      });

  /// [other]'s columns on top of these.
  MssqlWriteAssignments merge(MssqlWriteAssignments other) {
    var out = this;
    for (final entry in other.entries) {
      out = out.withValue(entry.key, entry.value);
    }
    return out;
  }

  /// What the DML builders take: an operand per column.
  Map<String, Object?> toOperands() => <String, Object?>{
    for (final entry in _values.entries)
      entry.key: switch (entry.value) {
        MssqlBoundValue(:final value) => value,
        MssqlServerValue(:final expression) => expression,
        MssqlDefaultValue() => const MssqlDefault(),
      },
  };

  @override
  String toString() => 'MssqlWriteAssignments(${_values.keys.join(', ')})';
}

/// What kind of trigger the target table carries.
///
/// Not a detail: it decides which readback SQL Server will even accept, and
/// whether `@@ROWCOUNT` is describing the caller's statement or the trigger's
/// last one.
enum MssqlTriggerKind {
  /// No enabled trigger. `OUTPUT` without `INTO` is allowed, and `@@ROWCOUNT`
  /// read immediately after the statement is that statement's own count.
  none,

  /// An `AFTER` trigger. SQL Server rejects a bare `OUTPUT` (error 334), so
  /// the written keys go into a table variable and the rows are read back
  /// from it. `@@ROWCOUNT` may be the trigger body's, so it is not used.
  after,

  /// An `INSTEAD OF` trigger. The statement the caller wrote never runs, so
  /// nothing the server reports describes it. Readback must be declared.
  insteadOf,
}

/// How a write finds out what it stored.
enum MssqlWriteReadback {
  /// `OUTPUT INSERTED.…` / `OUTPUT DELETED.…` on the statement itself.
  storedRow,

  /// `OUTPUT … INTO @keys`, then a `SELECT` of the stored rows keyed by it.
  keyCapture,

  /// `SELECT CAST(SCOPE_IDENTITY() AS <the column's own type>)`.
  identityOnly,

  /// Nothing is read back.
  none,
}

/// Where an affected-row count came from, so a caller can judge it.
///
/// The driver's own `affectedRows` is the sum of every row-count token the
/// batch produced, which on a table with a trigger includes the trigger
/// body's own writes. That number answers "how much did the server do", not
/// "how many of my rows changed", and the two are routinely different.
enum MssqlAffectedRowsSource {
  /// Counted from the rows the statement's own `OUTPUT` clause produced.
  /// Exact: those rows are the rows the statement wrote.
  outputRows,

  /// `SELECT @@ROWCOUNT` in the same batch, immediately after the statement.
  /// Exact only when no trigger ran, which is why it is used only then.
  immediateRowCount,

  /// A single-row statement that did not throw, so it wrote its one row.
  singleRowStatement,

  /// The driver's batch total, with no way to attribute it. Reported as-is
  /// and marked, rather than dressed up as a per-statement count.
  driverTotal,
}

/// What a write did, and how well that is known.
@immutable
class MssqlWriteOutcome {
  const MssqlWriteOutcome({
    required this.affectedRows,
    required this.affectedRowsSource,
    this.rows = const <MssqlRow>[],
  });

  /// How many of the caller's own rows the statement wrote.
  final int affectedRows;

  /// How [affectedRows] was determined.
  final MssqlAffectedRowsSource affectedRowsSource;

  /// The stored rows, when the write read them back. Empty otherwise, which
  /// is not the same as "the write matched nothing" — check [affectedRows].
  final List<MssqlRow> rows;

  /// Whether [affectedRows] is attributable to this statement alone.
  bool get affectedRowsExact =>
      affectedRowsSource != MssqlAffectedRowsSource.driverTotal;

  @override
  String toString() =>
      'MssqlWriteOutcome($affectedRows rows via ${affectedRowsSource.name})';
}

/// The one place insert, update, delete and upsert are executed.
///
/// Every write path funnels through here so three questions have one answer
/// each rather than one per call site: which readback SQL the target table
/// accepts, how many of the caller's rows actually changed, and what happens
/// to a write whose guard fails.
///
/// Immutable and cheap: [withSession] makes the transaction-scoped copy a
/// guard needs, so nothing here holds mutable state between calls.
@immutable
class MssqlWriteEngine<TRow> {
  MssqlWriteEngine(
    this.session, {
    required this.binding,
    required this.dialect,
    MssqlTriggerKind? triggers,
    this.readback,
    this.changes,
  }) : triggers = triggers ?? _triggersOf(binding.insertStrategy);

  final MssqlSession session;
  final MssqlTableBinding<TRow> binding;
  final MssqlDialect dialect;
  final MssqlChangeHub? changes;

  /// What the target table carries, as generated code described it.
  final MssqlTriggerKind triggers;

  /// The caller's declared strategy, overriding what the table implies.
  ///
  /// The only way to write to a table with an `INSTEAD OF` trigger: the
  /// engine refuses to guess there, because every guess is wrong for some
  /// trigger body.
  final MssqlWriteReadback? readback;

  /// The same engine against another session, which a guard needs when it has
  /// to open a transaction of its own.
  MssqlWriteEngine<TRow> withSession(MssqlSession other) =>
      MssqlWriteEngine<TRow>(
        other,
        binding: binding,
        dialect: dialect,
        triggers: triggers,
        readback: readback,
        changes: changes,
      );

  /// The generator does not record trigger kinds yet; the insert strategy it
  /// does record already answers the only question that matters here, because
  /// `scopeIdentity` is exactly what it chooses for a table whose enabled
  /// trigger makes a bare `OUTPUT` illegal.
  static MssqlTriggerKind _triggersOf(MssqlInsertStrategy strategy) =>
      switch (strategy) {
        MssqlInsertStrategy.scopeIdentity => MssqlTriggerKind.after,
        MssqlInsertStrategy.outputInserted ||
        MssqlInsertStrategy.noKeyReadback => MssqlTriggerKind.none,
      };

  // `noKeyReadback` does not turn the readback off. It names a table with no
  // identity column, which may still have defaults and computed columns to read
  // back, so it gets the same `OUTPUT INSERTED.*` as any other trigger-free
  // table and only the key readback is absent. A view, where a readback cannot
  // run at all, uses this same value.

  // Insert

  /// Inserts one row and reads back what the server stored.
  ///
  /// [values] may be empty only when the table can fill every column itself,
  /// in which case the statement becomes `INSERT … DEFAULT VALUES`.
  Future<MssqlWriteOutcome> insertRow(
    MssqlWriteAssignments values, {
    bool readRow = true,
  }) async {
    final strategy = readRow
        ? _insertReadback()
        : (readback ?? MssqlWriteReadback.none);
    var insert = MssqlInsert.intoParts(binding.nameParts);
    if (values.isEmpty) {
      insert = insert.defaultValues();
    } else {
      insert = insert.values(values.toOperands());
    }

    switch (strategy) {
      case MssqlWriteReadback.storedRow:
        final statement = insert
            .returning(MssqlOutputClause.inserted(_readableColumnNames))
            .compile(dialect: dialect);
        final rows = await session.queryTypedRows(
          statement.sql,
          parameters: statement.parameters,
        );
        _note();
        return MssqlWriteOutcome(
          affectedRows: rows.length,
          affectedRowsSource: MssqlAffectedRowsSource.outputRows,
          rows: rows,
        );

      case MssqlWriteReadback.keyCapture:
        final capture = _captureColumns('insert');
        final statement = insert
            .returning(
              MssqlOutputClause.inserted(
                capture.map((c) => c.name),
                into: MssqlOutputTarget.variable(
                  _captureVariable,
                  columns: capture.map((c) => c.name),
                ),
              ),
            )
            .compile(dialect: dialect);
        final rows = await session.queryTypedRows(
          '${_declareCapture(capture)} ${statement.sql}; '
          '${_selectCaptured(capture)}',
          parameters: statement.parameters,
        );
        _note();
        return MssqlWriteOutcome(
          affectedRows: rows.length,
          affectedRowsSource: MssqlAffectedRowsSource.outputRows,
          rows: rows,
        );

      case MssqlWriteReadback.identityOnly:
        final identity = binding.column(binding.identityColumn!)!;
        final statement = insert.compile(dialect: dialect);
        // CAST to the identity column's own declared type. SCOPE_IDENTITY()
        // is decimal(38, 0), which reaches Dart as a double or as text
        // depending on the connection's decimal mode; converting on the
        // server means the value arrives as the integer it always was
        // instead of being reconstructed from a float that cannot hold it.
        final rows = await session.queryTypedRows(
          '${statement.sql}; SELECT CAST(SCOPE_IDENTITY() AS '
          '${mssqlSqlTypeDeclaration(identity)}) AS '
          '${MssqlSql.quoteIdentifier(identity.name)};',
          parameters: statement.parameters,
        );
        _note();
        return MssqlWriteOutcome(
          affectedRows: 1,
          affectedRowsSource: MssqlAffectedRowsSource.singleRowStatement,
          rows: rows,
        );

      case MssqlWriteReadback.none:
        final statement = insert.compile(dialect: dialect);
        await session.execute(statement.sql, parameters: statement.parameters);
        _note();
        return const MssqlWriteOutcome(
          affectedRows: 1,
          affectedRowsSource: MssqlAffectedRowsSource.singleRowStatement,
        );
    }
  }

  /// Which readback an insert into this table will use.
  ///
  /// Public because the caller has to interpret the outcome: a stored-row
  /// readback returns the whole row and an identity readback returns one
  /// column, and the two are put back into a Dart row differently.
  MssqlWriteReadback get insertReadback => _insertReadback();

  /// Which readback an insert into this table can actually use.
  MssqlWriteReadback _insertReadback() {
    final declared = readback;
    if (declared != null) return declared;
    switch (triggers) {
      case MssqlTriggerKind.none:
        return MssqlWriteReadback.storedRow;
      case MssqlTriggerKind.after:
        if (_captureCandidates.isNotEmpty) return MssqlWriteReadback.keyCapture;
        if (binding.identityColumn != null) {
          return MssqlWriteReadback.identityOnly;
        }
        return MssqlWriteReadback.none;
      case MssqlTriggerKind.insteadOf:
        throw MssqlReadbackUnavailableException(
          table: binding.qualifiedName,
          operation: 'insert',
          reason:
              'the table has an INSTEAD OF trigger, so the INSERT you wrote '
              'never runs and neither OUTPUT nor SCOPE_IDENTITY() describes '
              'it',
        );
    }
  }

  /// `INSERT … SELECT`, with the statement's `WITH` clause where T-SQL wants
  /// it: at the very start, before `INSERT`.
  ///
  /// Returns the driver's count rather than a captured one. A set-based
  /// insert has no single row to read back, and counting its output rows
  /// would mean materialising the whole set on the client for a number the
  /// caller can also get from the target table.
  Future<MssqlWriteOutcome> insertSelect({
    required List<String> columns,
    required MssqlSelectQuery query,
    List<MssqlCte> ctes = const <MssqlCte>[],
  }) async {
    for (final name in columns) {
      final column = binding.column(name);
      if (column == null) {
        throw ArgumentError.value(
          name,
          'columns',
          'Names a column ${binding.qualifiedName} does not have.',
        );
      }
      if (!column.writable) {
        throw ArgumentError.value(
          name,
          'columns',
          column.isReadOnly
              ? 'Is marked read-only by the generator configuration.'
              : 'Is written by the server (identity, computed or rowversion), '
                    'so a projected value has nowhere to land.',
        );
      }
    }
    var insert = MssqlInsert.intoParts(binding.nameParts).using(columns, query);
    for (final cte in ctes) {
      insert = insert.withExpression(cte);
    }
    final statement = insert.compile(dialect: dialect);
    if (triggers == MssqlTriggerKind.none) {
      return _executeCounted(statement.sql, statement.parameters);
    }
    final affected = await session.execute(
      statement.sql,
      parameters: statement.parameters,
    );
    _note();
    return MssqlWriteOutcome(
      affectedRows: affected,
      affectedRowsSource: MssqlAffectedRowsSource.driverTotal,
    );
  }

  // Update / delete

  /// Writes [values] to every row matching [where].
  ///
  /// [operation] names the caller's method in any error, so a refused write
  /// says `update on dbo.Orders` rather than `UPDATE on [dbo].[Orders]`.
  Future<MssqlWriteOutcome> updateWhere({
    required MssqlWriteAssignments values,
    required List<MssqlCondition> where,
    required String operation,
    bool allRows = false,
    List<MssqlCondition> scopes = const <MssqlCondition>[],
    bool readRows = false,
  }) {
    if (values.isEmpty) {
      throw ArgumentError.value(
        values,
        'values',
        '$operation on ${binding.qualifiedName} would write no columns.',
      );
    }
    _requirePredicate(where, allRows, operation);
    var update = MssqlUpdate.tableParts(
      binding.nameParts,
    ).set(values.toOperands());
    for (final condition in <MssqlCondition>[...where, ...scopes]) {
      update = update.where(condition);
    }
    if (where.isEmpty && scopes.isEmpty) update = update.allRows();
    return _runTargeted(
      operation: operation,
      readRows: readRows,
      source: MssqlOutputSource.inserted,
      compile: (clause) => (clause == null ? update : update.returning(clause))
          .compile(dialect: dialect),
    );
  }

  /// Removes every row matching [where].
  Future<MssqlWriteOutcome> deleteWhere({
    required List<MssqlCondition> where,
    required String operation,
    bool allRows = false,
    List<MssqlCondition> scopes = const <MssqlCondition>[],
    bool readRows = false,
  }) {
    _requirePredicate(where, allRows, operation);
    var delete = MssqlDelete.fromParts(binding.nameParts);
    for (final condition in <MssqlCondition>[...where, ...scopes]) {
      delete = delete.where(condition);
    }
    if (where.isEmpty && scopes.isEmpty) delete = delete.allRows();
    return _runTargeted(
      operation: operation,
      readRows: readRows,
      source: MssqlOutputSource.deleted,
      compile: (clause) => (clause == null ? delete : delete.returning(clause))
          .compile(dialect: dialect),
    );
  }

  /// A scope is not a predicate.
  ///
  /// Scopes exist to narrow reads. Letting one stand in for a user filter is
  /// how a tenant scope turns a forgotten `where()` into a table-wide UPDATE
  /// that looks scoped in the log.
  void _requirePredicate(
    List<MssqlCondition> where,
    bool allRows,
    String operation,
  ) {
    if (where.isEmpty && !allRows) {
      throw MssqlUnsafeWriteException(binding.qualifiedName, operation);
    }
    if (where.isNotEmpty && allRows) {
      throw StateError(
        '$operation on ${binding.qualifiedName} passes both a predicate and '
        'allRows(); they contradict. allRows() means every row, so it cannot '
        'be narrowed.',
      );
    }
  }

  /// Runs an `UPDATE` or `DELETE` and decides what its row count means.
  Future<MssqlWriteOutcome> _runTargeted({
    required String operation,
    required bool readRows,
    required MssqlOutputSource source,
    required MssqlStatement Function(MssqlOutputClause? clause) compile,
  }) async {
    switch (triggers) {
      case MssqlTriggerKind.none:
        // No trigger ran, so @@ROWCOUNT read in the same batch immediately
        // after the statement is that statement's own count. This is the one
        // shape where the cheap answer is also the correct one.
        if (!readRows) {
          final statement = compile(null);
          return _executeCounted(statement.sql, statement.parameters);
        }
        final statement = compile(
          MssqlOutputClause(<MssqlOutputColumn>[
            for (final name in _readableColumnNames)
              MssqlOutputColumn(source, name),
          ]),
        );
        final rows = await session.queryTypedRows(
          statement.sql,
          parameters: statement.parameters,
        );
        _note();
        return MssqlWriteOutcome(
          affectedRows: rows.length,
          affectedRowsSource: MssqlAffectedRowsSource.outputRows,
          rows: rows,
        );

      case MssqlTriggerKind.after:
        // A trigger's own statements push their counts into the same batch
        // total and can overwrite @@ROWCOUNT, so the count comes from the
        // rows the statement itself output.
        final capture = _captureColumns(operation);
        final statement = compile(
          MssqlOutputClause(
            <MssqlOutputColumn>[
              for (final column in capture)
                MssqlOutputColumn(source, column.name),
            ],
            into: MssqlOutputTarget.variable(
              _captureVariable,
              columns: capture.map((c) => c.name),
            ),
          ),
        );
        final tail = readRows && source == MssqlOutputSource.inserted
            ? _selectCaptured(capture)
            : 'SELECT COUNT_BIG(*) AS [mssql_affected] FROM '
                  '$_captureVariable;';
        final result = await session.query(
          '${_declareCapture(capture)} ${statement.sql}; $tail',
          parameters: statement.parameters,
        );
        final returned = result.resultSets.isEmpty
            ? const <MssqlRow>[]
            : result.resultSets.first.typedRows;
        final affected = readRows && source == MssqlOutputSource.inserted
            ? returned.length
            : (returned.isEmpty ? 0 : (returned.first.at(0)! as num).toInt());
        _note();
        return MssqlWriteOutcome(
          affectedRows: affected,
          affectedRowsSource: MssqlAffectedRowsSource.outputRows,
          rows: readRows && source == MssqlOutputSource.inserted
              ? returned
              : const <MssqlRow>[],
        );

      case MssqlTriggerKind.insteadOf:
        if (readback != MssqlWriteReadback.none) {
          throw MssqlReadbackUnavailableException(
            table: binding.qualifiedName,
            operation: operation,
            reason:
                'the table has an INSTEAD OF trigger, so the statement you '
                'wrote never runs and neither OUTPUT nor @@ROWCOUNT counts '
                'your rows',
          );
        }
        final statement = compile(null);
        final affected = await session.execute(
          statement.sql,
          parameters: statement.parameters,
        );
        _note();
        return MssqlWriteOutcome(
          affectedRows: affected,
          affectedRowsSource: MssqlAffectedRowsSource.driverTotal,
        );
    }
  }

  // Upsert

  /// Updates the row [matching] identifies or inserts it, then reads it back.
  ///
  /// The readback is a keyed `SELECT` rather than an `OUTPUT` clause: the
  /// upsert is a multi-statement batch whose branches are chosen at run time,
  /// so an `OUTPUT` on one of them says nothing about whether the other ran.
  /// [matching] is a unique key by definition — that is what makes it an
  /// upsert — so selecting by it names the same one row either way.
  Future<MssqlWriteOutcome> upsertRow({
    required MssqlWriteAssignments matching,
    required MssqlWriteAssignments insertValues,
    required MssqlWriteAssignments updateValues,
    bool readRow = true,
  }) async {
    final statement = MssqlUpsert.intoParts(
      binding.nameParts,
      matching: matching.toOperands(),
      insertValues: insertValues.toOperands(),
      updateValues: updateValues.toOperands(),
    ).compile(dialect: dialect);
    if (!readRow) {
      await session.execute(statement.sql, parameters: statement.parameters);
      _note();
      return const MssqlWriteOutcome(
        affectedRows: 1,
        affectedRowsSource: MssqlAffectedRowsSource.singleRowStatement,
      );
    }
    var read = MssqlQuery.fromParts(binding.nameParts, ref: binding.sourceRef)
        .select(
          _readableColumns.map<MssqlExpression>((c) => Col(c.name)).toList(),
        );
    for (final entry in matching.entries) {
      final assigned = entry.value;
      read = read.where(
        assigned is MssqlBoundValue && assigned.value.value == null
            ? Col(entry.key).isNull()
            : Col(entry.key).eq(_matchOperand(assigned)),
      );
    }
    final select = _rebased(read.compile(dialect: dialect));
    final rows = await session.queryTypedRows(
      '${statement.sql} ${select.sql}',
      parameters: <String, Object?>{
        ...statement.parameters,
        ...select.parameters,
      },
    );
    _note();
    return MssqlWriteOutcome(
      affectedRows: 1,
      affectedRowsSource: MssqlAffectedRowsSource.singleRowStatement,
      rows: rows,
    );
  }

  static Object? _matchOperand(MssqlWriteValue assigned) => switch (assigned) {
    MssqlBoundValue(:final value) => value,
    MssqlServerValue(:final expression) => expression,
    MssqlDefaultValue() => throw ArgumentError.value(
      assigned,
      'matching',
      'DEFAULT is not a value, so it cannot identify the row to upsert.',
    ),
  };

  /// Renames a second statement's parameters so it can share a batch.
  ///
  /// Two statements compiled separately both start numbering at `q0`, and
  /// putting them in one batch would make the second's values overwrite the
  /// first's. The allocator numbers privately and offers no prefix, so the
  /// rename happens here, on the one shape it can be done safely: the
  /// builder's own `@q<number>` names, in a statement with no raw fragment in
  /// it. A raw fragment is the caller's SQL and is left alone.
  static MssqlStatement _rebased(MssqlStatement statement) {
    if (statement.containsRawSql) {
      throw ArgumentError.value(
        statement,
        'statement',
        'carries a raw fragment, so its parameter names are not the '
            'builder\'s to rename. Read the row back with a separate query.',
      );
    }
    return MssqlStatement(
      statement.sql.replaceAllMapped(
        RegExp(r'@(q\d+)\b'),
        (match) => '@$_readbackPrefix${match[1]}',
      ),
      <String, Object?>{
        for (final entry in statement.parameters.entries)
          '$_readbackPrefix${entry.key}': entry.value,
      },
    );
  }

  /// Distinct from the allocator's reserved `q<number>` shape, so a renamed
  /// parameter can never collide with a generated one.
  static const String _readbackPrefix = 'rb';

  // Guard

  /// Runs [write] and insists it affected exactly [expected] rows.
  ///
  /// A guard that only threw would be worse than none: the write would still
  /// be in the database, and the caller would have an exception saying it
  /// changed the wrong number of rows and no way to know it was kept. So the
  /// write runs inside a transaction it can be rolled back with — a savepoint
  /// when the caller already has one open, following the nesting contract in
  /// `MssqlTransaction.savepoint`, and a transaction of its own when it does
  /// not.
  ///
  /// The one case that cannot be made safe is a session this layer does not
  /// recognise, such as a hand-written [MssqlSession] implementation: there is
  /// no way to open a transaction on it, so the write is reported as kept
  /// rather than quietly claimed to be undone.
  Future<MssqlWriteOutcome> guard({
    required String operation,
    required int expected,
    required Future<MssqlWriteOutcome> Function(MssqlWriteEngine<TRow> engine)
    write,
  }) async {
    final inner = _unwrapped(session);
    if (inner is MssqlTransaction) {
      return inner.savepoint(() => _checked(this, operation, expected, write));
    }
    if (inner is MssqlConnection) {
      MssqlTransaction? tx;
      try {
        final result = await inner.transaction((transaction) {
          tx = transaction;
          return _checked(
            withSession(_rewrapped(transaction)),
            operation,
            expected,
            write,
          );
        });
        if (tx != null) changes?.commitPending(tx);
        return result;
      } catch (_) {
        if (tx != null) changes?.discardPending(tx);
        rethrow;
      }
    }
    // A pooled session leases a different connection per command, so there is
    // nothing here to open a transaction on: the guard's read of the count
    // could land on another connection than the write. Saying the write was
    // kept is the only true answer.
    final outcome = await write(this);
    if (outcome.affectedRows == expected) return outcome;
    throw MssqlAffectedRowsException(
      table: binding.qualifiedName,
      operation: operation,
      expected: expected,
      actual: outcome.affectedRows,
    );
  }

  static Future<MssqlWriteOutcome> _checked<TRow>(
    MssqlWriteEngine<TRow> engine,
    String operation,
    int expected,
    Future<MssqlWriteOutcome> Function(MssqlWriteEngine<TRow> engine) write,
  ) async {
    final outcome = await write(engine);
    if (outcome.affectedRows == expected) return outcome;
    // Thrown from inside the transaction, so the savepoint or the transaction
    // that wraps this call is what undoes the write; rolledBack says so.
    throw MssqlAffectedRowsException(
      table: engine.binding.qualifiedName,
      operation: operation,
      expected: expected,
      actual: outcome.affectedRows,
      rolledBack: true,
    );
  }

  /// The session under any observers, so a guard can see what it really has.
  static MssqlSession _unwrapped(MssqlSession session) {
    var current = session;
    while (current is MssqlObservedSession) {
      current = current.inner;
    }
    return current;
  }

  /// [transaction] wrapped in the same observers the engine's session carries.
  ///
  /// An observer exists to see every statement; a guard that quietly stepped
  /// out of it would hide exactly the writes worth watching.
  MssqlSession _rewrapped(MssqlSession transaction) {
    final observers = <MssqlQueryObserver>[];
    var current = session;
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

  // Shared

  /// Runs a statement and takes its count from `@@ROWCOUNT` in the same batch.
  Future<MssqlWriteOutcome> _executeCounted(
    String sql,
    Map<String, Object?> parameters,
  ) async {
    final rows = await session.queryTypedRows(
      '$sql; SELECT @@ROWCOUNT AS [mssql_affected];',
      parameters: parameters,
    );
    _note();
    return MssqlWriteOutcome(
      affectedRows: rows.isEmpty ? 0 : (rows.first.at(0)! as num).toInt(),
      affectedRowsSource: MssqlAffectedRowsSource.immediateRowCount,
    );
  }

  void _note([String? table]) {
    changes?.note(session, table ?? binding.qualifiedName);
  }

  /// The name of the table variable a key capture writes into.
  static const String _captureVariable = '@mssql_written';

  /// The columns a key capture carries: the primary key, or the identity
  /// column when there is no declared key.
  List<MssqlBoundColumn> get _captureCandidates {
    if (binding.hasPrimaryKey) {
      return <MssqlBoundColumn>[
        for (final name in binding.primaryKey) binding.column(name)!,
      ];
    }
    final identity = binding.identityColumn;
    if (identity == null) return const <MssqlBoundColumn>[];
    return <MssqlBoundColumn>[binding.column(identity)!];
  }

  List<MssqlBoundColumn> _captureColumns(String operation) {
    final candidates = _captureCandidates;
    if (candidates.isNotEmpty) return candidates;
    // Nothing identifies a row, so the capture cannot select the stored rows
    // back — but it can still count them, which is what an affected-row
    // contract needs. Any column will do for that.
    if (binding.columns.isEmpty) {
      throw MssqlReadbackUnavailableException(
        table: binding.qualifiedName,
        operation: operation,
        reason: 'the binding declares no columns to capture',
      );
    }
    return <MssqlBoundColumn>[binding.columns.first];
  }

  String _declareCapture(List<MssqlBoundColumn> capture) {
    final declared = capture
        .map(
          (c) =>
              '${MssqlSql.quoteIdentifier(c.name)} '
              '${mssqlSqlTypeDeclaration(c)} NULL',
        )
        .join(', ');
    return 'DECLARE $_captureVariable TABLE ($declared);';
  }

  /// The stored rows, found through the keys the write captured.
  String _selectCaptured(List<MssqlBoundColumn> capture) {
    final projection = _readableColumns
        .map((c) => '[t].${MssqlSql.quoteIdentifier(c.name)}')
        .join(', ');
    final join = capture
        .map(
          (c) =>
              '[k].${MssqlSql.quoteIdentifier(c.name)} = '
              '[t].${MssqlSql.quoteIdentifier(c.name)}',
        )
        .join(' AND ');
    return 'SELECT $projection FROM ${binding.quoted} AS [t] '
        'INNER JOIN $_captureVariable AS [k] ON $join;';
  }

  List<MssqlBoundColumn> get _readableColumns => binding.columns;

  Iterable<String> get _readableColumnNames =>
      _readableColumns.map((c) => c.name);
}

/// How a column is declared in a `DECLARE @t TABLE (…)` or a `CAST`.
///
/// Written from the binding's own metadata rather than inferred: the whole
/// point of capturing keys into a table variable is that the captured value
/// is the column's value, and a `bigint` variable holding an `int` key would
/// change what the join compares. `max` columns and the deprecated LOB types
/// collapse onto their supported spellings, which is what SQL Server itself
/// recommends and what a table variable accepts.
String mssqlSqlTypeDeclaration(MssqlBoundColumn column) {
  // sys.columns.max_length is in bytes, and an n-type stores two per
  // character; -1 means max.
  final bytes = column.maxLength;
  String sized(String name, {required bool wide}) {
    if (bytes < 0) return '$name(max)';
    final units = wide ? bytes ~/ 2 : bytes;
    return units <= 0 ? '$name(1)' : '$name($units)';
  }

  return switch (column.type) {
    MssqlType.bit => 'bit',
    MssqlType.tinyInt => 'tinyint',
    MssqlType.smallInt => 'smallint',
    MssqlType.int32 => 'int',
    MssqlType.int64 => 'bigint',
    MssqlType.real => 'real',
    MssqlType.float64 => 'float',
    MssqlType.decimal => 'decimal(${column.precision}, ${column.scale})',
    MssqlType.numeric => 'numeric(${column.precision}, ${column.scale})',
    MssqlType.money => 'money',
    MssqlType.smallMoney => 'smallmoney',
    MssqlType.char => sized('char', wide: false),
    MssqlType.varchar => sized('varchar', wide: false),
    MssqlType.nchar => sized('nchar', wide: true),
    MssqlType.nvarchar => sized('nvarchar', wide: true),
    MssqlType.text => 'varchar(max)',
    MssqlType.ntext => 'nvarchar(max)',
    MssqlType.binary => sized('binary', wide: false),
    MssqlType.varbinary => sized('varbinary', wide: false),
    MssqlType.image => 'varbinary(max)',
    MssqlType.date => 'date',
    MssqlType.time => 'time(${column.scale})',
    MssqlType.smallDateTime => 'smalldatetime',
    MssqlType.dateTime => 'datetime',
    MssqlType.dateTime2 => 'datetime2(${column.scale})',
    MssqlType.dateTimeOffset => 'datetimeoffset(${column.scale})',
    MssqlType.uniqueIdentifier => 'uniqueidentifier',
    MssqlType.xml => 'xml',
  };
}
