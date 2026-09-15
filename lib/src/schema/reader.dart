import 'package:mssql_native/mssql_native.dart';

import 'model.dart';
import 'type_map.dart';

/// Reads table and view shapes from SQL Server's catalog views.
///
/// One query per catalog concern, not one per table: a hundred-table database
/// costs the same seven queries as a one-table database.
///
/// `INFORMATION_SCHEMA` is not used. It cannot report identity columns,
/// computed columns or triggers, which are three of the facts a generator most
/// needs, and the driver already reads `sys.*` elsewhere.
class MssqlSchemaReader {
  MssqlSchemaReader(this.connection);

  final MssqlConnection connection;

  static const Duration _timeout = Duration(seconds: 30);

  /// Every table, and optionally view, in [schemas].
  ///
  /// [include] and [exclude] match a table's own name or its qualified name —
  /// with `*` standing for any run of characters. Exclusion wins.
  Future<List<MssqlTableSchema>> readTables({
    Set<String> schemas = const <String>{'dbo'},
    bool includeViews = true,
    List<String> include = const <String>['*'],
    List<String> exclude = const <String>[],
  }) async {
    if (schemas.isEmpty) {
      throw ArgumentError.value(
        schemas,
        'schemas',
        'Name at least one schema.',
      );
    }
    final objects = await _readObjects(schemas, includeViews);
    final wanted = objects.where(
      (o) => _matchesTable(o, include) && !_matchesTable(o, exclude),
    );
    final ids = <int, _ObjectRow>{for (final o in wanted) o.objectId: o};
    if (ids.isEmpty) return const <MssqlTableSchema>[];

    final columns = await _readColumns(schemas);
    final keys = await _readPrimaryKeys(schemas);
    final unique = await _readUniqueKeys(schemas);
    final foreign = await _readForeignKeys(schemas);
    final triggers = await _readTriggers(schemas);

    final tables = <MssqlTableSchema>[];
    for (final entry in ids.entries) {
      tables.add(
        MssqlTableSchema(
          schema: entry.value.schema,
          name: entry.value.name,
          isView: entry.value.isView,
          columns: columns[entry.key] ?? const <MssqlColumnSchema>[],
          primaryKey: keys[entry.key],
          foreignKeys: foreign[entry.key] ?? const <MssqlForeignKeySchema>[],
          triggers: triggers[entry.key] ?? const <MssqlTriggerSchema>[],
          uniqueKeys: unique[entry.key] ?? const <MssqlUniqueKeySchema>[],
        ),
      );
    }
    tables.sort((a, b) {
      final bySchema = a.schema.compareTo(b.schema);
      return bySchema != 0 ? bySchema : a.name.compareTo(b.name);
    });
    return tables;
  }

  /// One table by name, such as `dbo.Orders` or `Orders` (which means `dbo`).
  ///
  /// Returns null when nothing of that name exists, so that "no such table" is
  /// a value the caller handles rather than an exception it must catch.
  Future<MssqlTableSchema?> readTable(String identifier) async {
    final parts = MssqlMultipartIdentifier.parse(
      identifier,
      maximumParts: 2,
    ).parts;
    final schema = parts.length == 2 ? parts.first : 'dbo';
    final name = parts.last;
    final tables = await readTables(
      schemas: <String>{schema},
      include: <String>[name],
    );
    for (final table in tables) {
      if (table.name.toLowerCase() == name.toLowerCase()) return table;
    }
    return null;
  }

  Future<List<Map<String, Object?>>> _query(
    String sql,
    Map<String, Object?> parameters,
  ) => connection.queryRows(sql, parameters: parameters, timeout: _timeout);

  /// Builds `(@s0, @s1, …)` and the values to go with it.
  ///
  /// Schemas are few, so this never approaches SQL Server's parameter ceiling.
  (String, Map<String, Object?>) _schemaList(Set<String> schemas) {
    final names = <String>[];
    final values = <String, Object?>{};
    var index = 0;
    for (final schema in schemas) {
      final key = 's$index';
      names.add('@$key');
      values[key] = MssqlValue.nvarchar(schema, size: 128);
      index++;
    }
    return ('(${names.join(', ')})', values);
  }

  Future<List<_ObjectRow>> _readObjects(
    Set<String> schemas,
    bool includeViews,
  ) async {
    final (list, values) = _schemaList(schemas);
    final types = includeViews ? "('U', 'V')" : "('U')";
    final rows = await _query('''
SELECT o.object_id, o.name, SCHEMA_NAME(o.schema_id) AS schema_name, o.type
FROM sys.objects AS o
WHERE o.type IN $types
  AND o.is_ms_shipped = 0
  AND SCHEMA_NAME(o.schema_id) IN $list
ORDER BY schema_name, o.name;
''', values);
    return rows
        .map(
          (r) => _ObjectRow(
            objectId: r['object_id']! as int,
            name: r['name']! as String,
            schema: r['schema_name']! as String,
            isView: (r['type']! as String).trim() == 'V',
          ),
        )
        .toList();
  }

  Future<Map<int, List<MssqlColumnSchema>>> _readColumns(
    Set<String> schemas,
  ) async {
    final (list, values) = _schemaList(schemas);
    // The join to sys.types on system_type_id = user_type_id resolves a type
    // alias to the type it aliases, so a sysname column reports nvarchar.
    final rows = await _query('''
SELECT
  c.object_id,
  c.column_id,
  c.name,
  t.name AS type_name,
  c.max_length,
  c.precision,
  c.scale,
  c.is_nullable,
  c.is_identity,
  c.is_computed,
  c.collation_name,
  CASE WHEN c.default_object_id <> 0 THEN 1 ELSE 0 END AS has_default,
  dc.definition AS default_sql,
  cc.definition AS computed_sql,
  cc.is_persisted
FROM sys.columns AS c
JOIN sys.objects AS o ON o.object_id = c.object_id
JOIN sys.types AS t
  ON t.system_type_id = c.system_type_id
 AND t.user_type_id = t.system_type_id
LEFT JOIN sys.default_constraints AS dc
  ON dc.object_id = c.default_object_id
LEFT JOIN sys.computed_columns AS cc
  ON cc.object_id = c.object_id AND cc.column_id = c.column_id
WHERE o.type IN ('U', 'V')
  AND o.is_ms_shipped = 0
  AND SCHEMA_NAME(o.schema_id) IN $list
ORDER BY c.object_id, c.column_id;
''', values);

    final out = <int, List<MssqlColumnSchema>>{};
    for (final row in rows) {
      final objectId = row['object_id']! as int;
      final declaredType = row['type_name']! as String;
      final typeName = declaredType.toLowerCase();
      final type = mssqlTypeForSqlTypeName(typeName);
      if (type == null) {
        throw MssqlException(
          type: MssqlErrorType.configuration,
          // The schema's own spelling, so the type can be found in the database.
          message:
              'Column "${row['name']}" has SQL type "$declaredType", which this '
              'package does not map to a Dart type. Exclude the column, or '
              'open an issue naming the type.',
        );
      }
      out
          .putIfAbsent(objectId, () => <MssqlColumnSchema>[])
          .add(
            MssqlColumnSchema(
              ordinal: row['column_id']! as int,
              name: row['name']! as String,
              sqlTypeName: typeName,
              type: type,
              nullable: _bool(row['is_nullable']),
              isIdentity: _bool(row['is_identity']),
              isComputed: _bool(row['is_computed']),
              isRowVersion: typeName == 'timestamp' || typeName == 'rowversion',
              hasDefault: _bool(row['has_default']),
              maxLength: (row['max_length']! as num).toInt(),
              precision: (row['precision']! as num).toInt(),
              scale: (row['scale']! as num).toInt(),
              collation: row['collation_name'] as String?,
              defaultSql: row['default_sql'] as String?,
              computedSql: row['computed_sql'] as String?,
              isPersistedComputed: _bool(row['is_persisted']),
            ),
          );
    }
    return out;
  }

  Future<Map<int, MssqlPrimaryKeySchema>> _readPrimaryKeys(
    Set<String> schemas,
  ) async {
    final (list, values) = _schemaList(schemas);
    final rows = await _query('''
SELECT
  i.object_id,
  i.name AS index_name,
  c.name AS column_name,
  ic.key_ordinal
FROM sys.indexes AS i
JOIN sys.index_columns AS ic
  ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns AS c
  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN sys.objects AS o ON o.object_id = i.object_id
WHERE i.is_primary_key = 1
  AND o.is_ms_shipped = 0
  AND SCHEMA_NAME(o.schema_id) IN $list
ORDER BY i.object_id, ic.key_ordinal;
''', values);

    final names = <int, String>{};
    final columns = <int, List<String>>{};
    for (final row in rows) {
      final objectId = row['object_id']! as int;
      names[objectId] = row['index_name']! as String;
      columns
          .putIfAbsent(objectId, () => <String>[])
          .add(row['column_name']! as String);
    }
    return <int, MssqlPrimaryKeySchema>{
      for (final entry in columns.entries)
        entry.key: MssqlPrimaryKeySchema(
          name: names[entry.key]!,
          columns: entry.value,
        ),
    };
  }

  /// Every unique index and constraint, filtered and disabled ones included.
  ///
  /// Read and marked unusable rather than filtered out in SQL, so a diagnostic
  /// can say "there is a unique index on Code, but it is filtered" instead of
  /// "there is no unique key on Code".
  Future<Map<int, List<MssqlUniqueKeySchema>>> _readUniqueKeys(
    Set<String> schemas,
  ) async {
    final (list, values) = _schemaList(schemas);
    final rows = await _query('''
SELECT
  i.object_id,
  i.index_id,
  i.name AS index_name,
  i.is_primary_key,
  i.is_unique_constraint,
  i.is_disabled,
  i.filter_definition,
  c.name AS column_name,
  c.is_nullable,
  c.collation_name,
  ic.key_ordinal
FROM sys.indexes AS i
JOIN sys.index_columns AS ic
  ON ic.object_id = i.object_id AND ic.index_id = i.index_id
JOIN sys.columns AS c
  ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN sys.objects AS o ON o.object_id = i.object_id
WHERE i.is_unique = 1
  AND i.is_hypothetical = 0
  AND ic.is_included_column = 0
  AND o.is_ms_shipped = 0
  AND SCHEMA_NAME(o.schema_id) IN $list
ORDER BY i.object_id, i.index_id, ic.key_ordinal;
''', values);

    final columns = <int, Map<int, List<String>>>{};
    final nullables = <int, Map<int, List<bool>>>{};
    final collations = <int, Map<int, List<String?>>>{};
    final details = <int, Map<int, Map<String, Object?>>>{};
    for (final row in rows) {
      final objectId = row['object_id']! as int;
      final indexId = (row['index_id']! as num).toInt();
      columns
          .putIfAbsent(objectId, () => <int, List<String>>{})
          .putIfAbsent(indexId, () => <String>[])
          .add(row['column_name']! as String);
      nullables
          .putIfAbsent(objectId, () => <int, List<bool>>{})
          .putIfAbsent(indexId, () => <bool>[])
          .add(_bool(row['is_nullable']));
      collations
          .putIfAbsent(objectId, () => <int, List<String?>>{})
          .putIfAbsent(indexId, () => <String?>[])
          .add(row['collation_name'] as String?);
      details
          .putIfAbsent(objectId, () => <int, Map<String, Object?>>{})
          .putIfAbsent(indexId, () => row);
    }
    return <int, List<MssqlUniqueKeySchema>>{
      for (final entry in columns.entries)
        entry.key: <MssqlUniqueKeySchema>[
          for (final index in entry.value.entries)
            MssqlUniqueKeySchema(
              name:
                  details[entry.key]![index.key]!['index_name'] as String? ??
                  'index_${index.key}',
              columns: index.value,
              isPrimaryKey: _bool(
                details[entry.key]![index.key]!['is_primary_key'],
              ),
              isConstraint: _bool(
                details[entry.key]![index.key]!['is_unique_constraint'],
              ),
              isDisabled: _bool(details[entry.key]![index.key]!['is_disabled']),
              filterSql:
                  details[entry.key]![index.key]!['filter_definition']
                      as String?,
              nullable: nullables[entry.key]![index.key]!,
              collations: collations[entry.key]![index.key]!,
            ),
        ]..sort((a, b) => a.name.compareTo(b.name)),
    };
  }

  Future<Map<int, List<MssqlForeignKeySchema>>> _readForeignKeys(
    Set<String> schemas,
  ) async {
    final (list, values) = _schemaList(schemas);
    final rows = await _query('''
SELECT
  fk.object_id AS fk_id,
  fk.parent_object_id,
  fk.name AS fk_name,
  pc.name AS parent_column,
  SCHEMA_NAME(rt.schema_id) AS referenced_schema,
  rt.name AS referenced_table,
  rc.name AS referenced_column,
  fkc.constraint_column_id
FROM sys.foreign_keys AS fk
JOIN sys.foreign_key_columns AS fkc
  ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns AS pc
  ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
JOIN sys.objects AS rt ON rt.object_id = fk.referenced_object_id
JOIN sys.columns AS rc
  ON rc.object_id = fkc.referenced_object_id
 AND rc.column_id = fkc.referenced_column_id
JOIN sys.objects AS po ON po.object_id = fk.parent_object_id
WHERE po.is_ms_shipped = 0
  AND SCHEMA_NAME(po.schema_id) IN $list
ORDER BY fk.object_id, fkc.constraint_column_id;
''', values);

    final parents = <int, int>{};
    final names = <int, String>{};
    final referencedSchema = <int, String>{};
    final referencedTable = <int, String>{};
    final columns = <int, List<String>>{};
    final referencedColumns = <int, List<String>>{};
    for (final row in rows) {
      final fkId = row['fk_id']! as int;
      parents[fkId] = row['parent_object_id']! as int;
      names[fkId] = row['fk_name']! as String;
      referencedSchema[fkId] = row['referenced_schema']! as String;
      referencedTable[fkId] = row['referenced_table']! as String;
      columns
          .putIfAbsent(fkId, () => <String>[])
          .add(row['parent_column']! as String);
      referencedColumns
          .putIfAbsent(fkId, () => <String>[])
          .add(row['referenced_column']! as String);
    }

    final out = <int, List<MssqlForeignKeySchema>>{};
    for (final fkId in names.keys) {
      out
          .putIfAbsent(parents[fkId]!, () => <MssqlForeignKeySchema>[])
          .add(
            MssqlForeignKeySchema(
              name: names[fkId]!,
              columns: columns[fkId]!,
              referencedSchema: referencedSchema[fkId]!,
              referencedTable: referencedTable[fkId]!,
              referencedColumns: referencedColumns[fkId]!,
            ),
          );
    }
    for (final list in out.values) {
      list.sort((a, b) => a.name.compareTo(b.name));
    }
    return out;
  }

  /// Every trigger, with its timing and events.
  ///
  /// Disabled ones are read too: a snapshot that omits them cannot report a
  /// trigger being enabled as a change, and enabling one is exactly the change
  /// that invalidates an `OUTPUT` insert strategy.
  Future<Map<int, List<MssqlTriggerSchema>>> _readTriggers(
    Set<String> schemas,
  ) async {
    final (list, values) = _schemaList(schemas);
    final rows = await _query('''
SELECT
  tr.parent_id,
  tr.object_id,
  tr.name,
  tr.is_disabled,
  tr.is_instead_of_trigger,
  te.type_desc AS event_type
FROM sys.triggers AS tr
JOIN sys.objects AS o ON o.object_id = tr.parent_id
LEFT JOIN sys.trigger_events AS te ON te.object_id = tr.object_id
WHERE tr.parent_id <> 0
  AND SCHEMA_NAME(o.schema_id) IN $list
ORDER BY tr.parent_id, tr.name;
''', values);

    final events = <int, Set<String>>{};
    final rowsById = <int, Map<String, Object?>>{};
    final parents = <int, int>{};
    for (final row in rows) {
      // Named rather than `!`: a catalog row missing one of these columns
      // should say which one, instead of throwing a bare null-check failure
      // from inside the schema reader with no indication of what it read.
      final triggerId = _requiredInt(row, 'object_id');
      parents[triggerId] = _requiredInt(row, 'parent_id');
      rowsById[triggerId] = row;
      final event = row['event_type'] as String?;
      if (event != null) {
        events.putIfAbsent(triggerId, () => <String>{}).add(event.trim());
      }
    }
    final out = <int, List<MssqlTriggerSchema>>{};
    for (final entry in rowsById.entries) {
      out
          .putIfAbsent(parents[entry.key]!, () => <MssqlTriggerSchema>[])
          .add(
            MssqlTriggerSchema(
              name: _requiredString(entry.value, 'name'),
              isDisabled: _bool(entry.value['is_disabled']),
              isInsteadOf: _bool(entry.value['is_instead_of_trigger']),
              events: events[entry.key] ?? const <String>{},
            ),
          );
    }
    for (final triggers in out.values) {
      triggers.sort((a, b) => a.name.compareTo(b.name));
    }
    return out;
  }

  /// One `int` column of a catalog row, or an error naming it.
  static int _requiredInt(Map<String, Object?> row, String column) {
    final value = row[column];
    if (value is int) return value;
    throw MssqlException(
      type: MssqlErrorType.configuration,
      message: _missing('sys.triggers', column, value),
    );
  }

  /// One `String` column of a catalog row, or an error naming it.
  static String _requiredString(Map<String, Object?> row, String column) {
    final value = row[column];
    if (value is String) return value;
    throw MssqlException(
      type: MssqlErrorType.configuration,
      message: _missing('sys.triggers', column, value),
    );
  }

  static String _missing(String view, String column, Object? value) =>
      'The catalog query over $view returned a row with no usable "$column" '
      '(got ${value == null ? 'null' : value.runtimeType}). The schema reader '
      'stops rather than guessing which object the row describes.';
}

bool _bool(Object? value) => switch (value) {
  final bool b => b,
  final num n => n != 0,
  final String s => s == '1' || s.toLowerCase() == 'true',
  _ => false,
};

/// Matches an object against patterns written either way round.
///
/// `Orders` and `dbo.Orders` both name the one table, and every per-table
/// setting a generator layers on top of this is written schema-qualified — so
/// accepting only the bare name here would mean one file asking for two
/// conventions.
bool _matchesTable(_ObjectRow object, List<String> patterns) =>
    _matches(object.name, patterns) ||
    _matches('${object.schema}.${object.name}', patterns);

/// Matches [name] against glob-ish patterns where `*` stands for any run of
/// characters. Comparison ignores ASCII case, as SQL Server's default
/// collations do.
bool _matches(String name, List<String> patterns) {
  for (final pattern in patterns) {
    final escaped = RegExp.escape(pattern).replaceAll(r'\*', '.*');
    if (RegExp('^$escaped\$', caseSensitive: false).hasMatch(name)) return true;
  }
  return false;
}

class _ObjectRow {
  const _ObjectRow({
    required this.objectId,
    required this.name,
    required this.schema,
    required this.isView,
  });

  final int objectId;
  final String name;
  final String schema;
  final bool isView;
}
