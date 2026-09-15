import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

/// What a table or view is made of, as SQL Server reports it.
///
/// Read through [MssqlSchemaReader]. Public rather than private to the
/// generator because a schema drift check and any later tooling need the same
/// answers.
@immutable
class MssqlTableSchema {
  MssqlTableSchema({
    required this.schema,
    required this.name,
    required this.isView,
    required List<MssqlColumnSchema> columns,
    required this.primaryKey,
    required List<MssqlForeignKeySchema> foreignKeys,
    List<MssqlUniqueKeySchema> uniqueKeys = const <MssqlUniqueKeySchema>[],
    List<MssqlTriggerSchema> triggers = const <MssqlTriggerSchema>[],
  }) : columns = List<MssqlColumnSchema>.unmodifiable(columns),
       foreignKeys = List<MssqlForeignKeySchema>.unmodifiable(foreignKeys),
       uniqueKeys = List<MssqlUniqueKeySchema>.unmodifiable(uniqueKeys),
       triggers = List<MssqlTriggerSchema>.unmodifiable(triggers);

  final String schema;
  final String name;
  final bool isView;

  /// In `column_id` order, which is the order the table declares them.
  final List<MssqlColumnSchema> columns;

  /// Null when the table has none, which a view always does.
  final MssqlPrimaryKeySchema? primaryKey;

  final List<MssqlForeignKeySchema> foreignKeys;

  /// Every unique index and constraint, the primary key included.
  ///
  /// This is what tells a one-to-one from a one-to-many. Both are the same
  /// foreign key pointing here; the difference is whether the other side can
  /// hold more than one row per parent, and a unique constraint on its foreign
  /// key columns is exactly the guarantee that it cannot.
  ///
  /// Filtered and disabled indexes are kept rather than dropped, because a
  /// caller has to be able to see that they exist and why they do not count —
  /// see [MssqlUniqueKeySchema.guaranteesUniqueness].
  final List<MssqlUniqueKeySchema> uniqueKeys;

  /// Every trigger on this table, enabled or not.
  final List<MssqlTriggerSchema> triggers;

  /// Whether [columns] is covered by a unique index or constraint that holds
  /// for every row.
  ///
  /// A filtered index — `WHERE IsDeleted = 0` — does **not** count. It
  /// guarantees uniqueness only among the rows it covers, so treating one as a
  /// unique key would generate a `find` that can return the wrong row and a
  /// one-to-one relation that can have two children.
  bool isUnique(List<String> columns) =>
      uniqueKeyFor(columns, requireUnconditional: true) != null;

  /// The unique key covering exactly [columns], or null.
  ///
  /// With [requireUnconditional] false, a filtered or disabled index is
  /// returned too, so a caller can explain why it was not usable.
  MssqlUniqueKeySchema? uniqueKeyFor(
    List<String> columns, {
    bool requireUnconditional = true,
  }) {
    final wanted = columns.map((c) => c.toLowerCase()).toList()..sort();
    for (final key in uniqueKeys) {
      if (requireUnconditional && !key.guaranteesUniqueness) continue;
      final have = key.columns.map((c) => c.toLowerCase()).toList()..sort();
      if (have.length != wanted.length) continue;
      var same = true;
      for (var i = 0; i < have.length; i++) {
        if (have[i] != wanted[i]) same = false;
      }
      if (same) return key;
    }
    return null;
  }

  /// Whether any enabled trigger sits on this table.
  ///
  /// The rule it serves is not obvious: SQL Server rejects an `OUTPUT` clause
  /// without `INTO` on a table carrying **any** enabled trigger (error 334),
  /// not only an `INSTEAD OF` one. Whoever chooses between `OUTPUT INSERTED`
  /// and `SCOPE_IDENTITY()` reads this.
  bool get hasEnabledTrigger => triggers.any((t) => !t.isDisabled);

  /// Whether an enabled `INSTEAD OF` trigger sits on this table.
  ///
  /// Stronger than [hasEnabledTrigger]: with one of these, what an insert
  /// actually stored is whatever the trigger body decided, so no readback
  /// strategy can promise to return the stored row.
  bool get hasEnabledInsteadOfTrigger =>
      triggers.any((t) => !t.isDisabled && t.isInsteadOf);

  /// Whether a single row can be addressed at all.
  ///
  /// A view and a heap without a primary key both answer no, and generated
  /// code for them omits `find`, `getById` and single-row writes rather than
  /// offering ones that cannot be defined.
  bool get hasPrimaryKey =>
      primaryKey != null && primaryKey!.columns.isNotEmpty;

  /// `[schema].[name]`.
  String get quoted =>
      MssqlSql.quoteMultipartIdentifier(<String>[schema, name]);

  /// `schema.name`, unquoted, as a configuration file would write it.
  String get qualifiedName => '$schema.$name';

  /// The column called [name], compared without regard to ASCII case, or null.
  MssqlColumnSchema? column(String name) => columns.firstWhereOrNull(
    (c) => c.name.toLowerCase() == name.toLowerCase(),
  );

  /// The identity column, if the table has one.
  MssqlColumnSchema? get identityColumn =>
      columns.firstWhereOrNull((c) => c.isIdentity);

  @override
  String toString() =>
      'MssqlTableSchema($qualifiedName, '
      '${columns.length} columns)';
}

@immutable
class MssqlColumnSchema {
  const MssqlColumnSchema({
    required this.ordinal,
    required this.name,
    required this.sqlTypeName,
    required this.type,
    required this.nullable,
    required this.isIdentity,
    required this.isComputed,
    required this.isRowVersion,
    required this.hasDefault,
    required this.maxLength,
    required this.precision,
    required this.scale,
    this.collation,
    this.defaultSql,
    this.computedSql,
    this.isPersistedComputed = false,
  });

  /// SQL Server's `column_id`.
  final int ordinal;

  final String name;

  /// The base system type's name, such as `nvarchar` or `decimal`.
  ///
  /// Type aliases resolve to the type they alias, so a `sysname` column
  /// reports `nvarchar`.
  final String sqlTypeName;

  /// The driver's own classification of [sqlTypeName].
  final MssqlType type;

  final bool nullable;
  final bool isIdentity;
  final bool isComputed;

  /// A `rowversion`/`timestamp` column: written by the server, never by the
  /// client.
  final bool isRowVersion;

  /// Whether a default constraint fills this column in when an insert omits it.
  final bool hasDefault;

  /// Bytes, as `sys.columns` reports it: an `nvarchar(50)` is 100, and a
  /// `max` column is -1.
  final int maxLength;

  final int precision;
  final int scale;

  /// The column's collation, for a character column; null otherwise.
  ///
  /// Recorded because it decides what equality means for this column. It is
  /// never imitated in Dart: knowing a column is
  /// `SQL_Latin1_General_CP1_CI_AS` is a reason to correlate keys on the
  /// server, not a licence to lowercase strings here.
  final String? collation;

  /// The default constraint's expression, as SQL Server stores it.
  ///
  /// [hasDefault] says a default exists; this says what it is, which is what
  /// lets a drift report explain a change instead of only announcing one.
  final String? defaultSql;

  /// The computed column's expression, when [isComputed].
  final String? computedSql;

  /// Whether a computed column is persisted, and so can be indexed.
  final bool isPersistedComputed;

  /// Whether the server, not the application, produces this column's value.
  bool get isServerGenerated => isIdentity || isComputed || isRowVersion;

  @override
  String toString() =>
      'MssqlColumnSchema($name $sqlTypeName'
      '${nullable ? ' NULL' : ' NOT NULL'})';
}

/// A unique index or constraint.
@immutable
class MssqlUniqueKeySchema {
  MssqlUniqueKeySchema({
    required this.name,
    required List<String> columns,
    required this.isPrimaryKey,
    this.isConstraint = false,
    this.isDisabled = false,
    this.filterSql,
    List<bool> nullable = const <bool>[],
    List<String?> collations = const <String?>[],
  }) : columns = List<String>.unmodifiable(columns),
       nullable = List<bool>.unmodifiable(
         nullable.isEmpty ? List<bool>.filled(columns.length, false) : nullable,
       ),
       collations = List<String?>.unmodifiable(
         collations.isEmpty
             ? List<String?>.filled(columns.length, null)
             : collations,
       ) {
    if (this.nullable.length != this.columns.length) {
      throw ArgumentError.value(
        nullable,
        'nullable',
        'Unique key "$name" has ${this.columns.length} columns and '
            '${this.nullable.length} nullability flags.',
      );
    }
    if (this.collations.length != this.columns.length) {
      throw ArgumentError.value(
        collations,
        'collations',
        'Unique key "$name" has ${this.columns.length} columns and '
            '${this.collations.length} collations.',
      );
    }
  }

  final String name;

  /// The key columns, in key order. Included columns are not part of a key and
  /// are not here.
  final List<String> columns;

  final bool isPrimaryKey;

  /// Whether it is a `UNIQUE` constraint rather than a bare unique index.
  final bool isConstraint;

  final bool isDisabled;

  /// The filter predicate of a filtered index, or null for an ordinary one.
  final String? filterSql;

  /// Whether each key column is nullable, in [columns] order.
  ///
  /// SQL Server's UNIQUE still allows many rows with NULL in a nullable
  /// key column. That is not a filtered index, and it is not a reason to
  /// hide the key; it is a reason not to call getOrCreate with a null.
  final List<bool> nullable;

  /// Each key column's collation, in [columns] order; null for non-text.
  ///
  /// Recorded so a diagnostic can say equality is `CI_AS`, not so Dart
  /// can lowercase keys itself.
  final List<String?> collations;

  /// Whether any key column can be NULL, so several all-NULL rows can coexist.
  bool get allowsDuplicateNulls => nullable.contains(true);

  /// Whether this key makes its columns unique across the whole table.
  ///
  /// False for a filtered index, whose guarantee covers only the rows matching
  /// its predicate, and for a disabled one, which guarantees nothing at all.
  bool get guaranteesUniqueness => !isDisabled && filterSql == null;

  /// Why this key cannot stand in for a unique constraint, or null when it
  /// can. Written for a diagnostic, so it reads as a reason.
  String? get unusableReason {
    if (isDisabled) return 'the index is disabled';
    if (filterSql != null) {
      return 'it is a filtered index (WHERE $filterSql), so it is unique only '
          'among the rows matching that filter';
    }
    return null;
  }

  @override
  String toString() =>
      'MssqlUniqueKeySchema($name, ${columns.join(', ')}'
      '${filterSql == null ? '' : ' filtered'}'
      '${allowsDuplicateNulls ? ', nullable' : ''})';
}

/// A trigger, with the timing and events that decide what a write can read
/// back.
@immutable
class MssqlTriggerSchema {
  MssqlTriggerSchema({
    required this.name,
    required this.isDisabled,
    required this.isInsteadOf,
    Set<String> events = const <String>{},
  }) : events = Set<String>.unmodifiable(events);

  final String name;
  final bool isDisabled;

  /// `INSTEAD OF` rather than `AFTER`.
  final bool isInsteadOf;

  /// Some of `INSERT`, `UPDATE`, `DELETE`.
  final Set<String> events;

  @override
  String toString() =>
      'MssqlTriggerSchema($name, ${isInsteadOf ? 'INSTEAD OF' : 'AFTER'} '
      '${(events.toList()..sort()).join(', ')}'
      '${isDisabled ? ', disabled' : ''})';
}

@immutable
class MssqlPrimaryKeySchema {
  MssqlPrimaryKeySchema({required this.name, required List<String> columns})
    : columns = List<String>.unmodifiable(columns);

  final String name;

  /// In key order, which is what a composite key's `WHERE` must follow.
  final List<String> columns;

  @override
  String toString() => 'MssqlPrimaryKeySchema($name, ${columns.join(', ')})';
}

@immutable
class MssqlForeignKeySchema {
  MssqlForeignKeySchema({
    required this.name,
    required List<String> columns,
    required this.referencedSchema,
    required this.referencedTable,
    required List<String> referencedColumns,
  }) : columns = List<String>.unmodifiable(columns),
       referencedColumns = List<String>.unmodifiable(referencedColumns);

  final String name;

  /// The columns on this table, paired positionally with [referencedColumns].
  final List<String> columns;

  final String referencedSchema;
  final String referencedTable;
  final List<String> referencedColumns;

  String get referencedQualifiedName => '$referencedSchema.$referencedTable';

  @override
  String toString() =>
      'MssqlForeignKeySchema($name: ${columns.join(', ')} -> '
      '$referencedQualifiedName)';
}
