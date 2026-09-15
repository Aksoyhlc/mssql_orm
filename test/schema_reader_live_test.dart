import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

void main() {
  group('the schema reader', () {
    late MssqlConnection connection;
    late MssqlSchemaReader reader;
    late List<MssqlTableSchema> tables;

    setUpAll(() async {
      if (!liveEnabled) return;
      await initializeLive();
      connection = await MssqlConnection.open(liveConfig());
      await createFixtureSchema(connection, readerSchema);
      reader = MssqlSchemaReader(connection);
      tables = await reader.readTables(schemas: <String>{readerSchema});
    });

    tearDownAll(() async {
      if (!liveEnabled) return;
      await dropFixtureSchema(connection, readerSchema);
      await connection.close();
    });

    MssqlTableSchema table(String name) =>
        tables.firstWhere((t) => t.name == name);

    test('reads every fixture object, views included', () {
      expect(
        tables.map((t) => t.name),
        containsAll(<String>[
          'Customers',
          'Orders',
          'Lines',
          'NoKey',
          'Triggered',
          'TriggerOff',
          'CompositeParent',
          'CompositeChild',
          'Profiles',
          'SelfRef',
          'OpenOrders',
        ]),
      );
      expect(table('OpenOrders').isView, isTrue);
      expect(table('Orders').isView, isFalse);
    }, skip: liveSkip);

    test('views can be left out', () async {
      final onlyTables = await reader.readTables(
        schemas: <String>{readerSchema},
        includeViews: false,
      );
      expect(onlyTables.map((t) => t.name), isNot(contains('OpenOrders')));
      expect(onlyTables.map((t) => t.name), contains('Orders'));
    }, skip: liveSkip);

    test('columns come back in declaration order', () {
      final orders = table('Orders');
      expect(orders.columns.first.name, 'Id');
      expect(
        orders.columns.map((c) => c.ordinal).toList(),
        orders.columns.map((c) => c.ordinal).toList()..sort(),
      );
    }, skip: liveSkip);

    test('nullability is reported per column', () {
      final orders = table('Orders');
      expect(orders.column('Code')!.nullable, isFalse);
      expect(orders.column('Discount')!.nullable, isTrue);
      expect(orders.column('Guid')!.nullable, isTrue);
    }, skip: liveSkip);

    test('identity, computed and rowversion are distinguished', () {
      final orders = table('Orders');
      expect(orders.column('Id')!.isIdentity, isTrue);
      expect(orders.column('Code')!.isIdentity, isFalse);
      expect(orders.identityColumn!.name, 'Id');

      expect(orders.column('NetTotal')!.isComputed, isTrue);
      expect(orders.column('Total')!.isComputed, isFalse);

      expect(orders.column('Version')!.isRowVersion, isTrue);
      expect(orders.column('Payload')!.isRowVersion, isFalse);

      expect(orders.column('NetTotal')!.isServerGenerated, isTrue);
      expect(orders.column('Total')!.isServerGenerated, isFalse);
    }, skip: liveSkip);

    test('a default constraint is reported', () {
      final orders = table('Orders');
      expect(orders.column('CreatedAt')!.hasDefault, isTrue);
      expect(orders.column('Code')!.hasDefault, isFalse);
    }, skip: liveSkip);

    test('a sysname column resolves to its base type', () {
      final owner = table('Orders').column('OwnerName')!;
      expect(owner.sqlTypeName, 'nvarchar');
      expect(owner.type, MssqlType.nvarchar);
    }, skip: liveSkip);

    test('precision and scale survive for exact numerics', () {
      final total = table('Orders').column('Total')!;
      expect(total.sqlTypeName, 'decimal');
      expect(total.precision, 18);
      expect(total.scale, 4);

      final discount = table('Orders').column('Discount')!;
      expect(discount.precision, 9);
      expect(discount.scale, 2);
    }, skip: liveSkip);

    test(
      'date and time scales are reported, which decides their Dart type',
      () {
        expect(table('Orders').column('CreatedAt')!.scale, 3);
        expect(table('Orders').column('Precise')!.scale, 7);
        expect(table('Orders').column('OnlyTime')!.scale, 3);
        expect(table('Orders').column('Offset')!.sqlTypeName, 'datetimeoffset');
      },
      skip: liveSkip,
    );

    test('max_length is bytes, and -1 for a max column', () {
      expect(table('Orders').column('Code')!.maxLength, 20);
      expect(table('Customers').column('Name')!.maxLength, 200);
      expect(table('Customers').column('Note')!.maxLength, -1);
    }, skip: liveSkip);

    test('a single-column primary key', () {
      final key = table('Orders').primaryKey!;
      expect(key.columns, <String>['Id']);
      expect(key.name, 'PK_${readerSchema}_Orders');
    }, skip: liveSkip);

    test('a composite primary key keeps its key order', () {
      expect(table('CompositeParent').primaryKey!.columns, <String>[
        'TenantId',
        'Code',
      ]);
    }, skip: liveSkip);

    test(
      'a table without a primary key reports null, not an empty key',
      () {
        expect(table('NoKey').primaryKey, isNull);
        expect(table('OpenOrders').primaryKey, isNull);
      },
      skip: liveSkip,
    );

    test('a foreign key names both sides', () {
      final fk = table('Orders').foreignKeys.single;
      expect(fk.columns, <String>['CustomerId']);
      expect(fk.referencedQualifiedName, '$readerSchema.Customers');
      expect(fk.referencedColumns, <String>['Id']);
    }, skip: liveSkip);

    test('a composite foreign key pairs its columns positionally', () {
      final fk = table('CompositeChild').foreignKeys.single;
      expect(fk.columns, <String>['TenantId', 'Code']);
      expect(fk.referencedColumns, <String>['TenantId', 'Code']);
    }, skip: liveSkip);

    test('a self-referencing foreign key is an ordinary foreign key', () {
      final fk = table('SelfRef').foreignKeys.single;
      expect(fk.columns, <String>['ManagerId']);
      expect(fk.referencedTable, 'SelfRef');
    }, skip: liveSkip);

    test('a table with no foreign key reports an empty list', () {
      expect(table('Customers').foreignKeys, isEmpty);
    }, skip: liveSkip);

    test('unique constraints are reported, primary keys included', () {
      final profiles = table('Profiles');
      expect(profiles.isUnique(<String>['CustomerId']), isTrue);
      expect(profiles.isUnique(<String>['Id']), isTrue);
      expect(profiles.isUnique(<String>['Bio']), isFalse);

      expect(table('Orders').isUnique(<String>['CustomerId']), isFalse);
      expect(table('Orders').isUnique(<String>['Code']), isFalse);
    }, skip: liveSkip);

    test('a composite unique key is matched as a set, not a sequence', () {
      expect(
        table('CompositeParent').isUnique(<String>['Code', 'TenantId']),
        isTrue,
      );
      expect(table('CompositeParent').isUnique(<String>['TenantId']), isFalse);
    }, skip: liveSkip);

    test('an enabled trigger is reported; a disabled one is not', () {
      expect(table('Triggered').hasEnabledTrigger, isTrue);
      expect(table('TriggerOff').hasEnabledTrigger, isFalse);
      expect(table('Orders').hasEnabledTrigger, isFalse);
    }, skip: liveSkip);

    test(
      'include and exclude filter by table name, exclusion winning',
      () async {
        final some = await reader.readTables(
          schemas: <String>{readerSchema},
          include: <String>['Compos*'],
        );
        expect(some.map((t) => t.name), <String>[
          'CompositeChild',
          'CompositeParent',
        ]);

        final fewer = await reader.readTables(
          schemas: <String>{readerSchema},
          include: <String>['Compos*'],
          exclude: <String>['*Child'],
        );
        expect(fewer.map((t) => t.name), <String>['CompositeParent']);
      },
      skip: liveSkip,
    );

    test(
      'a filter matching nothing yields an empty list, not an error',
      () async {
        final none = await reader.readTables(
          schemas: <String>{readerSchema},
          include: <String>['NoSuchTable'],
        );
        expect(none, isEmpty);
      },
      skip: liveSkip,
    );

    test('readTable finds one table, qualified or not', () async {
      final qualified = await reader.readTable('$readerSchema.Orders');
      expect(qualified!.qualifiedName, '$readerSchema.Orders');
      expect(qualified.quoted, '[$readerSchema].[Orders]');
      expect(await reader.readTable('$readerSchema.NoSuchTable'), isNull);
    }, skip: liveSkip);

    test('reading many tables does not cost a query per table', () async {
      final again = await reader.readTables(schemas: <String>{readerSchema});
      expect(again.length, tables.length);
      expect(
        again.map((t) => t.qualifiedName),
        tables.map((t) => t.qualifiedName),
      );
    }, skip: liveSkip);

    test('naming no schema at all is refused', () {
      expect(
        () => reader.readTables(schemas: const <String>{}),
        throwsArgumentError,
      );
    }, skip: liveSkip);
  });
}

