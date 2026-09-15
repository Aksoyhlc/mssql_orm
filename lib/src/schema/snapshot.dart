import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mssql_native/mssql_native.dart';

import '../api_version.dart';
import 'model.dart';
import 'reader.dart';
import 'type_map.dart';

/// A database's shape, written to a file, so that generating code does not
/// need a live database.
///
/// Two things follow from that, and they are separate on purpose:
///
///  * **Generating from a snapshot** is offline. It needs no server, no
///    credentials and no network, which is what makes generation work in CI
///    and on a laptop without a VPN.
///  * **Checking for drift** is not. Comparing a snapshot against the database
///    it describes is the only thing that can say whether the file is still
///    true, and that needs the database.
///
/// A snapshot carries no connection string, user name or password: the
/// credentials used to read the objects are not part of what it describes.
class MssqlSchemaSnapshot {
  MssqlSchemaSnapshot({
    required List<MssqlTableSchema> tables,
    required this.serverVersion,
    required this.compatibilityLevel,
    required this.capturedAt,
    this.apiVersion = MssqlApiVersion.current,
  }) : tables = List<MssqlTableSchema>.unmodifiable(
         <MssqlTableSchema>[...tables]..sort(_byQualifiedName),
       );

  static int _byQualifiedName(MssqlTableSchema a, MssqlTableSchema b) {
    final bySchema = a.schema.compareTo(b.schema);
    return bySchema != 0 ? bySchema : a.name.compareTo(b.name);
  }

  /// The format this file is written in.
  ///
  /// Separate from [apiVersion]: the file format can stay put while the API
  /// contract moves, and the reader has to be able to tell which changed.
  static const int formatVersion = 1;

  final List<MssqlTableSchema> tables;

  /// `SERVERPROPERTY('ProductVersion')` — what the target can do.
  final String serverVersion;

  /// The database's compatibility level, which can hold a modern server to an
  /// older set of behaviours and is therefore its own fact.
  final int compatibilityLevel;

  /// When the snapshot was taken, in UTC. Reported in a drift message so that
  /// "the snapshot is old" is something a reader can see rather than guess.
  final DateTime capturedAt;

  /// The API contract the snapshot was written under.
  final int apiVersion;

  /// A digest of everything except [capturedAt].
  ///
  /// Content, not compatibility: two snapshots of an unchanged database have
  /// the same checksum however far apart they were taken. That is what makes
  /// "regenerate and see if anything changed" a usable check.
  late final String checksum = sha256
      .convert(utf8.encode(_canonicalJson(includeCapturedAt: false)))
      .toString();

  /// The table called [qualifiedName] — `dbo.Orders` — or null.
  ///
  /// Names are compared case-insensitively, which is right for a default
  /// SQL Server collation and wrong for a case-sensitive one. Where two tables
  /// differ only in case, this refuses rather than picking: see
  /// [ambiguousNames].
  MssqlTableSchema? table(String qualifiedName) {
    final wanted = qualifiedName.toLowerCase();
    MssqlTableSchema? found;
    for (final table in tables) {
      if (table.qualifiedName.toLowerCase() != wanted) continue;
      if (table.qualifiedName == qualifiedName) return table;
      if (found != null) {
        throw StateError(
          'The snapshot holds ${found.qualifiedName} and '
          '${table.qualifiedName}, which differ only in case. This database '
          'has a case-sensitive collation; name the table exactly.',
        );
      }
      found = table;
    }
    return found;
  }

  /// Names that differ only in case, and so cannot be resolved by folding.
  ///
  /// Empty for almost every database. When it is not, a tool has to say so
  /// rather than quietly choose one of the two: folding a case-sensitive
  /// database's names together generates code for the wrong table.
  List<String> get ambiguousNames {
    final seen = <String, String>{};
    final clashes = <String>[];
    for (final table in tables) {
      final folded = table.qualifiedName.toLowerCase();
      final first = seen[folded];
      if (first != null && first != table.qualifiedName) {
        clashes.add('$first / ${table.qualifiedName}');
      } else {
        seen[folded] = table.qualifiedName;
      }
    }
    return clashes;
  }

  /// The snapshot as deterministic, pretty-printed JSON.
  ///
  /// Deterministic so that a regenerated file that describes the same database
  /// is byte-identical, and a diff in version control is a real change rather
  /// than a reordering.
  String toJsonText() => _canonicalJson(includeCapturedAt: true);

  String _canonicalJson({required bool includeCapturedAt}) {
    final map = <String, Object?>{
      'format_version': formatVersion,
      'api_version': apiVersion,
      if (includeCapturedAt)
        'captured_at': capturedAt.toUtc().toIso8601String(),
      'server_version': serverVersion,
      'compatibility_level': compatibilityLevel,
      'tables': <Object?>[for (final table in tables) _tableJson(table)],
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  static Map<String, Object?> _tableJson(MssqlTableSchema table) => {
    'schema': table.schema,
    'name': table.name,
    'is_view': table.isView,
    'columns': <Object?>[
      for (final column in table.columns)
        <String, Object?>{
          'ordinal': column.ordinal,
          'name': column.name,
          'sql_type': column.sqlTypeName,
          'nullable': column.nullable,
          'max_length': column.maxLength,
          'precision': column.precision,
          'scale': column.scale,
          'collation': column.collation,
          'identity': column.isIdentity,
          'computed': column.isComputed,
          'computed_sql': column.computedSql,
          'persisted': column.isPersistedComputed,
          'rowversion': column.isRowVersion,
          'has_default': column.hasDefault,
          'default_sql': column.defaultSql,
        },
    ],
    'primary_key': table.primaryKey == null
        ? null
        : <String, Object?>{
            'name': table.primaryKey!.name,
            'columns': table.primaryKey!.columns,
          },
    'unique_keys': <Object?>[
      for (final key in table.uniqueKeys)
        <String, Object?>{
          'name': key.name,
          'columns': key.columns,
          'primary_key': key.isPrimaryKey,
          'constraint': key.isConstraint,
          'disabled': key.isDisabled,
          'filter_sql': key.filterSql,
          'nullable': key.nullable,
          'collations': key.collations,
        },
    ],
    'foreign_keys': <Object?>[
      for (final key in table.foreignKeys)
        <String, Object?>{
          'name': key.name,
          'columns': key.columns,
          'referenced_schema': key.referencedSchema,
          'referenced_table': key.referencedTable,
          'referenced_columns': key.referencedColumns,
        },
    ],
    'triggers': <Object?>[
      for (final trigger in table.triggers)
        <String, Object?>{
          'name': trigger.name,
          'disabled': trigger.isDisabled,
          'instead_of': trigger.isInsteadOf,
          'events': (trigger.events.toList()..sort()),
        },
    ],
  };

  /// Reads a snapshot file.
  ///
  /// A file from a newer format is refused with its version named, rather than
  /// read partly and used as if it were complete.
  factory MssqlSchemaSnapshot.fromJsonText(String source, {String? origin}) {
    final where = origin == null ? '' : ' in $origin';
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException(
        'The schema snapshot$where is not JSON: '
        '${error.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException('The schema snapshot$where is not an object.');
    }
    final format = decoded['format_version'];
    if (format is! int) {
      throw FormatException('The schema snapshot$where has no format_version.');
    }
    if (format > formatVersion) {
      throw FormatException(
        'The schema snapshot$where is format version $format; this package '
        'reads up to $formatVersion. Upgrade mssql_orm_dev, or '
        'regenerate the snapshot with the version you have.',
      );
    }
    final tables = <MssqlTableSchema>[];
    for (final entry in (decoded['tables']! as List<Object?>)) {
      tables.add(_tableFromJson(entry! as Map<String, Object?>, where));
    }
    return MssqlSchemaSnapshot(
      tables: tables,
      serverVersion: decoded['server_version'] as String? ?? '',
      compatibilityLevel: decoded['compatibility_level'] as int? ?? 0,
      capturedAt:
          DateTime.tryParse(decoded['captured_at'] as String? ?? '')?.toUtc() ??
          DateTime.utc(1970),
      apiVersion: decoded['api_version'] as int? ?? MssqlApiVersion.current,
    );
  }

  static MssqlTableSchema _tableFromJson(
    Map<String, Object?> map,
    String where,
  ) {
    final schema = map['schema']! as String;
    final name = map['name']! as String;
    final columns = <MssqlColumnSchema>[];
    for (final entry in (map['columns']! as List<Object?>)) {
      final column = entry! as Map<String, Object?>;
      final sqlTypeName = column['sql_type']! as String;
      final type = mssqlTypeForSqlTypeName(sqlTypeName);
      if (type == null) {
        // The same refusal the live reader makes: an unmapped type is not a
        // String, and code that casts to String would fail on the first row.
        throw FormatException(
          'Column $schema.$name.${column['name']} has SQL type "$sqlTypeName"'
          '$where, which this package does not map to a Dart type. Exclude the '
          'column, declare a converter for it, or open an issue naming the '
          'type.',
        );
      }
      columns.add(
        MssqlColumnSchema(
          ordinal: column['ordinal']! as int,
          name: column['name']! as String,
          sqlTypeName: sqlTypeName,
          type: type,
          nullable: column['nullable']! as bool,
          isIdentity: column['identity']! as bool,
          isComputed: column['computed']! as bool,
          isRowVersion: column['rowversion']! as bool,
          hasDefault: column['has_default']! as bool,
          maxLength: column['max_length']! as int,
          precision: column['precision']! as int,
          scale: column['scale']! as int,
          collation: column['collation'] as String?,
          defaultSql: column['default_sql'] as String?,
          computedSql: column['computed_sql'] as String?,
          isPersistedComputed: column['persisted'] as bool? ?? false,
        ),
      );
    }
    final primaryKey = map['primary_key'] as Map<String, Object?>?;
    return MssqlTableSchema(
      schema: schema,
      name: name,
      isView: map['is_view']! as bool,
      columns: columns,
      primaryKey: primaryKey == null
          ? null
          : MssqlPrimaryKeySchema(
              name: primaryKey['name']! as String,
              columns: _strings(primaryKey['columns']),
            ),
      foreignKeys: <MssqlForeignKeySchema>[
        for (final entry in (map['foreign_keys']! as List<Object?>))
          MssqlForeignKeySchema(
            name: (entry! as Map<String, Object?>)['name']! as String,
            columns: _strings((entry as Map<String, Object?>)['columns']),
            referencedSchema: entry['referenced_schema']! as String,
            referencedTable: entry['referenced_table']! as String,
            referencedColumns: _strings(entry['referenced_columns']),
          ),
      ],
      uniqueKeys: <MssqlUniqueKeySchema>[
        for (final entry in (map['unique_keys']! as List<Object?>))
          _uniqueFromJson(entry! as Map<String, Object?>, columns),
      ],
      triggers: <MssqlTriggerSchema>[
        for (final entry in (map['triggers'] as List<Object?>? ?? const []))
          MssqlTriggerSchema(
            name: (entry! as Map<String, Object?>)['name']! as String,
            isDisabled: (entry as Map<String, Object?>)['disabled']! as bool,
            isInsteadOf: entry['instead_of']! as bool,
            events: _strings(entry['events']).toSet(),
          ),
      ],
    );
  }

  static List<String> _strings(Object? value) => <String>[
    for (final entry in (value! as List<Object?>)) entry! as String,
  ];

  static MssqlUniqueKeySchema _uniqueFromJson(
    Map<String, Object?> entry,
    List<MssqlColumnSchema> tableColumns,
  ) {
    final cols = _strings(entry['columns']);
    MssqlColumnSchema? named(String name) {
      final lower = name.toLowerCase();
      for (final column in tableColumns) {
        if (column.name.toLowerCase() == lower) return column;
      }
      return null;
    }

    return MssqlUniqueKeySchema(
      name: entry['name']! as String,
      columns: cols,
      isPrimaryKey: entry['primary_key']! as bool,
      isConstraint: entry['constraint'] as bool? ?? false,
      isDisabled: entry['disabled'] as bool? ?? false,
      filterSql: entry['filter_sql'] as String?,
      nullable: entry['nullable'] is List
          ? <bool>[
              for (final item in (entry['nullable']! as List<Object?>))
                item == true,
            ]
          : <bool>[for (final name in cols) named(name)?.nullable ?? false],
      collations: entry['collations'] is List
          ? <String?>[
              for (final item in (entry['collations']! as List<Object?>))
                item as String?,
            ]
          : <String?>[for (final name in cols) named(name)?.collation],
    );
  }

  /// Reads the live schema and the two server facts a snapshot records.
  static Future<MssqlSchemaSnapshot> capture(
    MssqlConnection connection, {
    Set<String> schemas = const <String>{'dbo'},
    bool includeViews = true,
    List<String> include = const <String>['*'],
    List<String> exclude = const <String>[],
  }) async {
    final tables = await MssqlSchemaReader(connection).readTables(
      schemas: schemas,
      includeViews: includeViews,
      include: include,
      exclude: exclude,
    );
    final row = await connection.queryTypedSingle('''
SELECT
  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
  CAST(DATABASEPROPERTYEX(DB_NAME(), 'CompatibilityLevel') AS int) AS level;
''');
    return MssqlSchemaSnapshot(
      tables: tables,
      serverVersion: row.at(0)?.toString() ?? '',
      compatibilityLevel: (row.at(1) as num?)?.toInt() ?? 0,
      capturedAt: DateTime.now().toUtc(),
    );
  }
}
