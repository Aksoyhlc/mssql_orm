import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../schema/fingerprint.dart';
import '../schema/model.dart';
import '../schema/reader.dart';
import '../schema/snapshot.dart';
import 'binding.dart';

/// What kind of schema change was found.
enum MssqlDifferenceKind {
  tableMissing,

  /// A table the generated code does not cover at all.
  tableUngenerated,

  /// The generated code was built from a different version of the table.
  ///
  /// Reported by tools that hold the generated fingerprint but not the schema
  /// it was generated from, and so can say that something changed without
  /// saying what.
  schemaFingerprintChanged,

  columnMissing,
  columnAdded,
  typeChanged,
  nullabilityChanged,
  sizeChanged,
  primaryKeyChanged,
  identityChanged,
  triggerAdded,
  triggerRemoved,

  /// A column's collation moved, which changes what equality means for it.
  collationChanged,

  /// A default constraint appeared, vanished or changed its expression.
  defaultChanged,

  /// A unique index or constraint appeared, vanished or changed.
  ///
  /// Unique keys determine relation cardinality and whether a
  /// `getOrCreateBy…` operation is race-safe.
  uniqueKeyChanged,

  /// A foreign key appeared, vanished or moved.
  foreignKeyChanged,

  /// A computed column's expression changed.
  computedChanged,
}

/// Whether generated code still works with the change.
///
/// Changes that generated code neither reads nor writes, such as a new nullable
/// column, are benign.
enum MssqlDifferenceSeverity { breaking, benign }

/// One difference between a schema snapshot and the live database.
@immutable
class MssqlSchemaDifference {
  const MssqlSchemaDifference({
    required this.table,
    required this.kind,
    required this.severity,
    required this.expected,
    required this.actual,
    required this.remedy,
    this.column,
  });

  final String table;
  final String? column;
  final MssqlDifferenceKind kind;
  final MssqlDifferenceSeverity severity;
  final String expected;
  final String actual;

  /// What to do about it, in a sentence.
  final String remedy;

  bool get isBreaking => severity == MssqlDifferenceSeverity.breaking;

  String describe() {
    final where = column == null ? table : '$table.$column';
    return '${isBreaking ? 'breaking' : 'benign  '}  $where: '
        '${kind.name} — expected $expected, found $actual. $remedy';
  }

  @override
  String toString() => 'MssqlSchemaDifference(${describe()})';
}

/// Everything the check found.
@immutable
class MssqlSchemaReport {
  MssqlSchemaReport(List<MssqlSchemaDifference> differences)
    : differences = List<MssqlSchemaDifference>.unmodifiable(differences);

  final List<MssqlSchemaDifference> differences;

  bool get isClean => differences.isEmpty;
  bool get hasBreakingChanges => differences.any((d) => d.isBreaking);

  List<MssqlSchemaDifference> get breaking =>
      differences.where((d) => d.isBreaking).toList(growable: false);

  /// A readable summary.
  ///
  /// "The schema changed" is not useful on its own; which table, which column,
  /// and what it means for the generated code is.
  String describe() {
    if (isClean) return 'Generated code matches the database.';
    final buffer = StringBuffer()
      ..writeln(
        '${differences.length} difference(s) between the generated code and '
        'the database, ${breaking.length} of them breaking:',
      );
    for (final difference in differences) {
      buffer.writeln('  ${difference.describe()}');
    }
    return buffer.toString();
  }
}

/// Compares a schema snapshot against the live database.
///
/// The counterpart of generating offline: generation from a snapshot needs no
/// server, and this is the step that says whether the snapshot is still true.
/// Kept apart so a build that generates offline can still have a deploy step
/// that checks.
///
/// Unlike the binding check, this compares the whole schema, so it can say
/// which column changed, from what to what, and why it matters.
List<MssqlSchemaDifference> diffSchemas({
  required List<MssqlTableSchema> expected,
  required List<MssqlTableSchema> actual,
}) {
  final live = <String, MssqlTableSchema>{
    for (final table in actual) table.qualifiedName.toLowerCase(): table,
  };
  final out = <MssqlSchemaDifference>[];
  for (final table in expected) {
    final current = live.remove(table.qualifiedName.toLowerCase());
    if (current == null) {
      out.add(
        MssqlSchemaDifference(
          table: table.qualifiedName,
          kind: MssqlDifferenceKind.tableMissing,
          severity: MssqlDifferenceSeverity.breaking,
          expected: 'a ${table.isView ? 'view' : 'table'}',
          actual: 'nothing',
          remedy:
              'It was dropped or renamed since the snapshot was taken; '
              'take a new snapshot and regenerate.',
        ),
      );
      continue;
    }
    out.addAll(_diffTable(table, current));
  }
  for (final table in live.values) {
    out.add(
      MssqlSchemaDifference(
        table: table.qualifiedName,
        kind: MssqlDifferenceKind.tableUngenerated,
        severity: MssqlDifferenceSeverity.benign,
        expected: 'nothing',
        actual: 'a ${table.isView ? 'view' : 'table'}',
        remedy:
            'The snapshot does not describe it; take a new snapshot to '
            'generate code for it.',
      ),
    );
  }
  return out;
}

List<MssqlSchemaDifference> _diffTable(
  MssqlTableSchema expected,
  MssqlTableSchema actual,
) {
  final out = <MssqlSchemaDifference>[];
  final name = expected.qualifiedName;

  MssqlSchemaDifference difference({
    String? column,
    required MssqlDifferenceKind kind,
    required MssqlDifferenceSeverity severity,
    required String was,
    required String now,
    required String remedy,
  }) => MssqlSchemaDifference(
    table: name,
    column: column,
    kind: kind,
    severity: severity,
    expected: was,
    actual: now,
    remedy: remedy,
  );

  for (final column in expected.columns) {
    final current = actual.column(column.name);
    if (current == null) {
      out.add(
        difference(
          column: column.name,
          kind: MssqlDifferenceKind.columnMissing,
          severity: MssqlDifferenceSeverity.breaking,
          was: column.sqlTypeName,
          now: 'nothing',
          remedy: 'Generated code reads this column on every row; regenerate.',
        ),
      );
      continue;
    }
    if (current.sqlTypeName != column.sqlTypeName) {
      out.add(
        difference(
          column: column.name,
          kind: MssqlDifferenceKind.typeChanged,
          severity: MssqlDifferenceSeverity.breaking,
          was: column.sqlTypeName,
          now: current.sqlTypeName,
          remedy:
              'The generated Dart type comes from the SQL type; '
              'regenerate.',
        ),
      );
    }
    if (current.nullable != column.nullable) {
      out.add(
        difference(
          column: column.name,
          kind: MssqlDifferenceKind.nullabilityChanged,
          severity: MssqlDifferenceSeverity.breaking,
          was: column.nullable ? 'NULL' : 'NOT NULL',
          now: current.nullable ? 'NULL' : 'NOT NULL',
          remedy: current.nullable
              ? 'The generated field is non-nullable and will now receive '
                    'null; regenerate.'
              : 'An insert or patch omitting this column is now rejected; '
                    'regenerate.',
        ),
      );
    }
    if (current.isIdentity != column.isIdentity) {
      out.add(
        difference(
          column: column.name,
          kind: MssqlDifferenceKind.identityChanged,
          severity: MssqlDifferenceSeverity.breaking,
          was: column.isIdentity ? 'IDENTITY' : 'not IDENTITY',
          now: current.isIdentity ? 'IDENTITY' : 'not IDENTITY',
          remedy:
              'Which columns an insert may name, and how the key comes '
              'back, both change; regenerate.',
        ),
      );
    }
    if (current.precision != column.precision ||
        current.scale != column.scale ||
        current.maxLength != column.maxLength) {
      final shrank =
          current.precision < column.precision ||
          current.scale < column.scale ||
          _shrank(column.maxLength, current.maxLength);
      out.add(
        difference(
          column: column.name,
          kind: MssqlDifferenceKind.sizeChanged,
          severity: shrank
              ? MssqlDifferenceSeverity.breaking
              : MssqlDifferenceSeverity.benign,
          was: _size(column),
          now: _size(current),
          remedy: shrank
              ? 'A value that fitted before may now be rejected.'
              : 'Wider than the snapshot describes; regenerate when '
                    'convenient.',
        ),
      );
    }
    if (current.collation != column.collation) {
      out.add(
        difference(
          column: column.name,
          kind: MssqlDifferenceKind.collationChanged,
          severity: MssqlDifferenceSeverity.breaking,
          was: column.collation ?? 'none',
          now: current.collation ?? 'none',
          remedy:
              'Collation decides what equality and ordering mean for this '
              'column, so lookups and unique keys can behave differently.',
        ),
      );
    }
    if (current.hasDefault != column.hasDefault ||
        current.defaultSql != column.defaultSql) {
      out.add(
        difference(
          column: column.name,
          kind: MssqlDifferenceKind.defaultChanged,
          severity: MssqlDifferenceSeverity.benign,
          was: column.defaultSql ?? (column.hasDefault ? 'a default' : 'none'),
          now:
              current.defaultSql ?? (current.hasDefault ? 'a default' : 'none'),
          remedy: 'What an insert that omits this column stores has changed.',
        ),
      );
    }
    if (current.computedSql != column.computedSql) {
      out.add(
        difference(
          column: column.name,
          kind: MssqlDifferenceKind.computedChanged,
          severity: MssqlDifferenceSeverity.benign,
          was: column.computedSql ?? 'not computed',
          now: current.computedSql ?? 'not computed',
          remedy: 'The value this column reads back with has changed.',
        ),
      );
    }
  }

  final known = <String>{
    for (final c in expected.columns) c.name.toLowerCase(),
  };
  for (final column in actual.columns) {
    if (known.contains(column.name.toLowerCase())) continue;
    final breaks =
        !column.nullable && !column.hasDefault && !column.isServerGenerated;
    out.add(
      difference(
        column: column.name,
        kind: MssqlDifferenceKind.columnAdded,
        severity: breaks
            ? MssqlDifferenceSeverity.breaking
            : MssqlDifferenceSeverity.benign,
        was: 'nothing',
        now:
            '${column.sqlTypeName}'
            '${column.nullable ? ' NULL' : ' NOT NULL'}',
        remedy: breaks
            ? 'It is NOT NULL with no default, so every generated insert now '
                  'fails; regenerate.'
            : 'Generated code neither reads nor writes it; regenerate when '
                  'you want it.',
      ),
    );
  }

  if (!_sameColumns(
    expected.primaryKey?.columns ?? const <String>[],
    actual.primaryKey?.columns ?? const <String>[],
  )) {
    out.add(
      difference(
        kind: MssqlDifferenceKind.primaryKeyChanged,
        severity: MssqlDifferenceSeverity.breaking,
        was: expected.primaryKey?.columns.join(', ') ?? 'no primary key',
        now: actual.primaryKey?.columns.join(', ') ?? 'no primary key',
        remedy:
            'find, getById, update and delete all target rows by this key; '
            'regenerate.',
      ),
    );
  }

  out.addAll(_diffUniqueKeys(name, expected, actual, difference));
  out.addAll(_diffForeignKeys(name, expected, actual, difference));
  out.addAll(_diffTriggers(name, expected, actual, difference));
  return out;
}

typedef _Difference =
    MssqlSchemaDifference Function({
      String? column,
      required MssqlDifferenceKind kind,
      required MssqlDifferenceSeverity severity,
      required String was,
      required String now,
      required String remedy,
    });

List<MssqlSchemaDifference> _diffUniqueKeys(
  String name,
  MssqlTableSchema expected,
  MssqlTableSchema actual,
  _Difference difference,
) {
  final out = <MssqlSchemaDifference>[];
  final was = <String, MssqlUniqueKeySchema>{
    for (final key in expected.uniqueKeys) key.name.toLowerCase(): key,
  };
  final now = <String, MssqlUniqueKeySchema>{
    for (final key in actual.uniqueKeys) key.name.toLowerCase(): key,
  };
  for (final entry in was.entries) {
    final current = now[entry.key];
    if (current == null) {
      out.add(
        difference(
          kind: MssqlDifferenceKind.uniqueKeyChanged,
          severity: MssqlDifferenceSeverity.breaking,
          was: entry.value.toString(),
          now: 'nothing',
          remedy:
              'A getOrCreate or one-to-one relation generated from this '
              'key no longer has the guarantee it relies on.',
        ),
      );
      continue;
    }
    if (current.guaranteesUniqueness != entry.value.guaranteesUniqueness ||
        !_sameColumns(entry.value.columns, current.columns)) {
      out.add(
        difference(
          kind: MssqlDifferenceKind.uniqueKeyChanged,
          severity: MssqlDifferenceSeverity.breaking,
          was: entry.value.toString(),
          now: current.toString(),
          remedy: current.unusableReason == null
              ? 'The key covers different columns than it did.'
              : 'It no longer guarantees uniqueness: '
                    '${current.unusableReason}.',
        ),
      );
    }
  }
  for (final entry in now.entries) {
    if (was.containsKey(entry.key)) continue;
    out.add(
      difference(
        kind: MssqlDifferenceKind.uniqueKeyChanged,
        severity: MssqlDifferenceSeverity.benign,
        was: 'nothing',
        now: entry.value.toString(),
        remedy: 'Regenerating would offer a typed unique key for it.',
      ),
    );
  }
  return out;
}

List<MssqlSchemaDifference> _diffForeignKeys(
  String name,
  MssqlTableSchema expected,
  MssqlTableSchema actual,
  _Difference difference,
) {
  final out = <MssqlSchemaDifference>[];
  final was = <String, MssqlForeignKeySchema>{
    for (final key in expected.foreignKeys) key.name.toLowerCase(): key,
  };
  final now = <String, MssqlForeignKeySchema>{
    for (final key in actual.foreignKeys) key.name.toLowerCase(): key,
  };
  for (final entry in was.entries) {
    final current = now[entry.key];
    if (current == null) {
      out.add(
        difference(
          kind: MssqlDifferenceKind.foreignKeyChanged,
          severity: MssqlDifferenceSeverity.breaking,
          was: entry.value.toString(),
          now: 'nothing',
          remedy:
              'The relation generated from it no longer has a declared '
              'key; regenerate.',
        ),
      );
      continue;
    }
    if (!_sameColumns(entry.value.columns, current.columns) ||
        entry.value.referencedQualifiedName.toLowerCase() !=
            current.referencedQualifiedName.toLowerCase()) {
      out.add(
        difference(
          kind: MssqlDifferenceKind.foreignKeyChanged,
          severity: MssqlDifferenceSeverity.breaking,
          was: entry.value.toString(),
          now: current.toString(),
          remedy: 'The relation now joins different columns; regenerate.',
        ),
      );
    }
  }
  for (final entry in now.entries) {
    if (was.containsKey(entry.key)) continue;
    out.add(
      difference(
        kind: MssqlDifferenceKind.foreignKeyChanged,
        severity: MssqlDifferenceSeverity.benign,
        was: 'nothing',
        now: entry.value.toString(),
        remedy: 'Regenerating would offer a relation for it.',
      ),
    );
  }
  return out;
}

List<MssqlSchemaDifference> _diffTriggers(
  String name,
  MssqlTableSchema expected,
  MssqlTableSchema actual,
  _Difference difference,
) {
  final out = <MssqlSchemaDifference>[];
  if (actual.hasEnabledTrigger && !expected.hasEnabledTrigger) {
    out.add(
      difference(
        kind: MssqlDifferenceKind.triggerAdded,
        severity: MssqlDifferenceSeverity.breaking,
        was: 'no enabled trigger',
        now: actual.triggers
            .where((t) => !t.isDisabled)
            .map((t) => t.name)
            .join(', '),
        remedy:
            'SQL Server rejects OUTPUT without INTO on a table with an '
            'enabled trigger (error 334), so generated inserts will fail; '
            'regenerate.',
      ),
    );
  } else if (!actual.hasEnabledTrigger && expected.hasEnabledTrigger) {
    out.add(
      difference(
        kind: MssqlDifferenceKind.triggerRemoved,
        severity: MssqlDifferenceSeverity.benign,
        was: expected.triggers
            .where((t) => !t.isDisabled)
            .map((t) => t.name)
            .join(', '),
        now: 'no enabled trigger',
        remedy:
            'Inserts still work; regenerating would make them one round '
            'trip instead of two.',
      ),
    );
  }
  return out;
}

String _size(MssqlColumnSchema column) =>
    'max_length ${column.maxLength}, precision ${column.precision}, '
    'scale ${column.scale}';

/// Compares generated bindings against the live database.
///
/// This is what replaces migrations here. An ORM's migration makes the schema
/// match the code; the direction is reversed in a DB-first package, so the
/// counterpart is not changing anything but reporting the gap before a deploy
/// finds it.
abstract final class MssqlSchemaCheck {
  /// Reports how [bindings] differ from what [connection] actually has.
  ///
  /// Returns a report rather than throwing. What to do about drift is the
  /// application's decision — fail startup in development, log in production,
  /// stop only on breaking changes — and a library making that choice for
  /// everyone would be wrong for most of them.
  static Future<MssqlSchemaReport> verify(
    MssqlConnection connection, {
    required List<MssqlTableBinding<Object?>> bindings,
  }) async {
    if (bindings.isEmpty) return MssqlSchemaReport(const []);

    final reader = MssqlSchemaReader(connection);
    final schemas = <String>{for (final b in bindings) b.schema};
    final live = <String, MssqlTableSchema>{
      for (final table in await reader.readTables(schemas: schemas))
        table.qualifiedName.toLowerCase(): table,
    };

    final differences = <MssqlSchemaDifference>[];
    for (final binding in bindings) {
      final table = live[binding.qualifiedName.toLowerCase()];
      if (table == null) {
        differences.add(
          MssqlSchemaDifference(
            table: binding.qualifiedName,
            kind: MssqlDifferenceKind.tableMissing,
            severity: MssqlDifferenceSeverity.breaking,
            expected: 'a table',
            actual: 'nothing',
            remedy: 'The table was dropped or renamed; regenerate.',
          ),
        );
        continue;
      }
      differences.addAll(_compare(binding, table));
    }
    return MssqlSchemaReport(differences);
  }

  /// Compares one binding against a schema already in hand.
  ///
  /// [verify] reads the live schema and calls this; it is public because
  /// anyone who already holds an [MssqlTableSchema] — a generator, a test, a
  /// tool — should not have to read it again to ask the same question.
  static MssqlSchemaReport compare(
    MssqlTableBinding<Object?> binding,
    MssqlTableSchema table,
  ) => MssqlSchemaReport(_compare(binding, table));

  /// Reports how the live database differs from [snapshot].
  ///
  /// This is what a standalone `check_schema` runs. Comparing the whole
  /// snapshot rather than a header hash is what lets it name the column, its
  /// old and new type, and why the change matters — a hash can only say that
  /// something moved.
  static Future<MssqlSchemaReport> verifySnapshot(
    MssqlConnection connection,
    MssqlSchemaSnapshot snapshot, {
    bool includeViews = true,
  }) async {
    final ambiguous = snapshot.ambiguousNames;
    if (ambiguous.isNotEmpty) {
      throw StateError(
        'The snapshot holds names that differ only in case '
        '(${ambiguous.join('; ')}). Comparing them would mean folding them '
        'together, which is wrong for a case-sensitive collation.',
      );
    }
    final schemas = <String>{for (final t in snapshot.tables) t.schema};
    if (schemas.isEmpty) return MssqlSchemaReport(const []);
    final live = await MssqlSchemaReader(
      connection,
    ).readTables(schemas: schemas, includeViews: includeViews);
    return MssqlSchemaReport(
      diffSchemas(expected: snapshot.tables, actual: live),
    );
  }

  /// The cheap version: has anything at all changed for [binding]?
  ///
  /// Compares the stored fingerprint against a freshly computed one. Useful
  /// when only a yes/no is wanted; [verify] is what says what changed.
  static bool matchesFingerprint(
    MssqlTableBinding<Object?> binding,
    MssqlTableSchema table,
  ) =>
      binding.schemaFingerprint.isNotEmpty &&
      binding.schemaFingerprint == fingerprintOf(table);
}

List<MssqlSchemaDifference> _compare(
  MssqlTableBinding<Object?> binding,
  MssqlTableSchema table,
) {
  final out = <MssqlSchemaDifference>[];
  final name = binding.qualifiedName;

  MssqlSchemaDifference difference({
    String? column,
    required MssqlDifferenceKind kind,
    required MssqlDifferenceSeverity severity,
    required String expected,
    required String actual,
    required String remedy,
  }) => MssqlSchemaDifference(
    table: name,
    column: column,
    kind: kind,
    severity: severity,
    expected: expected,
    actual: actual,
    remedy: remedy,
  );

  for (final bound in binding.columns) {
    final column = table.column(bound.name);
    if (column == null) {
      out.add(
        difference(
          column: bound.name,
          kind: MssqlDifferenceKind.columnMissing,
          severity: MssqlDifferenceSeverity.breaking,
          expected: bound.type.name,
          actual: 'nothing',
          remedy: 'fromRow will fail on every read; regenerate.',
        ),
      );
      continue;
    }

    if (column.type != bound.type) {
      out.add(
        difference(
          column: bound.name,
          kind: MssqlDifferenceKind.typeChanged,
          severity: MssqlDifferenceSeverity.breaking,
          expected: bound.type.name,
          actual: column.type.name,
          remedy: 'The generated field type no longer matches; regenerate.',
        ),
      );
    }

    if (column.nullable != bound.nullable) {
      out.add(
        difference(
          column: bound.name,
          kind: MssqlDifferenceKind.nullabilityChanged,
          severity: MssqlDifferenceSeverity.breaking,
          expected: bound.nullable ? 'NULL' : 'NOT NULL',
          actual: column.nullable ? 'NULL' : 'NOT NULL',
          remedy: column.nullable
              // A column that became nullable will hand null to a
              // non-nullable generated field, which fails on the first row
              // that has one — later, and somewhere else.
              ? 'The generated field is non-nullable and will now receive '
                    'null; regenerate.'
              : 'An insert omitting this column is now rejected; regenerate.',
        ),
      );
    }

    if (column.isIdentity != bound.isIdentity) {
      out.add(
        difference(
          column: bound.name,
          kind: MssqlDifferenceKind.identityChanged,
          severity: MssqlDifferenceSeverity.breaking,
          expected: bound.isIdentity ? 'IDENTITY' : 'not IDENTITY',
          actual: column.isIdentity ? 'IDENTITY' : 'not IDENTITY',
          remedy: 'The insert strategy is no longer valid; regenerate.',
        ),
      );
    }

    // Precision, scale and length only break when they shrink: an existing
    // value fits a wider column, and generated code never asks how wide one is.
    if (column.precision < bound.precision || column.scale < bound.scale) {
      out.add(
        difference(
          column: bound.name,
          kind: MssqlDifferenceKind.sizeChanged,
          severity: MssqlDifferenceSeverity.breaking,
          expected: '(${bound.precision}, ${bound.scale})',
          actual: '(${column.precision}, ${column.scale})',
          remedy: 'A value that fitted before may now be rejected.',
        ),
      );
    } else if (column.precision > bound.precision ||
        column.scale > bound.scale) {
      out.add(
        difference(
          column: bound.name,
          kind: MssqlDifferenceKind.sizeChanged,
          severity: MssqlDifferenceSeverity.benign,
          expected: '(${bound.precision}, ${bound.scale})',
          actual: '(${column.precision}, ${column.scale})',
          remedy: 'Wider than generated for; regenerate when convenient.',
        ),
      );
    }

    if (_shrank(bound.maxLength, column.maxLength)) {
      out.add(
        difference(
          column: bound.name,
          kind: MssqlDifferenceKind.sizeChanged,
          severity: MssqlDifferenceSeverity.breaking,
          expected: 'max_length ${bound.maxLength}',
          actual: 'max_length ${column.maxLength}',
          remedy: 'A value that fitted before may now be rejected.',
        ),
      );
    }
  }

  final known = <String>{for (final c in binding.columns) c.name.toLowerCase()};
  for (final column in table.columns) {
    if (known.contains(column.name.toLowerCase())) continue;
    // A new column generated code cannot see is only a problem when an insert
    // that omits it would be rejected.
    final breaks =
        !column.nullable && !column.hasDefault && !column.isServerGenerated;
    out.add(
      difference(
        column: column.name,
        kind: MssqlDifferenceKind.columnAdded,
        severity: breaks
            ? MssqlDifferenceSeverity.breaking
            : MssqlDifferenceSeverity.benign,
        expected: 'nothing',
        actual:
            '${column.sqlTypeName}'
            '${column.nullable ? ' NULL' : ' NOT NULL'}',
        remedy: breaks
            ? 'It is NOT NULL with no default, so every insert now fails; '
                  'regenerate.'
            : 'Generated code neither reads nor writes it; regenerate when '
                  'you want it.',
      ),
    );
  }

  final liveKey = table.primaryKey?.columns ?? const <String>[];
  if (!_sameColumns(liveKey, binding.primaryKey)) {
    out.add(
      difference(
        kind: MssqlDifferenceKind.primaryKeyChanged,
        severity: MssqlDifferenceSeverity.breaking,
        expected: binding.primaryKey.isEmpty
            ? 'no primary key'
            : binding.primaryKey.join(', '),
        actual: liveKey.isEmpty ? 'no primary key' : liveKey.join(', '),
        remedy:
            'findById, update and delete now target the wrong rows; '
            'regenerate.',
      ),
    );
  }

  // A trigger added after generation invalidates an OUTPUT INSERTED strategy:
  // SQL Server rejects an OUTPUT clause without INTO on a table carrying any
  // enabled trigger. Removing one only leaves the insert less than optimal.
  final expectsOutput =
      binding.insertStrategy == MssqlInsertStrategy.outputInserted;
  if (table.hasEnabledTrigger && expectsOutput) {
    out.add(
      difference(
        kind: MssqlDifferenceKind.triggerAdded,
        severity: MssqlDifferenceSeverity.breaking,
        expected: 'no enabled trigger',
        actual: 'an enabled trigger',
        remedy:
            'Inserts will fail with error 334; regenerate so the table '
            'uses SCOPE_IDENTITY().',
      ),
    );
  } else if (!table.hasEnabledTrigger &&
      binding.insertStrategy == MssqlInsertStrategy.scopeIdentity) {
    out.add(
      difference(
        kind: MssqlDifferenceKind.triggerRemoved,
        severity: MssqlDifferenceSeverity.benign,
        expected: 'an enabled trigger',
        actual: 'no enabled trigger',
        remedy:
            'Inserts still work; regenerating would make them one round '
            'trip instead of two.',
      ),
    );
  }

  return out;
}

/// A `max` column reports -1, which is wider than any fixed length.
bool _shrank(int generated, int live) {
  if (generated == live) return false;
  if (live < 0) return false;
  if (generated < 0) return true;
  return live < generated;
}

bool _sameColumns(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].toLowerCase() != b[i].toLowerCase()) return false;
  }
  return true;
}
