import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:test/test.dart';

import 'support/fake_driver.dart';

class CatalogRows {
  CatalogRows({
    this.objects = const <Map<String, Object?>>[],
    this.columns = const <Map<String, Object?>>[],
    this.primaryKeys = const <Map<String, Object?>>[],
    this.uniqueKeys = const <Map<String, Object?>>[],
    this.foreignKeys = const <Map<String, Object?>>[],
    this.triggerOwners = const <Map<String, Object?>>[],
  });

  final List<Map<String, Object?>> objects;
  final List<Map<String, Object?>> columns;
  final List<Map<String, Object?>> primaryKeys;
  final List<Map<String, Object?>> uniqueKeys;
  final List<Map<String, Object?>> foreignKeys;
  final List<Map<String, Object?>> triggerOwners;

  FakeConnection get connection => FakeConnection()
    ..replies.addAll(<List<Map<String, Object?>>>[
      objects,
      columns,
      primaryKeys,
      uniqueKeys,
      foreignKeys,
      triggerOwners,
    ]);
}

Map<String, Object?> object(
  int id,
  String name, {
  String schema = 'dbo',
  String type = 'U',
}) => <String, Object?>{
  'object_id': id,
  'name': name,
  'schema_name': schema,
  'type': type,
};

Map<String, Object?> col(
  int objectId,
  int ordinal,
  String name,
  String type, {
  bool nullable = false,
  bool identity = false,
  bool computed = false,
  int hasDefault = 0,
  int maxLength = 0,
  int precision = 0,
  int scale = 0,
}) => <String, Object?>{
  'object_id': objectId,
  'column_id': ordinal,
  'name': name,
  'type_name': type,
  'max_length': maxLength,
  'precision': precision,
  'scale': scale,
  'is_nullable': nullable,
  'is_identity': identity,
  'is_computed': computed,
  'has_default': hasDefault,
};

void main() {
  group('refusals', () {
    test('naming no schema is refused before anything is asked', () async {
      final fake = FakeConnection();
      await expectLater(
        MssqlSchemaReader(fake).readTables(schemas: const <String>{}),
        throwsArgumentError,
      );
      expect(fake.calls, isEmpty);
    });

    test('a column type nothing maps stops the read', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'T')],
        columns: <Map<String, Object?>>[col(1, 1, 'Shape', 'myUserType')],
      );
      await expectLater(
        MssqlSchemaReader(rows.connection).readTables(),
        throwsA(
          isA<MssqlException>()
              .having((e) => e.message, 'message', contains('Shape'))
              .having((e) => e.message, 'message', contains('myUserType')),
        ),
      );
    });

    test('readTable refuses a name with too many parts', () async {
      await expectLater(
        MssqlSchemaReader(FakeConnection()).readTable('a.b.c'),
        throwsArgumentError,
      );
    });
  });

  group('assembling a table', () {
    Future<List<MssqlTableSchema>> read([CatalogRows? rows]) =>
        MssqlSchemaReader(
          (rows ?? _orders).connection,
        ).readTables(schemas: <String>{'dbo'});

    test('columns, key and flags come together', () async {
      final tables = await read();
      final orders = tables.single;
      expect(orders.qualifiedName, 'dbo.Orders');
      expect(orders.isView, isFalse);
      expect(orders.columns.map((c) => c.name), <String>['Id', 'Total']);
      expect(orders.primaryKey!.columns, <String>['Id']);
      expect(orders.identityColumn!.name, 'Id');
      expect(orders.column('Total')!.precision, 18);
      expect(orders.column('Total')!.scale, 4);
    });

    test('a column lookup ignores case, and a missing one is null', () async {
      final orders = (await read()).single;
      expect(orders.column('total')!.name, 'Total');
      expect(orders.column('TOTAL')!.name, 'Total');
      expect(orders.column('NoSuch'), isNull);
    });

    test('tables come back sorted by schema then name', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[
          object(2, 'Zebra'),
          object(3, 'Apple', schema: 'aaa'),
          object(1, 'Beta'),
        ],
        columns: <Map<String, Object?>>[
          col(1, 1, 'Id', 'int'),
          col(2, 1, 'Id', 'int'),
          col(3, 1, 'Id', 'int'),
        ],
      );
      final tables = await MssqlSchemaReader(
        rows.connection,
      ).readTables(schemas: <String>{'dbo', 'aaa'});
      expect(tables.map((t) => t.qualifiedName), <String>[
        'aaa.Apple',
        'dbo.Beta',
        'dbo.Zebra',
      ]);
    });

    test('a view is marked as one', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'OpenOrders', type: 'V')],
        columns: <Map<String, Object?>>[col(1, 1, 'Id', 'int')],
      );
      expect((await read(rows)).single.isView, isTrue);
    });

    test('a table with no columns still comes back', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'Empty')],
      );
      final tables = await read(rows);
      expect(tables.single.columns, isEmpty);
      expect(tables.single.primaryKey, isNull);
    });

    test('no object at all means no further queries are wasted', () async {
      final fake = CatalogRows().connection;
      expect(await MssqlSchemaReader(fake).readTables(), isEmpty);
      expect(fake.calls, hasLength(1));
    });
  });

  group('the SQL it sends', () {
    test('views are asked for by default and excluded on request', () async {
      final withViews = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'T')],
        columns: <Map<String, Object?>>[col(1, 1, 'Id', 'int')],
      ).connection;
      await MssqlSchemaReader(withViews).readTables();
      expect(withViews.calls.first.sql, contains("o.type IN ('U', 'V')"));

      final without = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'T')],
        columns: <Map<String, Object?>>[col(1, 1, 'Id', 'int')],
      ).connection;
      await MssqlSchemaReader(without).readTables(includeViews: false);
      expect(without.calls.first.sql, contains("o.type IN ('U')"));
    });

    test('schemas travel as parameters, not as text', () async {
      final fake = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'T')],
        columns: <Map<String, Object?>>[col(1, 1, 'Id', 'int')],
      ).connection;
      await MssqlSchemaReader(fake).readTables(schemas: <String>{'dbo', 'erp'});
      expect(fake.calls.first.sql, contains('IN (@s0, @s1)'));
      expect(fake.calls.first.parameters, hasLength(2));
      expect(fake.calls.first.sql, isNot(contains("'dbo'")));
    });

    test('it reads sys.*, not INFORMATION_SCHEMA', () async {
      final fake = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'T')],
        columns: <Map<String, Object?>>[col(1, 1, 'Id', 'int')],
      ).connection;
      await MssqlSchemaReader(fake).readTables();
      for (final call in fake.calls) {
        expect(call.sql, isNot(contains('INFORMATION_SCHEMA')));
      }
      expect(fake.calls.map((c) => c.sql).join(), contains('sys.columns'));
      expect(fake.calls.map((c) => c.sql).join(), contains('sys.triggers'));
    });

    test('one query per catalog concern, not one per table', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[
          for (var i = 1; i <= 40; i++) object(i, 'T$i'),
        ],
        columns: <Map<String, Object?>>[
          for (var i = 1; i <= 40; i++) col(i, 1, 'Id', 'int'),
        ],
      );
      final fake = rows.connection;
      final tables = await MssqlSchemaReader(fake).readTables();
      expect(tables, hasLength(40));
      expect(fake.calls, hasLength(6));
    });
  });

  group('filters', () {
    CatalogRows three() => CatalogRows(
      objects: <Map<String, Object?>>[
        object(1, 'CompositeParent'),
        object(2, 'CompositeChild'),
        object(3, 'Orders'),
      ],
      columns: <Map<String, Object?>>[
        col(1, 1, 'Id', 'int'),
        col(2, 1, 'Id', 'int'),
        col(3, 1, 'Id', 'int'),
      ],
    );

    test('include matches a glob', () async {
      final tables = await MssqlSchemaReader(
        three().connection,
      ).readTables(include: <String>['Compos*']);
      expect(tables.map((t) => t.name), <String>[
        'CompositeChild',
        'CompositeParent',
      ]);
    });

    test('exclude wins over include', () async {
      final tables = await MssqlSchemaReader(
        three().connection,
      ).readTables(include: <String>['Compos*'], exclude: <String>['*Child']);
      expect(tables.map((t) => t.name), <String>['CompositeParent']);
    });

    test(
      'matching is case-insensitive, as SQL Server collations are',
      () async {
        final tables = await MssqlSchemaReader(
          three().connection,
        ).readTables(include: <String>['orders']);
        expect(tables.single.name, 'Orders');
      },
    );

    test(
      'a filter matching nothing yields an empty list, not an error',
      () async {
        expect(
          await MssqlSchemaReader(
            three().connection,
          ).readTables(include: <String>['NoSuch']),
          isEmpty,
        );
      },
    );
  });

  group('keys and constraints', () {
    test('a composite primary key keeps its key order', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'T')],
        columns: <Map<String, Object?>>[
          col(1, 1, 'TenantId', 'int'),
          col(1, 2, 'Code', 'varchar', maxLength: 10),
        ],
        primaryKeys: <Map<String, Object?>>[
          <String, Object?>{
            'object_id': 1,
            'index_name': 'PK_T',
            'column_name': 'TenantId',
            'key_ordinal': 1,
          },
          <String, Object?>{
            'object_id': 1,
            'index_name': 'PK_T',
            'column_name': 'Code',
            'key_ordinal': 2,
          },
        ],
      );
      final table = (await MssqlSchemaReader(
        rows.connection,
      ).readTables()).single;
      expect(table.primaryKey!.columns, <String>['TenantId', 'Code']);
      expect(table.primaryKey!.name, 'PK_T');
    });

    test('unique keys are grouped per index', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'T')],
        columns: <Map<String, Object?>>[
          col(1, 1, 'Id', 'int'),
          col(1, 2, 'Slug', 'varchar', maxLength: 40),
          col(1, 3, 'A', 'int'),
          col(1, 4, 'B', 'int'),
        ],
        uniqueKeys: <Map<String, Object?>>[
          <String, Object?>{
            'object_id': 1,
            'index_id': 1,
            'column_name': 'Slug',
            'key_ordinal': 1,
          },
          <String, Object?>{
            'object_id': 1,
            'index_id': 2,
            'column_name': 'A',
            'key_ordinal': 1,
          },
          <String, Object?>{
            'object_id': 1,
            'index_id': 2,
            'column_name': 'B',
            'key_ordinal': 2,
          },
        ],
      );
      final table = (await MssqlSchemaReader(
        rows.connection,
      ).readTables()).single;
      expect(table.isUnique(<String>['Slug']), isTrue);
      expect(table.isUnique(<String>['A', 'B']), isTrue);
      expect(table.isUnique(<String>['B', 'A']), isTrue);
      expect(table.isUnique(<String>['A']), isFalse);
    });

    test('a composite foreign key pairs its columns positionally', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'Child')],
        columns: <Map<String, Object?>>[
          col(1, 1, 'TenantId', 'int'),
          col(1, 2, 'Code', 'varchar', maxLength: 10),
        ],
        foreignKeys: <Map<String, Object?>>[
          <String, Object?>{
            'fk_id': 9,
            'parent_object_id': 1,
            'fk_name': 'FK_Child',
            'parent_column': 'TenantId',
            'referenced_schema': 'dbo',
            'referenced_table': 'Parent',
            'referenced_column': 'TenantId',
            'constraint_column_id': 1,
          },
          <String, Object?>{
            'fk_id': 9,
            'parent_object_id': 1,
            'fk_name': 'FK_Child',
            'parent_column': 'Code',
            'referenced_schema': 'dbo',
            'referenced_table': 'Parent',
            'referenced_column': 'Code',
            'constraint_column_id': 2,
          },
        ],
      );
      final fk = (await MssqlSchemaReader(
        rows.connection,
      ).readTables()).single.foreignKeys.single;
      expect(fk.columns, <String>['TenantId', 'Code']);
      expect(fk.referencedColumns, <String>['TenantId', 'Code']);
      expect(fk.referencedQualifiedName, 'dbo.Parent');
    });

    test(
      'several foreign keys on one table come back sorted by name',
      () async {
        final rows = CatalogRows(
          objects: <Map<String, Object?>>[object(1, 'T')],
          columns: <Map<String, Object?>>[
            col(1, 1, 'A', 'int'),
            col(1, 2, 'B', 'int'),
          ],
          foreignKeys: <Map<String, Object?>>[
            <String, Object?>{
              'fk_id': 2,
              'parent_object_id': 1,
              'fk_name': 'FK_Zebra',
              'parent_column': 'B',
              'referenced_schema': 'dbo',
              'referenced_table': 'Z',
              'referenced_column': 'Id',
              'constraint_column_id': 1,
            },
            <String, Object?>{
              'fk_id': 1,
              'parent_object_id': 1,
              'fk_name': 'FK_Apple',
              'parent_column': 'A',
              'referenced_schema': 'dbo',
              'referenced_table': 'A',
              'referenced_column': 'Id',
              'constraint_column_id': 1,
            },
          ],
        );
        final table = (await MssqlSchemaReader(
          rows.connection,
        ).readTables()).single;
        expect(table.foreignKeys.map((f) => f.name), <String>[
          'FK_Apple',
          'FK_Zebra',
        ]);
      },
    );

    test('an enabled trigger marks its table', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'A'), object(2, 'B')],
        columns: <Map<String, Object?>>[
          col(1, 1, 'Id', 'int'),
          col(2, 1, 'Id', 'int'),
        ],
        triggerOwners: <Map<String, Object?>>[
          <String, Object?>{
            'parent_id': 2,
            'object_id': 900,
            'name': 'trB',
            'is_disabled': false,
            'is_instead_of_trigger': false,
            'event_type': 'INSERT',
          },
        ],
      );
      final tables = await MssqlSchemaReader(rows.connection).readTables();
      expect(
        tables.firstWhere((t) => t.name == 'A').hasEnabledTrigger,
        isFalse,
      );
      expect(tables.firstWhere((t) => t.name == 'B').hasEnabledTrigger, isTrue);
    });

    test('the trigger query reads what each trigger is', () async {
      final fake = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'T')],
        columns: <Map<String, Object?>>[col(1, 1, 'Id', 'int')],
      ).connection;
      await MssqlSchemaReader(fake).readTables();
      expect(fake.calls.last.sql, contains('tr.is_disabled'));
      expect(fake.calls.last.sql, contains('tr.is_instead_of_trigger'));
    });
  });

  group('column flags', () {
    Future<MssqlColumnSchema> single(Map<String, Object?> row) async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'T')],
        columns: <Map<String, Object?>>[row],
      );
      return (await MssqlSchemaReader(
        rows.connection,
      ).readTables()).single.columns.single;
    }

    test('a boolean flag is read from bool, number or string alike', () async {
      for (final value in <Object?>[true, 1, '1', 'true']) {
        final column = await single(<String, Object?>{
          ...col(1, 1, 'C', 'int'),
          'is_nullable': value,
        });
        expect(column.nullable, isTrue, reason: '$value');
      }
      for (final value in <Object?>[false, 0, '0', null, 'no']) {
        final column = await single(<String, Object?>{
          ...col(1, 1, 'C', 'int'),
          'is_nullable': value,
        });
        expect(column.nullable, isFalse, reason: '$value');
      }
    });

    test('rowversion is recognised by its type name', () async {
      expect(
        (await single(col(1, 1, 'Version', 'timestamp'))).isRowVersion,
        isTrue,
      );
      expect(
        (await single(col(1, 1, 'Payload', 'varbinary'))).isRowVersion,
        isFalse,
      );
    });

    test('isServerGenerated collapses the three the server owns', () async {
      expect(
        (await single(col(1, 1, 'C', 'int', identity: true))).isServerGenerated,
        isTrue,
      );
      expect(
        (await single(col(1, 1, 'C', 'int', computed: true))).isServerGenerated,
        isTrue,
      );
      expect(
        (await single(col(1, 1, 'C', 'timestamp'))).isServerGenerated,
        isTrue,
      );
      expect((await single(col(1, 1, 'C', 'int'))).isServerGenerated, isFalse);
    });

    test('a default constraint is reported', () async {
      expect(
        (await single(col(1, 1, 'C', 'int', hasDefault: 1))).hasDefault,
        isTrue,
      );
      expect((await single(col(1, 1, 'C', 'int'))).hasDefault, isFalse);
    });

    test('toString names the column and whether it is nullable', () async {
      final column = await single(
        col(1, 1, 'Name', 'nvarchar', nullable: true),
      );
      expect(column.toString(), contains('Name'));
      expect(column.toString(), contains('nvarchar'));
      expect(column.toString(), contains('NULL'));
    });
  });

  group('readTable', () {
    CatalogRows one() => CatalogRows(
      objects: <Map<String, Object?>>[object(1, 'Orders')],
      columns: <Map<String, Object?>>[col(1, 1, 'Id', 'int')],
    );

    test('a qualified name selects its schema', () async {
      final fake = CatalogRows(
        objects: <Map<String, Object?>>[object(1, 'Orders', schema: 'erp')],
        columns: <Map<String, Object?>>[col(1, 1, 'Id', 'int')],
      ).connection;
      final table = await MssqlSchemaReader(fake).readTable('erp.Orders');
      expect(table!.qualifiedName, 'erp.Orders');
      expect(
        (fake.calls.first.parameters.values.single! as MssqlValue).value,
        'erp',
      );
    });

    test('an unqualified name means dbo', () async {
      final fake = one().connection;
      expect(
        (await MssqlSchemaReader(fake).readTable('Orders'))!.schema,
        'dbo',
      );
    });

    test('the name is matched without regard to case', () async {
      expect(
        (await MssqlSchemaReader(one().connection).readTable('orders'))!.name,
        'Orders',
      );
    });

    test('nothing found is null, rather than an exception to catch', () async {
      expect(
        await MssqlSchemaReader(CatalogRows().connection).readTable('Nope'),
        isNull,
      );
    });
  });

  group('the table model', () {
    test('quoted and nameParts describe the same table two ways', () async {
      final rows = CatalogRows(
        objects: <Map<String, Object?>>[
          object(1, 'Order Lines', schema: 'erp'),
        ],
        columns: <Map<String, Object?>>[col(1, 1, 'Id', 'int')],
      );
      final table = (await MssqlSchemaReader(
        rows.connection,
      ).readTables(schemas: <String>{'erp'})).single;
      expect(table.quoted, '[erp].[Order Lines]');
      expect(table.qualifiedName, 'erp.Order Lines');
      expect(table.toString(), contains('erp.Order Lines'));
    });
  });

  group('include and exclude accept a name written either way', () {
    CatalogRows two() => CatalogRows(
      objects: <Map<String, Object?>>[
        object(1, 'Orders'),
        object(2, 'Orders', schema: 'sales'),
        object(3, 'Customers'),
      ],
      columns: <Map<String, Object?>>[
        col(1, 1, 'Id', 'int'),
        col(2, 1, 'Id', 'int'),
        col(3, 1, 'Id', 'int'),
      ],
    );

    Future<List<String>> read({
      List<String> include = const <String>['*'],
      List<String> exclude = const <String>[],
    }) async => <String>[
      for (final table in await MssqlSchemaReader(two().connection).readTables(
        schemas: const <String>{'dbo', 'sales'},
        include: include,
        exclude: exclude,
      ))
        table.qualifiedName,
    ];

    test('a bare name still matches every schema that has it', () async {
      expect(await read(include: <String>['Orders']), <String>[
        'dbo.Orders',
        'sales.Orders',
      ]);
    });

    test('a qualified name picks out the one table', () async {
      expect(await read(include: <String>['dbo.Orders']), <String>[
        'dbo.Orders',
      ]);
    });

    test('the case does not have to match', () async {
      expect(await read(include: <String>['DBO.orders']), <String>[
        'dbo.Orders',
      ]);
    });

    test('a wildcard works on either form', () async {
      expect(await read(include: <String>['sales.*']), <String>[
        'sales.Orders',
      ]);
      expect(await read(include: <String>['*.Orders']), <String>[
        'dbo.Orders',
        'sales.Orders',
      ]);
    });

    test('exclude reads the same way, and still wins', () async {
      expect(await read(exclude: <String>['sales.Orders']), <String>[
        'dbo.Customers',
        'dbo.Orders',
      ]);
      expect(
        await read(include: <String>['Orders'], exclude: <String>['dbo.*']),
        <String>['sales.Orders'],
      );
    });
  });
}

CatalogRows get _orders => CatalogRows(
  objects: <Map<String, Object?>>[object(1, 'Orders')],
  columns: <Map<String, Object?>>[
    col(1, 1, 'Id', 'int', identity: true),
    col(1, 2, 'Total', 'decimal', precision: 18, scale: 4),
  ],
  primaryKeys: <Map<String, Object?>>[
    <String, Object?>{
      'object_id': 1,
      'index_name': 'PK_Orders',
      'column_name': 'Id',
      'key_ordinal': 1,
    },
  ],
);

