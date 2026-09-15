// ignore_for_file: avoid_print
//
// Five worked examples against the generated sales schema.
//
//   dart run example/advanced_examples.dart
//
// RecordingSession only renders SQL. Printed text is what this package
// builds, not proof that SQL Server accepted it or returned these rows.
// These examples are not a test suite.
library;

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';

import 'db/extensions/orders_scopes.dart';
import 'db/generated/database.g.dart';
import 'db/generated/generated.dart';
import 'db/recording_session.dart';

Future<void> main() async {
  exampleTypeChain();
  await example1SearchScreen();
  await example2OrderDetailWithoutNPlusOne();
  await example3RevenueReport();
  await example4CategoryTreeAndMonthlyTrend();
  await example5WriteFlowInOneTransaction();
  await example5GraphInsertAlternative();
}

/// Type chain: where → open → whereStatus, OrderRow field access,
/// typed projection. Analyzer-visible without talking to a server.
void exampleTypeChain() {
  final db = AppDatabase(RecordingSession());
  final selected = db.orders
      .where((o) => o.customerId.eq(1))
      .open()
      .whereStatus('open')
      .orderBy((o) => [o.placedAt.desc(), o.id.desc()]);
  print(loadOpenOrders);
  print(selected.runtimeType);
  print(OrderListItem.projection.name);
  print(selectPair);
  print(readOrderCode);
}

MssqlProjectedQuery<(int, String)> selectPair(OrderQuery query) =>
    query.select2<int, String>((o) => (o.id, o.code));

Future<List<OrderRow>> loadOpenOrders(OrderQuery query) => query.get();

String readOrderCode(OrderRow order) => order.code;

AppDatabase _db(MssqlSession session) => AppDatabase(session);

// ===========================================================================
// 1. Search screen — optional filters, projection, stable page
// ===========================================================================

Future<void> example1SearchScreen() async {
  _title('1. Search screen: optional filters, OrderListItem, one page');

  const String? search = null;
  const filledSearch = 'ACME';
  final placedFrom = DateTime.utc(2026, 1, 1);
  const statuses = <String>['open', 'shipped'];
  const MssqlDecimal? minTotal = null;
  final placedFromValue = MssqlDateTimeValue.fromDateTime(placedFrom);

  MssqlQuery searchJoin({required bool inner, String? term}) {
    // INNER JOIN drops orders whose customer row is missing.
    // LEFT JOIN keeps those orders and leaves customer columns NULL.
    // The two are not interchangeable; the row set changes.
    var q = MssqlQuery.from('dbo.Orders', as: 'o');
    q = inner
        ? q.innerJoin(
            'dbo.Customers',
            as: 'c',
            on: Col('o.CustomerId').eqCol('c.Id'),
          )
        : q.leftJoin(
            'dbo.Customers',
            as: 'c',
            on: Col('o.CustomerId').eqCol('c.Id'),
          );
    return q
        .where(Col('o.DeletedAt').isNull())
        .when(
          term != null && term.trim().isNotEmpty,
          (q) => q.where(
            Order.code.contains(term!) |
                Customer.name.contains(term) |
                Customer.city.contains(term),
          ),
        )
        .whenNotNull(
          placedFromValue,
          (q, from) => q.where(Order.placedAt.gte(from)),
        )
        .when(
          statuses.isNotEmpty,
          (q) => q.where(Order.status.inList(statuses)),
        )
        .whenNotNull(minTotal, (q, min) => q.where(Order.total.gte(min)));
  }

  final innerBase = searchJoin(inner: true, term: filledSearch);
  final emptySearch = searchJoin(inner: true, term: search);
  final page = innerBase
      .select(<MssqlExpression>[
        Order.id,
        Order.code,
        Order.total,
        Customer.name.as('Customer'),
      ])
      .orderBy(<MssqlOrder>[Order.placedAt.desc(), Order.id.desc()])
      .paged(offset: 0, rows: 25);
  _sql('page (INNER JOIN customers)', page.compile());
  _sql(
    'same filters, LEFT JOIN',
    searchJoin(inner: false, term: filledSearch).countRows().compile(),
  );
  _sql('empty search adds no LIKE', emptySearch.countRows().compile());
  _sql('count (INNER JOIN)', innerBase.countRows().compile());

  final session = RecordingSession()
    ..replies.add(<Map<String, Object?>>[])
    ..replies.add(<Map<String, Object?>>[
      <String, Object?>{'': 0},
    ]);
  final db = _db(session);
  await db.orders
      .search(filledSearch, (o) => [o.code])
      .whereIfNotNull(placedFromValue, (o, from) => o.placedAt.gte(from))
      .whereInIfNotEmpty(statuses, (o, list) => o.status.inList(list))
      .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
      .select(OrderListItem.projection)
      .page(size: 25, offset: 0, total: true);
  _ran(session);
}

// ===========================================================================
// 2. Relations — batch/depth cost, not "always four queries"
// ===========================================================================

Future<void> example2OrderDetailWithoutNPlusOne() async {
  _title('2. Eager loading: customer + lines + product + category');

  final session = RecordingSession()
    ..replies.add(<Map<String, Object?>>[
      for (var i = 1; i <= 3; i++) _orderRow(i),
    ])
    ..replies.add(<Map<String, Object?>>[
      for (var i = 1; i <= 3; i++) _customerRow(i),
    ])
    ..replies.add(<Map<String, Object?>>[
      for (var i = 1; i <= 3; i++) _lineRow(i, orderId: i),
    ])
    ..replies.add(<Map<String, Object?>>[
      for (var i = 1; i <= 3; i++) _productRow(i),
    ])
    ..replies.add(<Map<String, Object?>>[
      for (var i = 1; i <= 3; i++) _categoryRow(i),
    ]);

  final recorder = MssqlQueryRecorder();
  final db = _db(session.observedBy(recorder.record));

  // Parent page, then one batched IN-query per include depth unless a
  // to-one is `.joined()`. takePerParent adds ROW_NUMBER. The statement
  // count grows with include depth and through-relations, not with page
  // size, and it is not "4 at every size".
  final page = await db.orders
      .where((o) => o.status.ne('draft'))
      .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
      .include(
        (o) => [
          o.customer.asInclude,
          o.lines
              .ordered(<MssqlOrder>[OrderLine.id.asc()])
              .takePerParent(20)
              .then(OrderLineRel.product.then(ProductRel.category))
              .asInclude,
        ],
      )
      .page(size: 50, offset: 0);

  final first = page.rows.first;
  print('  rows: ${page.rows.length}, hasMore: ${page.hasMore}');
  print('  customer: ${first.customer?.name}');
  print(
    '  lines: ${first.lines.length}, '
    'first product: ${first.lines.first.product?.name}',
  );
  print('  isLoaded("lines"): ${first.isLoaded('lines')}');
  print('');
  print('  ${recorder.describe().trimRight().replaceAll('\n', '\n  ')}');
  print('');
  _ran(session);
}

// ===========================================================================
// 3. Revenue — COUNT DISTINCT orders, SUM lines, named averages
// ===========================================================================

Future<void> example3RevenueReport() async {
  _title('3. Report: distinct orders, line revenue, same date/delete scope');

  final from = DateTime.utc(2026, 1, 1);
  final to = DateTime.utc(2027, 1, 1);

  // Last order in the *same* window as the report, not all-time. An
  // all-time MAX(PlacedAt) while the outer query filters 2026 is a
  // different question and would mix scopes.
  final lastOrderAt = scalarSubquery(
    MssqlQuery.from('dbo.Orders', as: 'lo')
        .select(<MssqlExpression>[max(Col('lo.PlacedAt'))])
        .where(Col('lo.CustomerId').eqCol('c.Id'))
        .where(Col('lo.DeletedAt').isNull())
        .where(Col('lo.Status').ne('cancelled'))
        .where(Col('lo.PlacedAt').gte(from))
        .where(Col('lo.PlacedAt').lt(to)),
  );

  final hasCancellation = MssqlQuery.from('dbo.Orders', as: 'x')
      .select(<MssqlExpression>[raw('1')])
      .where(Col('x.CustomerId').eqCol('c.Id'))
      .where(Col('x.Status').eq('cancelled'))
      .where(Col('x.DeletedAt').isNull())
      .where(Col('x.PlacedAt').gte(from))
      .where(Col('x.PlacedAt').lt(to));

  final report = MssqlQuery.from('dbo.Customers', as: 'c')
      .innerJoin('dbo.Orders', as: 'o', on: Col('o.CustomerId').eqCol('c.Id'))
      .innerJoin('dbo.OrderLines', as: 'l', on: Col('l.OrderId').eqCol('o.Id'))
      .where(Col('c.DeletedAt').isNull())
      .where(Col('o.DeletedAt').isNull())
      .where(Col('o.Status').ne('cancelled'))
      .where(Col('o.PlacedAt').gte(from))
      .where(Col('o.PlacedAt').lt(to))
      .whereNotExists(hasCancellation)
      .groupBy(<MssqlExpression>[Col('c.Id'), Col('c.Name'), Col('c.City')])
      .havingCondition(sum(Col('l.LineTotal')).gt(MssqlDecimal.parse('10000')))
      .select(<MssqlExpression>[
        Col('c.Id'),
        Col('c.Name'),
        Col('c.City'),
        count(Col('o.Id'), distinct: true).as('OrderCount'),
        sum(Col('l.LineTotal')).as('Revenue'),
        // Unweighted mean of line UnitPrice rows. Not quantity-weighted:
        // quantity-weighted is SUM(LineTotal) / SUM(Quantity).
        avg(Col('l.UnitPrice')).as('AvgUnitPriceUnweighted'),
        lastOrderAt.as('LastOrderAt'),
        raw('DATEDIFF(day, MIN(o.PlacedAt), MAX(o.PlacedAt))').as('SpanDays'),
      ])
      .orderBy(<MssqlOrder>[Col('Revenue').desc()]);

  _sql('top 20', report.top(20).compile());
  _sql(
    'page 3, on a 2008-compatible database',
    report.paged(offset: 40, rows: 20).compile(dialect: MssqlDialect.sql2008),
  );
}

// ===========================================================================
// 4. Category tree — typed CTE + typed SQL report + DATE_BUCKET gate
// ===========================================================================

Future<void> example4CategoryTreeAndMonthlyTrend() async {
  _title('4. Typed recursive CTE, date-bucket capability, db.reports');

  const rootCategoryId = 7;
  final since = DateTime.utc(2025, 1, 1);

  // Depth is a filter (maxDepth / Depth column). MAXRECURSION is the
  // server's runaway guard and fails the query. Cycle policy error lets
  // SQL Server raise 530; skipVisited would carry the path instead.
  final tree = MssqlTypedCte.recursive(
    name: 'tree',
    fields: <MssqlCteField>[
      MssqlCteField(
        'Id',
        const MssqlColumnType(type: MssqlType.int32, nullable: false),
      ),
      MssqlCteField(
        'ParentId',
        const MssqlColumnType(type: MssqlType.int32, nullable: true),
      ),
      MssqlCteField(
        'Name',
        const MssqlColumnType(
          type: MssqlType.nvarchar,
          size: 200,
          nullable: false,
        ),
      ),
      MssqlCteField(
        'Depth',
        const MssqlColumnType(type: MssqlType.int32, nullable: false),
      ),
    ],
    maxRecursion: 20,
    anchor: MssqlQuery.from('dbo.Categories')
        .select(<MssqlExpression>[
          Category.id,
          Category.parentId,
          Category.name,
          const MssqlLiteral(0),
        ])
        .where(Category.id.eq(rootCategoryId)),
    recursiveMember: MssqlQuery.from('dbo.Categories', as: 'c')
        .innerJoin('tree', on: Col('tree.Id').eqCol('c.ParentId'))
        .select(<MssqlExpression>[
          Col('c.Id'),
          Col('c.ParentId'),
          Col('c.Name'),
          MssqlArithmetic(Col('tree.Depth'), MssqlArithmeticOperator.add, 1),
        ]),
  );

  _sql(
    'subtree (typed CTE, cycle=error via MAXRECURSION)',
    tree.read().where(tree.column('Depth').lte(4)).orderBy(<MssqlOrder>[
      tree.column('Depth').asc(),
      tree.column('Name').asc(),
    ]).compile(),
  );

  // The runtime hierarchy, hand-built: the walk on its own, as the
  // outermost query. `CategoryQuery.hierarchy` is the same thing derived
  // from the schema, so nothing here has to name a column twice.
  _sql(
    'same walk as descendantsOf (maxDepth 4, cycles error)',
    CategoryQuery.hierarchy
        .descendantsOf(
          rootCategoryId,
          maxDepth: 4,
          cycles: MssqlCycleHandling.error,
          maxRecursion: 20,
        )
        .compile(),
  );

  // The generated filter: `dbo.Categories` has exactly one self-referencing
  // foreign key (`ParentId`), so `descendantsOf` is emitted on the table
  // query. It returns a CategoryQuery, so the ordinary chain continues —
  // ordering, paging, includes and this query's scopes all still apply, and
  // the recursive expression rides on the statement's own WITH clause
  // because SQL Server allows one only at the start of a statement.
  _sql(
    'generated db.categories.descendantsOf(...) — still a CategoryQuery',
    _db(RecordingSession()).categories
        .descendantsOf(rootCategoryId, maxDepth: 4, includeRoot: false)
        .whereName('Tools')
        .orderByNamed('name')
        .compile(),
  );

  // DATE_BUCKET needs SQL Server 2022 / compat 160. monthStart() is the
  // DATEADD/DATEDIFF form that runs on every version this package supports.
  final monthStart = Order.placedAt.monthStart();
  try {
    MssqlQuery.from('dbo.Orders', as: 'o')
        .select(<MssqlExpression>[
          Order.placedAt.dateBucket(unit: MssqlDateBucketUnit.month, width: 1),
        ])
        .compile(dialect: MssqlDialect.sql2012);
  } on MssqlCapabilityException catch (error) {
    print('  dateBucket on 2012: ${error.message}');
  }
  _sql(
    'monthStart (no version gate)',
    MssqlQuery.from(
      'dbo.Orders',
      as: 'o',
    ).select(<MssqlExpression>[monthStart.as('Month')]).compile(),
  );
  _sql(
    'DATE_BUCKET on 2022',
    MssqlQuery.from('dbo.Orders', as: 'o')
        .select(<MssqlExpression>[
          Order.placedAt
              .dateBucket(unit: MssqlDateBucketUnit.month, width: 1)
              .as('Month'),
        ])
        .compile(dialect: MssqlDialect.forVersion(majorVersion: 16)),
  );

  final session = RecordingSession()
    ..replies.add(<Map<String, Object?>>[
      <String, Object?>{
        'Month': DateTime.utc(2026, 1, 1),
        'Category': 'Root',
        'Revenue': MssqlDecimal.parse('10.00'),
        'Lines': 1,
      },
    ]);
  final db = _db(session);
  // One `since` parameter, same window as the Dart builder above.
  final rows = await db.reports.categoryTrend(
    rootId: rootCategoryId,
    since: since,
  );
  print('  reports.categoryTrend -> ${rows.length} row(s)');
  _ran(session);
}

// ===========================================================================
// 5. Writes — getOrCreate, Create, grouped stock, guarded status, archive
// ===========================================================================

Future<void> example5WriteFlowInOneTransaction() async {
  _title('5. Writes: getOrCreate, create, grouped decrement, archive');

  final session = RecordingSession(inTransaction: true)
    ..replies.add(<Map<String, Object?>>[_customerRow(42)])
    ..replies.add(<Map<String, Object?>>[_orderRow(1001, customerId: 42)])
    ..replies.add(<Map<String, Object?>>[
      _lineRow(1, orderId: 1001),
      _lineRow(2, orderId: 1001),
    ]);
  session.affected.addAll(<int>[2, 1, 1]);

  final db = _db(session);
  await db.transaction((tx) async {
    final customer = await tx.customers.getOrCreateByCode(
      'ACME',
      name: 'ACME Ltd',
      city: 'İstanbul',
      isActive: true,
    );

    final order = await tx.orders.create(
      OrderRowBaseCreate(
        customerId: customer.id,
        code: 'SO-2026-1001',
        status: 'open',
        total: MssqlDecimal.parse('1499.90'),
        placedAt: MssqlDateTimeValue.fromDateTime(DateTime.utc(2026, 9, 8)),
      ),
    );

    await tx.orderLines.createMany(<OrderLineRowBaseCreate>[
      OrderLineRowBaseCreate(
        orderId: order.id,
        productId: 11,
        quantity: 2,
        unitPrice: MssqlDecimal.parse('499.95'),
        lineTotal: MssqlDecimal.parse('999.90'),
      ),
      OrderLineRowBaseCreate(
        orderId: order.id,
        productId: 12,
        quantity: 1,
        unitPrice: MssqlDecimal.parse('500.00'),
        lineTotal: MssqlDecimal.parse('500.00'),
      ),
    ]);

    // Same product twice is one UPDATE: amounts are grouped by key.
    await tx.products.decrementQuantities(
      keyColumn: 'Id',
      quantityColumn: 'Stock',
      requests: <({Object key, num amount})>[
        (key: 11, amount: 2),
        (key: 12, amount: 1),
      ],
    );

    final closed = await tx.orders
        .whereId(order.id)
        .whereStatus('open')
        .update(
          const OrderRowBasePatch(status: Field.value('closed')),
          expectAffected: 1,
        );
    print('  rows closed: $closed');
  });

  final archive = MssqlInsert.into('dbo.OrdersArchive').using(
    <String>['Id', 'CustomerId', 'Code', 'Total', 'PlacedAt'],
    MssqlQuery.from('dbo.Orders')
        .select(<MssqlExpression>[
          Order.id,
          Order.customerId,
          Order.code,
          Order.total,
          Order.placedAt,
        ])
        .where(Order.status.eq('closed'))
        .where(
          Order.placedAt.lt(
            MssqlDateTimeValue.fromDateTime(DateTime.utc(2025, 1, 1)),
          ),
        ),
  );
  await archive.run(session);
  _ran(session);

  try {
    MssqlUpdate.table(
      'dbo.Orders',
    ).set(<String, Object?>{'Status': 'void'}).compile();
  } on StateError catch (error) {
    print('  refused: ${error.message}');
  }
  try {
    MssqlQuery.from('dbo.Orders').paged(offset: 0, rows: 10).compile();
  } on StateError catch (error) {
    print('  refused: ${error.message}');
  }
  try {
    Order.status.inList(const <String>[]);
  } on ArgumentError catch (error) {
    print('  refused: ${error.message}');
  }
}

/// Graph insert is a different function so this example does not write
/// the same order twice.
Future<void> example5GraphInsertAlternative() async {
  _title('5b. Explicit graph insert (alternative, not combined with 5)');

  final session = RecordingSession(inTransaction: true)
    ..replies.add(<Map<String, Object?>>[_orderRow(2001, customerId: 42)])
    ..replies.add(<Map<String, Object?>>[
      _lineRow(21, orderId: 2001),
      _lineRow(22, orderId: 2001),
    ]);
  final db = _db(session);
  await db.orders.createGraph(
    OrderRowBaseCreate(
      customerId: 42,
      code: 'SO-2026-2001',
      status: 'open',
      total: MssqlDecimal.parse('100.00'),
      placedAt: MssqlDateTimeValue.fromDateTime(DateTime.utc(2026, 9, 8)),
    ),
    lines: <OrderLineRowBaseCreate>[
      OrderLineRowBaseCreate(
        orderId: 0,
        productId: 11,
        quantity: 1,
        unitPrice: MssqlDecimal.parse('50.00'),
        lineTotal: MssqlDecimal.parse('50.00'),
      ),
      OrderLineRowBaseCreate(
        orderId: 0,
        productId: 12,
        quantity: 1,
        unitPrice: MssqlDecimal.parse('50.00'),
        lineTotal: MssqlDecimal.parse('50.00'),
      ),
    ],
  );
  _ran(session);
}

void _title(String text) {
  print('');
  print('=' * 76);
  print(text);
  print('=' * 76);
}

void _sql(String label, MssqlStatement statement) {
  print('');
  print('-- $label');
  print(statement.sql);
  if (statement.parameters.isNotEmpty) {
    print('-- parameters: ${statement.parameters}');
  }
}

void _ran(RecordingSession session) {
  print('  ${session.statements.length} statement(s) rendered:');
  for (final sql in session.statements) {
    print('    $sql');
  }
  session.statements.clear();
}

Map<String, Object?> _orderRow(int id, {int customerId = 1}) =>
    <String, Object?>{
      'Id': id,
      'CustomerId': customerId,
      'Code': 'SO-$id',
      'Status': 'open',
      'Total': MssqlDecimal.parse('${100 * id}.00'),
      'PlacedAt': MssqlDateTimeValue.fromDateTime(DateTime.utc(2026, 9, 8)),
      'CreatedAt': MssqlDateTimeValue.fromDateTime(DateTime.utc(2026, 9, 8)),
      'UpdatedAt': null,
      'DeletedAt': null,
    };

Map<String, Object?> _customerRow(int id) => <String, Object?>{
  'Id': id,
  'Code': 'C-$id',
  'Name': 'Customer $id',
  'City': 'İstanbul',
  'IsActive': true,
  'CreatedAt': MssqlDateTimeValue.fromDateTime(DateTime.utc(2026, 1, 1)),
  'UpdatedAt': null,
  'DeletedAt': null,
};

Map<String, Object?> _lineRow(int id, {required int orderId}) =>
    <String, Object?>{
      'Id': id,
      'OrderId': orderId,
      'ProductId': id,
      'Quantity': 2,
      'UnitPrice': MssqlDecimal.parse('49.90'),
      'LineTotal': MssqlDecimal.parse('99.80'),
    };

Map<String, Object?> _productRow(int id) => <String, Object?>{
  'Id': id,
  'CategoryId': 7,
  'Sku': 'SKU-$id',
  'Name': 'Product $id',
  'Price': MssqlDecimal.parse('49.90'),
  'Stock': 100,
};

Map<String, Object?> _categoryRow(int id) => <String, Object?>{
  'Id': id,
  'ParentId': id == 7 ? null : 7,
  'Name': 'Category $id',
};
