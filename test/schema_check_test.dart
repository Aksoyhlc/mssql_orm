import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_driver.dart';

MssqlBoundColumn bound(
  String name,
  MssqlType type, {
  bool nullable = false,
  bool isIdentity = false,
  int maxLength = 0,
  int precision = 0,
  int scale = 0,
}) => MssqlBoundColumn(
  name: name,
  type: type,
  nullable: nullable,
  isIdentity: isIdentity,
  maxLength: maxLength,
  precision: precision,
  scale: scale,
);

MssqlColumnSchema live(
  String name,
  String sqlTypeName, {
  int ordinal = 1,
  bool nullable = false,
  bool isIdentity = false,
  bool isComputed = false,
  bool hasDefault = false,
  int maxLength = 0,
  int precision = 0,
  int scale = 0,
}) => MssqlColumnSchema(
  ordinal: ordinal,
  name: name,
  sqlTypeName: sqlTypeName,
  type: mssqlTypeForSqlTypeName(sqlTypeName)!,
  nullable: nullable,
  isIdentity: isIdentity,
  isComputed: isComputed,
  isRowVersion: false,
  hasDefault: hasDefault,
  maxLength: maxLength,
  precision: precision,
  scale: scale,
);

MssqlTableBinding<Object?> binding({
  List<MssqlBoundColumn>? columns,
  List<String> primaryKey = const <String>['Id'],
  MssqlInsertStrategy strategy = MssqlInsertStrategy.outputInserted,
}) => MssqlTableBinding<Object?>(
  schema: 'dbo',
  table: 'Users',
  primaryKey: primaryKey,
  insertStrategy: strategy,
  columns:
      columns ??
      <MssqlBoundColumn>[
        bound('Id', MssqlType.int32, isIdentity: true),
        bound('Name', MssqlType.nvarchar, maxLength: 100),
      ],
  fromRow: (row) => row,
  toColumns: (row) => <String, Object?>{},
  readColumn: (row, name) => null,
);

MssqlTableSchema table({
  List<MssqlColumnSchema>? columns,
  List<String> primaryKey = const <String>['Id'],
  bool hasEnabledTrigger = false,
}) => MssqlTableSchema(
  schema: 'dbo',
  name: 'Users',
  isView: false,
  columns:
      columns ??
      <MssqlColumnSchema>[
        live('Id', 'int', isIdentity: true),
        live('Name', 'nvarchar', ordinal: 2, maxLength: 100),
      ],
  primaryKey: primaryKey.isEmpty
      ? null
      : MssqlPrimaryKeySchema(name: 'PK', columns: primaryKey),
  foreignKeys: const <MssqlForeignKeySchema>[],
  triggers: hasEnabledTrigger
      ? <MssqlTriggerSchema>[
          MssqlTriggerSchema(
            name: 'tr_Users',
            isDisabled: false,
            isInsteadOf: false,
          ),
        ]
      : const <MssqlTriggerSchema>[],
);

MssqlSchemaReport compare(MssqlTableBinding<Object?> b, MssqlTableSchema t) =>
    MssqlSchemaCheck.compare(b, t);

void main() {
  group('clean', () {
    test('an unchanged table reports nothing', () {
      final report = compare(binding(), table());
      expect(report.isClean, isTrue);
      expect(report.hasBreakingChanges, isFalse);
      expect(report.describe(), contains('matches the database'));
    });
  });

  group('breaking changes', () {
    void expectBreaking(MssqlSchemaReport report, MssqlDifferenceKind kind) {
      final match = report.differences.where((d) => d.kind == kind);
      expect(
        match,
        isNotEmpty,
        reason: '$kind not reported: ${report.describe()}',
      );
      expect(match.first.isBreaking, isTrue);
      expect(match.first.remedy, isNotEmpty);
    }

    test('a dropped column', () {
      expectBreaking(
        compare(
          binding(),
          table(
            columns: <MssqlColumnSchema>[live('Id', 'int', isIdentity: true)],
          ),
        ),
        MssqlDifferenceKind.columnMissing,
      );
    });

    test('a changed type', () {
      expectBreaking(
        compare(
          binding(),
          table(
            columns: <MssqlColumnSchema>[
              live('Id', 'int', isIdentity: true),
              live('Name', 'int', ordinal: 2),
            ],
          ),
        ),
        MssqlDifferenceKind.typeChanged,
      );
    });

    test('NULL becoming NOT NULL', () {
      expectBreaking(
        compare(
          binding(
            columns: <MssqlBoundColumn>[
              bound('Id', MssqlType.int32, isIdentity: true),
              bound('Name', MssqlType.nvarchar, nullable: true, maxLength: 100),
            ],
          ),
          table(),
        ),
        MssqlDifferenceKind.nullabilityChanged,
      );
    });

    test(
      'NOT NULL becoming NULL, because a non-nullable field would get null',
      () {
        expectBreaking(
          compare(
            binding(),
            table(
              columns: <MssqlColumnSchema>[
                live('Id', 'int', isIdentity: true),
                live(
                  'Name',
                  'nvarchar',
                  ordinal: 2,
                  nullable: true,
                  maxLength: 100,
                ),
              ],
            ),
          ),
          MssqlDifferenceKind.nullabilityChanged,
        );
      },
    );

    test('a changed primary key', () {
      expectBreaking(
        compare(binding(), table(primaryKey: const <String>['Name'])),
        MssqlDifferenceKind.primaryKeyChanged,
      );
    });

    test('a primary key that disappeared', () {
      expectBreaking(
        compare(binding(), table(primaryKey: const <String>[])),
        MssqlDifferenceKind.primaryKeyChanged,
      );
    });

    test('an identity column that is no longer one', () {
      expectBreaking(
        compare(
          binding(),
          table(
            columns: <MssqlColumnSchema>[
              live('Id', 'int'),
              live('Name', 'nvarchar', ordinal: 2, maxLength: 100),
            ],
          ),
        ),
        MssqlDifferenceKind.identityChanged,
      );
    });

    test('a trigger added under an OUTPUT INSERTED strategy', () {
      final report = compare(binding(), table(hasEnabledTrigger: true));
      expectBreaking(report, MssqlDifferenceKind.triggerAdded);
      expect(report.describe(), contains('334'));
    });

    test('a shrunken precision or scale', () {
      expectBreaking(
        compare(
          binding(
            columns: <MssqlBoundColumn>[
              bound('Id', MssqlType.int32, isIdentity: true),
              bound('Total', MssqlType.decimal, precision: 18, scale: 4),
            ],
          ),
          table(
            columns: <MssqlColumnSchema>[
              live('Id', 'int', isIdentity: true),
              live('Total', 'decimal', ordinal: 2, precision: 9, scale: 2),
            ],
          ),
        ),
        MssqlDifferenceKind.sizeChanged,
      );
    });

    test('a shrunken max_length', () {
      expectBreaking(
        compare(
          binding(),
          table(
            columns: <MssqlColumnSchema>[
              live('Id', 'int', isIdentity: true),
              live('Name', 'nvarchar', ordinal: 2, maxLength: 20),
            ],
          ),
        ),
        MssqlDifferenceKind.sizeChanged,
      );
    });

    test('a max column narrowed to a fixed length', () {
      expectBreaking(
        compare(
          binding(
            columns: <MssqlBoundColumn>[
              bound('Id', MssqlType.int32, isIdentity: true),
              bound('Name', MssqlType.nvarchar, maxLength: -1),
            ],
          ),
          table(
            columns: <MssqlColumnSchema>[
              live('Id', 'int', isIdentity: true),
              live('Name', 'nvarchar', ordinal: 2, maxLength: 100),
            ],
          ),
        ),
        MssqlDifferenceKind.sizeChanged,
      );
    });

    test('a new NOT NULL column with no default', () {
      expectBreaking(
        compare(
          binding(),
          table(
            columns: <MssqlColumnSchema>[
              live('Id', 'int', isIdentity: true),
              live('Name', 'nvarchar', ordinal: 2, maxLength: 100),
              live('Region', 'nvarchar', ordinal: 3, maxLength: 40),
            ],
          ),
        ),
        MssqlDifferenceKind.columnAdded,
      );
    });
  });

  group('benign changes stay quiet', () {
    void expectBenign(MssqlSchemaReport report, MssqlDifferenceKind kind) {
      final match = report.differences.where((d) => d.kind == kind);
      expect(match, isNotEmpty, reason: '$kind not reported');
      expect(match.first.isBreaking, isFalse);
      expect(report.hasBreakingChanges, isFalse);
    }

    test('a new nullable column', () {
      expectBenign(
        compare(
          binding(),
          table(
            columns: <MssqlColumnSchema>[
              live('Id', 'int', isIdentity: true),
              live('Name', 'nvarchar', ordinal: 2, maxLength: 100),
              live(
                'Region',
                'nvarchar',
                ordinal: 3,
                nullable: true,
                maxLength: 40,
              ),
            ],
          ),
        ),
        MssqlDifferenceKind.columnAdded,
      );
    });

    test('a new NOT NULL column that has a default', () {
      expectBenign(
        compare(
          binding(),
          table(
            columns: <MssqlColumnSchema>[
              live('Id', 'int', isIdentity: true),
              live('Name', 'nvarchar', ordinal: 2, maxLength: 100),
              live(
                'CreatedAt',
                'datetime2',
                ordinal: 3,
                hasDefault: true,
                scale: 3,
              ),
            ],
          ),
        ),
        MssqlDifferenceKind.columnAdded,
      );
    });

    test('a widened precision', () {
      expectBenign(
        compare(
          binding(
            columns: <MssqlBoundColumn>[
              bound('Id', MssqlType.int32, isIdentity: true),
              bound('Total', MssqlType.decimal, precision: 9, scale: 2),
            ],
          ),
          table(
            columns: <MssqlColumnSchema>[
              live('Id', 'int', isIdentity: true),
              live('Total', 'decimal', ordinal: 2, precision: 18, scale: 4),
            ],
          ),
        ),
        MssqlDifferenceKind.sizeChanged,
      );
    });

    test('a max column is wider than any fixed length', () {
      final report = compare(
        binding(),
        table(
          columns: <MssqlColumnSchema>[
            live('Id', 'int', isIdentity: true),
            live('Name', 'nvarchar', ordinal: 2, maxLength: -1),
          ],
        ),
      );
      expect(report.hasBreakingChanges, isFalse);
    });

    test('a trigger removed under SCOPE_IDENTITY', () {
      expectBenign(
        compare(binding(strategy: MssqlInsertStrategy.scopeIdentity), table()),
        MssqlDifferenceKind.triggerRemoved,
      );
    });
  });

  group('the report', () {
    test('names the table, the column and what to do', () {
      final report = compare(
        binding(),
        table(primaryKey: const <String>['Name']),
      );
      final text = report.describe();
      expect(text, contains('dbo.Users'));
      expect(text, contains('breaking'));
      expect(text, contains('regenerate'));
    });

    test('separates breaking from the rest', () {
      final report = compare(
        binding(),
        table(
          primaryKey: const <String>['Name'],
          columns: <MssqlColumnSchema>[
            live('Id', 'int', isIdentity: true),
            live('Name', 'nvarchar', ordinal: 2, maxLength: 100),
            live('Extra', 'int', ordinal: 3, nullable: true),
          ],
        ),
      );
      expect(report.differences.length, greaterThan(report.breaking.length));
      expect(report.hasBreakingChanges, isTrue);
    });
  });

  group('the fingerprint', () {
    test('is stable for the same schema and changes with it', () {
      final a = table();
      expect(fingerprintOf(a), fingerprintOf(table()));
      expect(
        fingerprintOf(a),
        isNot(fingerprintOf(table(hasEnabledTrigger: true))),
      );
      expect(
        fingerprintOf(a),
        isNot(fingerprintOf(table(primaryKey: const <String>['Name']))),
      );
    });

    test('matchesFingerprint answers the cheap yes/no', () {
      final b = MssqlTableBinding<Object?>(
        schema: 'dbo',
        table: 'Users',
        primaryKey: const <String>['Id'],
        schemaFingerprint: fingerprintOf(table()),
        columns: <MssqlBoundColumn>[bound('Id', MssqlType.int32)],
        fromRow: (row) => row,
        toColumns: (row) => <String, Object?>{},
        readColumn: (row, name) => null,
      );
      expect(MssqlSchemaCheck.matchesFingerprint(b, table()), isTrue);
      expect(
        MssqlSchemaCheck.matchesFingerprint(b, table(hasEnabledTrigger: true)),
        isFalse,
      );
    });

    test(
      'an empty fingerprint never matches, rather than matching anything',
      () {
        final b = binding();
        expect(MssqlSchemaCheck.matchesFingerprint(b, table()), isFalse);
      },
    );
  });

  group('verify reads the live schema before comparing', () {
    Map<String, Object?> objectRow() => <String, Object?>{
      'object_id': 1,
      'name': 'Users',
      'schema_name': 'dbo',
      'type': 'U',
    };

    Map<String, Object?> columnRow(
      int ordinal,
      String name,
      String typeName, {
      bool nullable = false,
      bool identity = false,
      int maxLength = 0,
      int precision = 0,
      int scale = 0,
    }) => <String, Object?>{
      'object_id': 1,
      'column_id': ordinal,
      'name': name,
      'type_name': typeName,
      'max_length': maxLength,
      'precision': precision,
      'scale': scale,
      'is_nullable': nullable,
      'is_identity': identity,
      'is_computed': false,
      'has_default': 0,
    };

    Map<String, Object?> primaryKeyRow(int ordinal, String column) =>
        <String, Object?>{
          'object_id': 1,
          'index_name': 'PK_Users',
          'column_name': column,
          'key_ordinal': ordinal,
        };

    FakeConnection matchingConnection() =>
        FakeConnection()
          ..replies.addAll(<List<Map<String, Object?>>>[
            <Map<String, Object?>>[objectRow()],
            <Map<String, Object?>>[
              columnRow(1, 'Id', 'int', identity: true),
              columnRow(2, 'Name', 'nvarchar', maxLength: 100),
            ],
            <Map<String, Object?>>[primaryKeyRow(1, 'Id')],
            <Map<String, Object?>>[],
            <Map<String, Object?>>[],
            <Map<String, Object?>>[],
          ]);

    test('reports the same differences compare would', () async {
      final report = await MssqlSchemaCheck.verify(
        matchingConnection(),
        bindings: <MssqlTableBinding<Object?>>[binding()],
      );
      expect(report.isClean, isTrue);
      expect(report.differences, isEmpty);
    });

    test('a table missing from the database is breaking', () async {
      final report = await MssqlSchemaCheck.verify(
        FakeConnection(),
        bindings: <MssqlTableBinding<Object?>>[binding()],
      );
      final difference = report.differences.single;
      expect(difference.kind, MssqlDifferenceKind.tableMissing);
      expect(difference.isBreaking, isTrue);
      expect(difference.table, 'dbo.Users');
    });

    test(
      'nothing to check is clean, and asks nothing of the database',
      () async {
        final fake = FakeConnection();
        final report = await MssqlSchemaCheck.verify(
          fake,
          bindings: <MssqlTableBinding<Object?>>[],
        );
        expect(report.isClean, isTrue);
        expect(fake.calls, isEmpty);
      },
    );

    test('reads every schema a binding names', () async {
      final fake = matchingConnection();
      final second = MssqlTableBinding<Object?>(
        schema: 'erp',
        table: 'Orders',
        primaryKey: const <String>['Id'],
        columns: <MssqlBoundColumn>[bound('Id', MssqlType.int32)],
        fromRow: (row) => row,
        toColumns: (row) => <String, Object?>{},
        readColumn: (row, name) => null,
      );
      final report = await MssqlSchemaCheck.verify(
        fake,
        bindings: <MssqlTableBinding<Object?>>[binding(), second],
      );
      expect(report.differences.map((d) => d.kind), <MssqlDifferenceKind>[
        MssqlDifferenceKind.tableMissing,
      ]);
      final schemas = fake.calls.first.parameters.values
          .map((v) => (v! as MssqlValue).value)
          .toList();
      expect(schemas, containsAll(<Object?>['dbo', 'erp']));
    });
  });
}

