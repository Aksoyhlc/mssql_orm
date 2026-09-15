import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_executor.dart';

class OrderRow {
  const OrderRow({
    required this.id,
    required this.customerId,
    this.customer,
    this.lines,
    this.loaded = const <String>{},
  });

  factory OrderRow.fromRow(MssqlRow row) => OrderRow(
    id: (row['Id']! as num).toInt(),
    customerId: (row['CustomerId'] as num?)?.toInt(),
  );

  final int id;
  final int? customerId;
  final CustomerRow? customer;
  final List<LineRow>? lines;
  final Set<String> loaded;

  Map<String, Object?> toColumns() => <String, Object?>{
    'Id': id,
    'CustomerId': customerId,
  };

  OrderRow withRelations(Map<String, Object?> relations) => OrderRow(
    id: id,
    customerId: customerId,
    customer: relations.containsKey('customer')
        ? relations['customer'] as CustomerRow?
        : customer,
    lines: relations.containsKey('lines')
        ? (relations['lines']! as List<Object?>).cast<LineRow>()
        : lines,
    loaded: <String>{...loaded, ...relations.keys},
  );
}

class CustomerRow {
  const CustomerRow({required this.id, this.orders});
  factory CustomerRow.fromRow(MssqlRow row) =>
      CustomerRow(id: (row['Id']! as num).toInt());
  final int id;
  final List<OrderRow>? orders;
  Map<String, Object?> toColumns() => <String, Object?>{'Id': id};
}

class LineRow {
  const LineRow({
    required this.id,
    required this.orderId,
    required this.productId,
    this.product,
  });
  factory LineRow.fromRow(MssqlRow row) => LineRow(
    id: (row['Id']! as num).toInt(),
    orderId: (row['OrderId']! as num).toInt(),
    productId: (row['ProductId']! as num).toInt(),
  );
  final int id;
  final int orderId;
  final int productId;
  final ProductRow? product;
  Map<String, Object?> toColumns() => <String, Object?>{
    'Id': id,
    'OrderId': orderId,
    'ProductId': productId,
  };
  LineRow withRelations(Map<String, Object?> relations) => LineRow(
    id: id,
    orderId: orderId,
    productId: productId,
    product: relations['product'] as ProductRow?,
  );
}

class ProductRow {
  const ProductRow({required this.id});
  factory ProductRow.fromRow(MssqlRow row) =>
      ProductRow(id: (row['Id']! as num).toInt());
  final int id;
  Map<String, Object?> toColumns() => <String, Object?>{'Id': id};
}

final products = MssqlTableBinding<ProductRow>(
  schema: 'dbo',
  table: 'Products',
  primaryKey: const <String>['Id'],
  columns: <MssqlBoundColumn>[
    MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
  ],
  fromRow: ProductRow.fromRow,
  toColumns: (r) => r.toColumns(),
  readColumn: (r, name) => r.toColumns()[name],
);

final lines = MssqlTableBinding<LineRow>(
  schema: 'dbo',
  table: 'Lines',
  primaryKey: const <String>['Id'],
  columns: <MssqlBoundColumn>[
    MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
    MssqlBoundColumn(name: 'OrderId', type: MssqlType.int32),
    MssqlBoundColumn(name: 'ProductId', type: MssqlType.int32),
  ],
  fromRow: LineRow.fromRow,
  toColumns: (r) => r.toColumns(),
  readColumn: (r, name) => r.toColumns()[name],
  applyRelations: (row, relations) => row.withRelations(relations),
);

final customers = MssqlTableBinding<CustomerRow>(
  schema: 'dbo',
  table: 'Customers',
  primaryKey: const <String>['Id'],
  columns: <MssqlBoundColumn>[
    MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
  ],
  fromRow: CustomerRow.fromRow,
  toColumns: (r) => r.toColumns(),
  readColumn: (r, name) => r.toColumns()[name],
);

final orders = MssqlTableBinding<OrderRow>(
  schema: 'dbo',
  table: 'Orders',
  primaryKey: const <String>['Id'],
  columns: <MssqlBoundColumn>[
    MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
    MssqlBoundColumn(name: 'CustomerId', type: MssqlType.int32, nullable: true),
  ],
  fromRow: OrderRow.fromRow,
  toColumns: (r) => r.toColumns(),
  readColumn: (r, name) => r.toColumns()[name],
  applyRelations: (row, relations) => row.withRelations(relations),
);

MssqlRelation<OrderRow, CustomerRow> get customerRelation =>
    MssqlRelation<OrderRow, CustomerRow>(
      name: 'customer',
      kind: MssqlRelationKind.belongsTo,
      targetBinding: customers,
      localColumns: const <String>['CustomerId'],
      foreignColumns: const <String>['Id'],
    );

MssqlRelation<OrderRow, LineRow> get lineRelation =>
    MssqlRelation<OrderRow, LineRow>(
      name: 'lines',
      kind: MssqlRelationKind.hasMany,
      targetBinding: lines,
      localColumns: const <String>['Id'],
      foreignColumns: const <String>['OrderId'],
    );

MssqlRelation<LineRow, ProductRow> get productRelation =>
    MssqlRelation<LineRow, ProductRow>(
      name: 'product',
      kind: MssqlRelationKind.belongsTo,
      targetBinding: products,
      localColumns: const <String>['ProductId'],
      foreignColumns: const <String>['Id'],
    );

MssqlRepository<OrderRow, int> repo(FakeExecutor fake) =>
    MssqlRepository<OrderRow, int>(
      fake,
      binding: orders,
      dialect: MssqlDialect.sql2012,
    );

List<Map<String, Object?>> orderRows(int count) => <Map<String, Object?>>[
  for (var i = 1; i <= count; i++)
    <String, Object?>{'Id': i, 'CustomerId': i % 3 + 1},
];

void main() {
  group('the query count', () {
    test(
      'fifty parents and two relations cost three queries, not a hundred',
      () async {
        final fake = FakeExecutor()
          ..replies.add(orderRows(50))
          ..replies.add(<Map<String, Object?>>[
            for (var i = 1; i <= 3; i++) <String, Object?>{'Id': i},
          ])
          ..replies.add(<Map<String, Object?>>[
            for (var i = 1; i <= 50; i++)
              <String, Object?>{'Id': i, 'OrderId': i, 'ProductId': 1},
          ]);

        final rows = await repo(fake).findAll(
          include: <MssqlRelation<OrderRow, Object?>>[
            customerRelation,
            lineRelation,
          ],
        );
        expect(rows, hasLength(50));
        expect(fake.calls, hasLength(3));
      },
    );

    test('and an observer sees those three from outside the package', () async {
      final fake = FakeExecutor()
        ..replies.add(orderRows(50))
        ..replies.add(<Map<String, Object?>>[
          for (var i = 1; i <= 3; i++) <String, Object?>{'Id': i},
        ])
        ..replies.add(<Map<String, Object?>>[
          for (var i = 1; i <= 50; i++)
            <String, Object?>{'Id': i, 'OrderId': i, 'ProductId': 1},
        ]);
      final log = MssqlQueryRecorder();
      await MssqlRepository<OrderRow, int>(
        fake.observedBy(log.record),
        binding: orders,
        dialect: MssqlDialect.sql2012,
      ).findAll(
        include: <MssqlRelation<OrderRow, Object?>>[
          customerRelation,
          lineRelation,
        ],
      );
      expect(log.count, 3);
      expect(log.events.map((e) => e.rows), <int>[50, 3, 50]);
      expect(log.describe(), contains('3 statement(s)'));
    });

    test('no include means no extra query at all', () async {
      final fake = FakeExecutor()..replies.add(orderRows(10));
      await repo(fake).findAll();
      expect(fake.calls, hasLength(1));
    });

    test('an empty parent set skips the relation queries', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      final rows = await repo(
        fake,
      ).findAll(include: <MssqlRelation<OrderRow, Object?>>[lineRelation]);
      expect(rows, isEmpty);
      expect(fake.calls, hasLength(1));
    });

    test('one level of nesting is one more query', () async {
      final fake = FakeExecutor()
        ..replies.add(orderRows(3))
        ..replies.add(<Map<String, Object?>>[
          for (var i = 1; i <= 3; i++)
            <String, Object?>{'Id': i, 'OrderId': i, 'ProductId': 7},
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 7},
        ]);

      final rows = await repo(fake).findAll(
        include: <MssqlRelation<OrderRow, Object?>>[
          lineRelation.then(productRelation),
        ],
      );
      expect(fake.calls, hasLength(3));
      expect(rows.first.lines!.single.product!.id, 7);
    });
  });

  group('the queries themselves', () {
    test('a single-column key becomes IN, with each key bound once', () async {
      final fake = FakeExecutor()
        ..replies.add(orderRows(3))
        ..replies.add(<Map<String, Object?>>[]);
      await repo(
        fake,
      ).findAll(include: <MssqlRelation<OrderRow, Object?>>[lineRelation]);
      expect(fake.calls.last.sql, contains('WHERE [OrderId] IN (@q'));
      expect(fake.calls.last.parameters, hasLength(3));
    });

    test('duplicate parent keys are asked for once', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1, 'CustomerId': 9},
          <String, Object?>{'Id': 2, 'CustomerId': 9},
          <String, Object?>{'Id': 3, 'CustomerId': 9},
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 9},
        ]);
      await repo(
        fake,
      ).findAll(include: <MssqlRelation<OrderRow, Object?>>[customerRelation]);
      expect(fake.calls.last.parameters, hasLength(1));
    });

    test('a null foreign key is left out of the IN list', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1, 'CustomerId': null},
          <String, Object?>{'Id': 2, 'CustomerId': 5},
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 5},
        ]);
      final rows = await repo(
        fake,
      ).findAll(include: <MssqlRelation<OrderRow, Object?>>[customerRelation]);
      expect(fake.calls.last.parameters, hasLength(1));
      expect(rows.first.customer, isNull);
      expect(rows.last.customer!.id, 5);
    });

    test('every parent key null means no relation query at all', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1, 'CustomerId': null},
        ]);
      await repo(
        fake,
      ).findAll(include: <MssqlRelation<OrderRow, Object?>>[customerRelation]);
      expect(fake.calls, hasLength(1));
    });

    test(
      'relation loads are idempotent, so a lost connection recovers',
      () async {
        final fake = FakeExecutor()
          ..replies.add(orderRows(2))
          ..replies.add(<Map<String, Object?>>[]);
        await repo(
          fake,
        ).findAll(include: <MssqlRelation<OrderRow, Object?>>[lineRelation]);
        expect(fake.calls.map((c) => c.idempotent), everyElement(isTrue));
      },
    );

    test('an ordering is applied to the relation query', () async {
      final fake = FakeExecutor()
        ..replies.add(orderRows(2))
        ..replies.add(<Map<String, Object?>>[]);
      await repo(fake).findAll(
        include: <MssqlRelation<OrderRow, Object?>>[
          lineRelation.ordered(<MssqlOrder>[Col('Id').desc()]),
        ],
      );
      expect(fake.calls.last.sql, endsWith('ORDER BY [Id] DESC'));
    });
  });

  group('batching', () {
    test('keys are split so the parameter ceiling is never reached', () {
      final keys = <MssqlRelationKey>[
        for (var i = 0; i < 5000; i++) MssqlRelationKey(<Object?>[i]),
      ];
      final batches = batchKeys(keys, 1);
      expect(batches, hasLength(3));
      for (final batch in batches) {
        expect(batch.length, lessThanOrEqualTo(relationParameterCeiling));
      }
      expect(batches.expand<MssqlRelationKey>((b) => b), hasLength(5000));
    });

    test('a composite key takes proportionally fewer per batch', () {
      final keys = <MssqlRelationKey>[
        for (var i = 0; i < 3000; i++) MssqlRelationKey(<Object?>[i, 'x']),
      ];
      final batches = batchKeys(keys, 2);
      for (final batch in batches) {
        expect(batch.length * 2, lessThanOrEqualTo(relationParameterCeiling));
      }
    });

    test(
      'a large relation load becomes several queries, not one failure',
      () async {
        final fake = FakeExecutor()..replies.add(orderRows(2500));
        for (var i = 0; i < 3; i++) {
          fake.replies.add(<Map<String, Object?>>[]);
        }
        await repo(
          fake,
        ).findAll(include: <MssqlRelation<OrderRow, Object?>>[lineRelation]);
        expect(fake.calls.length, greaterThan(2));
        for (final call in fake.calls.skip(1)) {
          expect(call.parameters.length, lessThanOrEqualTo(2000));
        }
      },
    );
  });

  group('composite keys', () {
    test('become OR-ed equality groups, not an IN list', () {
      final condition = relationPredicate(
        const <String>['TenantId', 'Code'],
        <MssqlRelationKey>[
          MssqlRelationKey(<Object?>[1, 'A']),
          MssqlRelationKey(<Object?>[2, 'B']),
        ],
      );
      final sql = MssqlQuery.from('T').where(condition).compile().sql;
      expect(
        sql,
        endsWith(
          'WHERE (([TenantId] = @q0 AND [Code] = @q1) OR '
          '([TenantId] = @q2 AND [Code] = @q3))',
        ),
      );
    });

    test('a single column still becomes IN', () {
      final condition = relationPredicate(
        const <String>['OrderId'],
        <MssqlRelationKey>[
          MssqlRelationKey(<Object?>[1]),
          MssqlRelationKey(<Object?>[2]),
        ],
      );
      final sql = MssqlQuery.from('T').where(condition).compile().sql;
      expect(sql, endsWith('WHERE [OrderId] IN (@q0, @q1)'));
    });
  });

  group('shapes', () {
    test('a to-many with no children is an empty list, not null', () async {
      final fake = FakeExecutor()
        ..replies.add(orderRows(1))
        ..replies.add(<Map<String, Object?>>[]);
      final rows = await repo(
        fake,
      ).findAll(include: <MssqlRelation<OrderRow, Object?>>[lineRelation]);
      expect(rows.single.lines, isEmpty);
      expect(rows.single.loaded, contains('lines'));
    });

    test('a to-one with no counterpart is null', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1, 'CustomerId': 99},
        ])
        ..replies.add(<Map<String, Object?>>[]);
      final rows = await repo(
        fake,
      ).findAll(include: <MssqlRelation<OrderRow, Object?>>[customerRelation]);
      expect(rows.single.customer, isNull);
      expect(rows.single.loaded, contains('customer'));
    });

    test('children are grouped against the right parent', () async {
      final fake = FakeExecutor()
        ..replies.add(orderRows(2))
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 10, 'OrderId': 1, 'ProductId': 1},
          <String, Object?>{'Id': 11, 'OrderId': 2, 'ProductId': 1},
          <String, Object?>{'Id': 12, 'OrderId': 1, 'ProductId': 1},
        ]);
      final rows = await repo(
        fake,
      ).findAll(include: <MssqlRelation<OrderRow, Object?>>[lineRelation]);
      expect(rows.first.lines!.map((l) => l.id), <int>[10, 12]);
      expect(rows.last.lines!.map((l) => l.id), <int>[11]);
    });
  });

  group('limits', () {
    test('maxLoadedRows is a ceiling on the whole load, and says so', () async {
      final fake = FakeExecutor()
        ..replies.add(orderRows(2))
        ..replies.add(<Map<String, Object?>>[
          for (var i = 1; i <= 10; i++)
            <String, Object?>{'Id': i, 'OrderId': 1, 'ProductId': 1},
        ]);
      final repository = repo(fake);
      await repository.findAll(
        include: <MssqlRelation<OrderRow, Object?>>[
          lineRelation.maxLoadedRows(4),
        ],
      );
      expect(repository.warnings, isNotEmpty);
      expect(repository.warnings.first, contains('maxLoadedRows(4)'));
    });

    test('takePerParent is a limit the server applies', () async {
      final fake = FakeExecutor()
        ..replies.add(orderRows(2))
        ..replies.add(<Map<String, Object?>>[
          for (var i = 1; i <= 4; i++)
            <String, Object?>{'Id': i, 'OrderId': 1, 'ProductId': 1},
        ]);
      await repo(fake).findAll(
        include: <MssqlRelation<OrderRow, Object?>>[
          lineRelation.takePerParent(4),
        ],
      );
      final child = fake.calls.last.sql;
      expect(child, contains('ROW_NUMBER() OVER (PARTITION BY'));
      expect(child, contains('[__mssql_rn] <= @'));
      expect(child, startsWith('SELECT [Id], [OrderId], [ProductId] FROM ('));
    });
  });

  group('refusals', () {
    test('include on a table with no generated relations says so', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1},
        ]);
      final noRelations = MssqlRepository<CustomerRow, int>(
        fake,
        binding: customers,
        dialect: MssqlDialect.sql2012,
      );
      await expectLater(
        noRelations.findAll(
          include: <MssqlRelation<CustomerRow, Object?>>[
            MssqlRelation<CustomerRow, OrderRow>(
              name: 'orders',
              kind: MssqlRelationKind.hasMany,
              targetBinding: orders,
              localColumns: const <String>['Id'],
              foreignColumns: const <String>['CustomerId'],
            ),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no generated relations'),
          ),
        ),
      );
    });

    test('mismatched column counts are refused at construction', () {
      expect(
        () => MssqlRelation<OrderRow, LineRow>(
          name: 'bad',
          kind: MssqlRelationKind.hasMany,
          targetBinding: lines,
          localColumns: const <String>['Id'],
          foreignColumns: const <String>['OrderId', 'Extra'],
        ),
        throwsArgumentError,
      );
      expect(
        () => MssqlRelation<OrderRow, LineRow>(
          name: 'bad',
          kind: MssqlRelationKind.hasMany,
          targetBinding: lines,
          localColumns: const <String>[],
          foreignColumns: const <String>[],
        ),
        throwsArgumentError,
      );
    });
  });

  group('the relation key', () {
    test('compares by value, so it can group a composite key', () {
      expect(
        MssqlRelationKey(<Object?>[1, 'A']),
        MssqlRelationKey(<Object?>[1, 'A']),
      );
      expect(
        MssqlRelationKey(<Object?>[1, 'A']).hashCode,
        MssqlRelationKey(<Object?>[1, 'A']).hashCode,
      );
      expect(
        MssqlRelationKey(<Object?>[1, 'A']),
        isNot(MssqlRelationKey(<Object?>[1, 'B'])),
      );
      expect(
        MssqlRelationKey(<Object?>[1]),
        isNot(MssqlRelationKey(<Object?>[1, 'A'])),
      );
    });

    test('knows when it carries a null', () {
      expect(MssqlRelationKey(<Object?>[1, null]).hasNull, isTrue);
      expect(MssqlRelationKey(<Object?>[1, 2]).hasNull, isFalse);
    });
  });
}

