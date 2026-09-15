# Examples — the query builder

`import 'package:mssql_orm/query.dart';`

The query builder is for SQL whose **shape** depends on runtime values: a
`WHERE` that grows with whichever filters the user filled in, a sort the user
picked, a page whose SQL differs on SQL Server 2008. It needs no code
generation and no schema — it works against any table you can name.

If you want a one-off literal SQL string, the driver's `session.queryRows` is
the right place. If you want typed rows, relations and generated column
methods, that is the [ORM cookbook](EXAMPLES_ORM.md).

| Level | What it covers | Read it when |
|---|---|---|
| [0 · The one idea](#level-0--the-one-idea) | compile ≠ execute | before anything else |
| [1 · Simple](#level-1--simple) | select, where, order, page, count | first query |
| [2 · Everyday](#level-2--everyday) | optional filters, joins, text search, dates, groups | a real search screen |
| [3 · Advanced](#level-3--advanced) | subqueries, CTEs, windows, unions, INSERT/UPDATE/DELETE/upsert, dialects | a report |
| [4 · Hard](#level-4--hard) | recursive walks, keyset chunking, raw fragments, parameter allocation, refusals | the edges |

---

## Level 0 · The one idea

**Compilation is separate from execution.** `compile()` returns an
`MssqlStatement` — SQL text **and** the values to bind.

```dart
import 'package:mssql_orm/query.dart';

final statement = MssqlQuery.from('dbo.Orders', as: 'o')
    .where(Col('o.IsOpen').eq(true))
    .select([Col('o.Id'), Col('o.Code')])
    .orderBy([Col('o.Id').desc()])
    .paged(offset: 0, rows: 50)
    .compile();

print(statement.sql);         // SELECT o.[Id], o.[Code] FROM … OFFSET … FETCH …
print(statement.parameters);  // {q0: true, q1: 0, q2: 50}

final rows = await session.queryRows(
  statement.sql,
  parameters: statement.parameters,   // ← both halves, always
);
```

Passing only `.compile().sql` drops the parameter map. That is a bug, not a
shortcut: the statement still has `@q0` in it and the server will refuse it.

Two shorter ways to run one, so you rarely hold a statement yourself:

```dart
// a) The execution extensions — they compile and run in one step.
final rows  = await query.get(session);        // List<MssqlRow>
final one   = await query.first(session);      // MssqlRow?
final total = await query.count(session);      // int, result-row count
final items = await query.getAs(session, OrderRowBase.fromRow); // with an ORM generation

// b) Through an ORM AppDatabase, if you have one — same observer,
//    same transaction, and the dialect resolved from the real server.
final rows2 = await db.query(query);
final n     = await db.execute(insertStatement);
```

A query is **immutable**. Every method returns a new query, so a base query is
safe to share, store in a field, and branch from:

```dart
final base = MssqlQuery.from('dbo.Orders').where(Col('DeletedAt').isNull());
final open   = base.where(Col('Status').eq('open'));     // base is unchanged
final closed = base.where(Col('Status').eq('closed'));
```

---

## Level 1 · Simple

### 1.1 Select, filter, order

```dart
final q = MssqlQuery.from('dbo.Products')
    .select([Col('Id'), Col('Name'), Col('Price')])
    .where(Col('IsActive').eq(true))
    .orderBy([Col('Name').asc()]);

final rows = await q.get(session);
for (final row in rows) {
  print('${row.require<int>('Id')}  ${row.require<String>('Name')}');
}
```

Omitting `select` gives `SELECT *`. `Col('o.Name')` is a column reference;
the dot is understood and each part is quoted, so a column called `Order` or
`Group` is safe.

### 1.2 The comparison vocabulary

```dart
Col('Price').eq(100)         Col('Price').ne(100)
Col('Price').lt(100)         Col('Price').lte(100)
Col('Price').gt(100)         Col('Price').gte(100)
Col('Note').isNull()         Col('Note').isNotNull()
Col('Status').inList(['open', 'shipped'])
Col('Status').notInList(['void'])
Col('Price').between(10, 100)          // inclusive
Col('Price').notBetween(10, 100)
Col('o.CustomerId').eqCol('c.Id')      // column to column
```

Two deliberate refusals, both `ArgumentError` at build time:

```dart
Col('Note').eq(null);        // ✗ SQL `= NULL` is never true. Write isNull().
Col('Status').inList([]);    // ✗ An empty IN list is a question, not `1 = 0`.
```

If an empty list is a legitimate state in your code, decide what it means
before you build the query:

```dart
final q = statuses.isEmpty
    ? base                                       // no filter
    : base.where(Col('Status').inList(statuses)); // or return nothing — say which
```

Generated typed columns make that decision explicit instead of leaving it in
an `if`:

```dart
o.Status.inList([], onEmpty: MssqlEmptyIn.error);        // default: ArgumentError
o.Status.inList([], onEmpty: MssqlEmptyIn.matchNone);    // compiles to 1 = 0
o.Status.inList([], onEmpty: MssqlEmptyIn.omit);         // clause is dropped
o.Status.notInList([], onEmpty: MssqlEmptyIn.matchNone); // 1 = 1, nothing excluded
```

### 1.3 Combining conditions

Chained `.where()` calls are `AND`. For anything else, say so:

```dart
q.where(Col('Status').eq('open'))
 .where(Col('Total').gte(100));                 // AND

q.where(Col('Status').eq('open') | Col('Status').eq('shipped'));   // OR
q.where(Col('IsActive').eq(true) & Col('DeletedAt').isNull());     // explicit AND
q.where(not(Col('Status').eq('void')));                            // NOT

q.where(or([                                    // n-ary forms
  Col('Status').eq('open'),
  Col('Status').eq('shipped'),
  Col('Status').eq('partial'),
]));
q.where(and([...]));
```

`|` binds looser than `&` in Dart, same as in SQL, but parenthesise anyway
when a reader would have to think about it.

### 1.4 Paging

```dart
final page = q
    .orderBy([Col('PlacedAt').desc(), Col('Id').desc()])   // required
    .paged(offset: 40, rows: 20);
```

`paged` without an `orderBy` throws a `StateError`. That is not pedantry:
`OFFSET … FETCH` with no order returns whatever the plan happened to produce,
so page 2 can repeat a row from page 1 and omit another forever.

`orderBy` should end in something unique — a primary key — so ties do not
shuffle between pages. `top(n)` is the different thing: `SELECT TOP (n)`, no
offset and no order required.

### 1.5 Counting

```dart
final total = await q.count(session);              // result rows
```

Under the hood this is `countRows()`, which counts **result rows** rather than
swapping the projection for `COUNT(*)`:

```dart
final stmt = q.countRows().compile();
```

Why it matters: on a `DISTINCT` or `GROUP BY` query, `COUNT(*)` counts the
rows *before* grouping. `countRows()` counts through a derived table, so the
number is the number of rows your query actually returns. The related
questions have their own methods:

```dart
q.countDistinct([Col('o.Id')])                      // distinct keys
await q.countDistinctColumns(session, ['Id'])       // …and run it
q.aggregateRows(sum(Col('l.LineTotal')))            // one aggregate, no grouping
```

The classic mistake: a query joined to a child table returns one row per
child, so `count()` counts *lines*, not orders. `countDistinct([Col('o.Id')])`
is the other question.

### 1.6 One value in one round trip

The builder runs a query and returns just what its name says — no compile,
no row mapping by hand:

```dart
final exists = await q.exists(session);                          // TOP (1) 1
final code   = await q.value<String>(session, 'Code');           // first row's Code
final codes  = await q.pluck<String>(session, 'Code');           // every row's Code
final total  = await q.sum<MssqlDecimal>(session, 'LineTotal');  // exact — never double
final newest = await q.max<int>(session, 'Id');
```

`value`, `pluck`, `sum`, `avg`, `min` and `max` return `null` when nothing
matched. Ask for the type that matches the column: `MssqlDecimal` for an
exact `decimal`/`money` column, `int` or `double` for the others. SQL Server's
`AVG` of an integer column is integer division — cast the column, or use the
typed builder's `avg(integers: …)`, when the fraction matters.

---

## Level 2 · Everyday

### 2.1 Optional filters — the reason this package exists

```dart
Future<List<MssqlRow>> search(
  MssqlSession session, {
  String? term,
  DateTime? since,
  List<String> statuses = const [],
  MssqlDecimal? minTotal,
}) {
  final q = MssqlQuery.from('dbo.Orders', as: 'o')
      .where(Col('o.DeletedAt').isNull())
      // `when`: add the clause only if the test holds.
      .when(
        term != null && term.trim().isNotEmpty,
        (q) => q.where(whereAny(
          ['o.Code', 'o.Note'],
          (column) => column.contains(term!.trim()),
        )),
      )
      // `whenNotNull`: the value arrives non-null in the callback.
      .whenNotNull(since, (q, from) => q.where(Col('o.PlacedAt').gte(from)))
      .when(statuses.isNotEmpty,
          (q) => q.where(Col('o.Status').inList(statuses)))
      .whenNotNull(minTotal, (q, min) => q.where(Col('o.Total').gte(min)))
      .orderBy([Col('o.PlacedAt').desc(), Col('o.Id').desc()]);

  return q.paged(offset: 0, rows: 25).get(session);
}
```

`unless(test, build)` is `when(!test, build)`. Nothing is appended when a
filter is absent, so the SQL an empty form produces has no dead `AND 1 = 1` in
it and the plan cache is not polluted with one variant per filter combination
that happens to bind different literals.

### 2.2 The column-group helpers

```dart
whereAny(['o.Code', 'c.Name', 'c.City'], (c) => c.contains(term))  // OR
whereAll(['a.Flag', 'b.Flag'], (c) => c.eq(true))                  // AND
whereNone(['o.Note', 'o.Comment'], (c) => c.contains('spam'))      // NOR
whereColumn('o.Total', MssqlOperator.gte, 'o.PaidTotal')           // col vs col
```

`whereAll` here is "AND across these **columns**", not "every row". Name the
variable `columns` in your head and it reads correctly.

### 2.3 Joins

```dart
final q = MssqlQuery.from('dbo.Orders', as: 'o')
    .innerJoin('dbo.Customers', as: 'c', on: Col('o.CustomerId').eqCol('c.Id'))
    .leftJoin('dbo.Invoices',  as: 'i', on: Col('i.OrderId').eqCol('o.Id'))
    .select([
      Col('o.Id'),
      Col('o.Code'),
      Col('c.Name').as('Customer'),
      Col('i.Number').as('InvoiceNumber'),   // NULL when there is no invoice
    ]);
```

`innerJoin`, `leftJoin`, `rightJoin`, `fullJoin`, `crossJoin`, plus the
explicit `join(MssqlJoinKind.inner, …)` and `joinSub(...)` for a derived
table.

**They are not interchangeable.** An inner join to `Customers` silently drops
orders whose customer row is missing; a left join keeps them with NULL
customer columns. If a report total changed after "just switching to an inner
join for speed", this is why.

### 2.4 Text search that behaves

```dart
Col('Name').contains('50%')      // LIKE '%50[%]%'  — the literal string
Col('Name').startsWith('AC')     // LIKE 'AC%'
Col('Name').endsWith('Ltd')      // LIKE '%Ltd'
Col('Name').notContains('test')
Col('Name').like('AC_ME%')       // your pattern, still escaped for [ ] etc.
Col('Name').likeRaw('AC[0-9]%')  // your pattern, NOT escaped — you own it
```

`contains` / `startsWith` / `endsWith` escape `%`, `_` and `[` in the search
term, so a user searching for `50%` gets the literal string rather than every
row. `likeRaw` is the deliberate opt-out, for when the pattern itself is
yours.

These live on **text** expressions. An untyped `Col('…')` counts as one — it
has no declared type, so the builder cannot object. A *typed* column does:
`OrderFields.total.contains('5')` on a `decimal` column does not compile,
because asking SQL Server to `LIKE` a `decimal` either converts the column —
losing the index — or fails on the first value that will not convert. That is
one of the things the ORM's generated columns buy you over bare strings.

### 2.5 Dates: the sargable form and the honest one

```dart
// Half-open ranges on the bare column. An index on PlacedAt can be used.
Col('o.PlacedAt').inYear(2026)
Col('o.PlacedAt').onDate(DateTime(2026, 9, 8))

// DATEPART / CAST on the column. Correct, but the column is wrapped in a
// function, so an index seek on it is no longer available.
Col('o.PlacedAt').whereYear(2026)
Col('o.PlacedAt').whereMonth(9)
Col('o.PlacedAt').whereDay(8)
Col('o.PlacedAt').whereDate(DateTime(2026, 9, 8))
Col('o.PlacedAt').whereTime(const Duration(hours: 9))

// Relative to the SERVER's clock, not the application's.
Col('o.DueAt').wherePast()          Col('o.DueAt').whereFuture()
Col('o.DueAt').whereNowOrPast()     Col('o.DueAt').whereNowOrFuture()
Col('o.PlacedAt').whereToday()      Col('o.PlacedAt').whereBeforeToday()
Col('o.PlacedAt').whereAfterToday() Col('o.PlacedAt').whereTodayOrBefore()
```

The two families are **not equivalent** and the package does not pretend
otherwise: `inYear` / `onDate` compile to `>= start AND < end`, and
`whereYear` compiles to `YEAR(col) = 2026`. Both are correct SQL. Only the
first leaves the column bare. No measurement is offered for either — the
difference is in what the optimizer is allowed to do, not in a benchmark
printed here.

For a `datetimeoffset` column, `inYear` and `onDate` require `zoneOffset:`,
because a calendar year is not one range on that type until someone says whose
calendar it is:

```dart
Col('o.PlacedAt').inYear(2026, zoneOffset: const Duration(hours: 3))
```

Grouping by a period uses the same descriptor in the `SELECT` list and the
`GROUP BY`, which is what ties the two together:

```dart
final month = Col('o.PlacedAt').monthStart();          // DATEADD/DATEDIFF form
final q = MssqlQuery.from('dbo.Orders', as: 'o')
    .select([month.as('Month'), sum(Col('o.Total')).as('Revenue')])
    .groupBy([month])
    .orderBy([Col('Month').asc()]);
```

`truncatedTo(MssqlTemporalGrain.month)` is the same idea spelled generally.
`dateBucket(unit:, width:)` is SQL Server 2022's `DATE_BUCKET` and is
**refused** on older dialects rather than rewritten into something similar —
see [dialects](#38-dialects-two-numbers-not-a-name).

### 2.6 Grouping and `HAVING`

```dart
final q = MssqlQuery.from('dbo.Customers', as: 'c')
    .innerJoin('dbo.Orders', as: 'o', on: Col('o.CustomerId').eqCol('c.Id'))
    .innerJoin('dbo.OrderLines', as: 'l', on: Col('l.OrderId').eqCol('o.Id'))
    .where(Col('o.Status').ne('cancelled'))
    .groupBy([Col('c.Id'), Col('c.Name')])
    .havingCondition(sum(Col('l.LineTotal')).gt(MssqlDecimal.parse('10000')))
    .select([
      Col('c.Id'),
      Col('c.Name'),
      count(Col('o.Id'), distinct: true).as('OrderCount'),
      sum(Col('l.LineTotal')).as('Revenue'),
      avg(Col('l.UnitPrice')).as('AvgUnitPrice'),
      min(Col('o.PlacedAt')).as('FirstOrder'),
      max(Col('o.PlacedAt')).as('LastOrder'),
      countAll().as('LineCount'),
    ])
    .orderBy([Col('Revenue').desc()]);
```

Two arithmetic traps this example is written around:

- `count(Col('o.Id'), distinct: true)` — after joining lines, each order
  appears once per line. `COUNT(o.Id)` would count line duplicates.
- `avg(Col('l.UnitPrice'))` is the **unweighted mean of line rows**. The
  quantity-weighted unit price is `SUM(LineTotal) / SUM(Quantity)`. They are
  different numbers, and only one of them is what a business user means.

`countAll(big: true)` is `COUNT_BIG(*)`, for a count that can exceed a 32-bit
`int`.

### 2.7 `CASE` and `COALESCE`

```dart
final bucket = caseWhen(
  [
    MssqlCaseBranch(Col('o.Total').gte(10000), const MssqlLiteral('A')),
    MssqlCaseBranch(Col('o.Total').gte(1000),  const MssqlLiteral('B')),
    MssqlCaseBranch(Col('o.Total').isNull(),   const MssqlLiteral('unknown')),
  ],
  otherwise: const MssqlLiteral('C'),
);

final q = MssqlQuery.from('dbo.Orders', as: 'o')
    .select([
      Col('o.Id'),
      bucket.as('Tier'),
      coalesce([Col('o.Note'), Col('o.Comment'), const MssqlLiteral('')])
          .as('Text'),
    ])
    .groupBy([Col('o.Id'), bucket]);   // the same descriptor, so identical SQL
```

Only the **searched** form (`CASE WHEN cond THEN …`) exists. SQL Server's
simple form (`CASE x WHEN 1 THEN …`) is equality against `x`, so it never
matches when `x` is NULL — a bucket that silently loses the null rows. The
searched form can express the simple one and can also say `WHEN x IS NULL`.

---

## Level 3 · Advanced

### 3.1 Scalar subqueries

```dart
final lastOrderAt = scalarSubquery(
  MssqlQuery.from('dbo.Orders', as: 'lo')
      .select([max(Col('lo.PlacedAt'))])
      .where(Col('lo.CustomerId').eqCol('c.Id'))     // correlated
      .where(Col('lo.PlacedAt').gte(from))
      .where(Col('lo.PlacedAt').lt(to)),
);

final q = MssqlQuery.from('dbo.Customers', as: 'c')
    .select([Col('c.Id'), Col('c.Name'), lastOrderAt.as('LastOrderAt')]);
```

The subquery shares the parent's parameter allocator, so `from` and `to` are
bound once and there is no name collision between the two queries' parameters.

**Keep the scopes aligned.** If the outer query filters to 2026 and this
subquery does not, `LastOrderAt` is an all-time maximum sitting in a 2026
report — a different question, silently answered.

### 3.2 `EXISTS`, `NOT EXISTS`, `IN (subquery)`

```dart
final hasCancellation = MssqlQuery.from('dbo.Orders', as: 'x')
    .select([raw('1')])
    .where(Col('x.CustomerId').eqCol('c.Id'))
    .where(Col('x.Status').eq('cancelled'));

final clean = MssqlQuery.from('dbo.Customers', as: 'c')
    .whereNotExists(hasCancellation);

final q2 = MssqlQuery.from('dbo.Orders')
    .where(Col('CustomerId').inQuery(
      MssqlQuery.from('dbo.Customers').select([Col('Id')]).where(
        Col('City').eq('İstanbul'),
      ),
    ));
```

`whereExists`, `whereNotExists`, `inQuery`, `notInQuery`, and
`existsValue(query)` when you want the boolean **in the projection** rather
than in the `WHERE`.

`notInQuery` with a subquery whose column is nullable is the classic SQL
footgun — `NOT IN` against a set containing NULL returns no rows. Prefer
`whereNotExists` when the inner column can be NULL.

### 3.3 CTEs

```dart
final recent = MssqlQuery.from('dbo.Orders')
    .select([Col('Id'), Col('CustomerId'), Col('Total')])
    .where(Col('PlacedAt').gte(from));

final q = MssqlQuery.from('recent', as: 'r')
    .withCte('recent', recent)
    .innerJoin('dbo.Customers', as: 'c', on: Col('r.CustomerId').eqCol('c.Id'))
    .select([Col('c.Name'), sum(Col('r.Total')).as('Revenue')])
    .groupBy([Col('c.Name')]);
```

A **typed** CTE gives you column types, and therefore typed operators on its
columns:

```dart
final tree = MssqlTypedCte.recursive(
  name: 'tree',
  fields: [
    MssqlCteField('Id',
        const MssqlColumnType(type: MssqlType.int32, nullable: false)),
    MssqlCteField('ParentId',
        const MssqlColumnType(type: MssqlType.int32, nullable: true)),
    MssqlCteField('Name',
        const MssqlColumnType(type: MssqlType.nvarchar, size: 200,
            nullable: false)),
    MssqlCteField('Depth',
        const MssqlColumnType(type: MssqlType.int32, nullable: false)),
  ],
  maxRecursion: 20,
  anchor: MssqlQuery.from('dbo.Categories')
      .select([Col('Id'), Col('ParentId'), Col('Name'), const MssqlLiteral(0)])
      .where(Col('Id').eq(rootId)),
  recursiveMember: MssqlQuery.from('dbo.Categories', as: 'c')
      .innerJoin('tree', on: Col('tree.Id').eqCol('c.ParentId'))
      .select([
        Col('c.Id'), Col('c.ParentId'), Col('c.Name'),
        MssqlArithmetic(Col('tree.Depth'), MssqlArithmeticOperator.add, 1),
      ]),
);

final statement = tree
    .read()
    .where(tree.column('Depth').lte(4))
    .orderBy([tree.column('Depth').asc(), tree.column('Name').asc()])
    .compile();
```

**`maxDepth` and `MAXRECURSION` are different things.** `Depth <= 4` filters
the result. `MAXRECURSION` is SQL Server's runaway guard: exceeding it *fails
the query* with error 530. Set the guard above the depth you expect, and
filter with the depth column.

### 3.4 Window functions

```dart
final byCustomer = MssqlWindow(
  partitionBy: [Col('o.CustomerId')],
  orderBy: [Col('o.PlacedAt').desc()],
);

final q = MssqlQuery.from('dbo.Orders', as: 'o')
    .select([
      Col('o.Id'),
      Col('o.CustomerId'),
      Col('o.Total'),
      MssqlWindowExpression.rowNumber(byCustomer).as('Rn'),
      MssqlWindowExpression.rank(byCustomer).as('Rank'),
      MssqlWindowExpression.lag(Col('o.Total'), byCustomer).as('PreviousTotal'),
      sum(Col('o.Total')).over(MssqlWindow(
        partitionBy: [Col('o.CustomerId')],
        orderBy: [Col('o.PlacedAt').asc()],
        frame: MssqlWindowFrame(
          unit: MssqlFrameUnit.rows,
          start: MssqlFrameBound.unboundedPreceding,
          end: MssqlFrameBound.currentRow,
        ),
      )).as('RunningTotal'),
    ]);
```

Available: `rowNumber`, `rank`, `denseRank`, `ntile(n)`, `lag`, `lead`, and
`over(window)` on any aggregate. Two validations happen at build time:

- A frame needs an `orderBy` — a frame counts rows either side of the current
  one, which needs an order to count in.
- Ranking functions take **no** frame; SQL Server rejects one.

`lag` without `ifMissing` leaves the first row of each partition NULL, which
is the honest answer: there is no earlier row, and substituting zero would
make the first change look like a full one.

`LAG` / `LEAD` / frames are **refused** on SQL 2008 rather than rewritten into
a self-join that means something slightly different.

### 3.5 `UNION` and `UNION ALL`

```dart
final combined = MssqlQuery.from('dbo.Orders')
        .select([Col('Id'), Col('Code'), raw("'order'").as('Kind')])
    .unionAll(
      MssqlQuery.from('dbo.Quotes')
          .select([Col('Id'), Col('Code'), raw("'quote'").as('Kind')]),
    )
    .orderBy([Col('Code').asc()])
    .paged(offset: 0, rows: 50);
```

`union` de-duplicates and `unionAll` does not; the set query takes its own
`orderBy` and `paged`, which apply to the combined result.

### 3.6 INSERT, UPDATE, DELETE

```dart
// INSERT with a server-side expression.
await MssqlInsert.into('dbo.AuditLog')
    .values({'Message': 'started', 'CreatedAt': raw('SYSDATETIME()')})
    .run(session);

// INSERT … OUTPUT: read back what the server generated.
final inserted = await MssqlInsert.into('dbo.Orders')
    .values({'Code': 'A-1', 'CustomerId': 1})
    .returning(MssqlOutputClause([MssqlOutputColumn.inserted('Id')]))
    .runReturning(session);
final newId = inserted.single.require<int>('Id');

// INSERT … SELECT, for an archive move.
await MssqlInsert.into('dbo.OrdersArchive')
    .using(
      ['Id', 'CustomerId', 'Code', 'Total'],
      MssqlQuery.from('dbo.Orders')
          .select([Col('Id'), Col('CustomerId'), Col('Code'), Col('Total')])
          .where(Col('Status').eq('closed'))
          .where(Col('PlacedAt').lt(cutoff)),
    )
    .run(session);

// UPDATE — a predicate is required.
final closed = await MssqlUpdate.table('dbo.Orders')
    .set({'Status': 'closed', 'ClosedAt': raw('SYSDATETIME()')})
    .where(Col('Status').eq('open'))
    .where(Col('Id').eq(orderId))
    .run(session);

// DELETE — likewise.
await MssqlDelete.from('dbo.Sessions')
    .where(Col('ExpiresAt').wherePast())
    .run(session);

// The whole table, said out loud.
await MssqlDelete.from('dbo.TempRows').allRows().run(session);
```

`UPDATE` and `DELETE` **refuse to compile** without a predicate — a
`StateError`, at build time, before anything reaches the server. `allRows()`
is the explicit opt-in, and it is one word longer than the accident.

`MssqlDefault()` writes a column's `DEFAULT` keyword;
`MssqlInsert.into(t).defaultValues()` is `INSERT … DEFAULT VALUES`.

### 3.7 Upsert

```dart
await MssqlUpsert.into(
  'dbo.Settings',
  matching:     {'Key': 'theme'},                    // how a row is identified
  insertValues: {'Key': 'theme', 'Value': 'dark'},   // if it is not there
  updateValues: {'Value': 'dark'},                   // if it is
).run(session);
```

Every key in `matching` must also appear in `insertValues` with the same
value — otherwise the row you insert is not the row you looked for, and the
next upsert inserts another one. That is checked at construction.

An upsert is not a substitute for a unique index. Two concurrent upserts can
both find nothing and both insert; the index is what turns the loser into a
duplicate-key error you can handle (`MssqlConstraintException.isDuplicateKey`).

### 3.8 Dialects: two numbers, not a name

```dart
page.compile(dialect: MssqlDialect.sql2012);   // OFFSET … FETCH (default)
page.compile(dialect: MssqlDialect.sql2008);   // ROW_NUMBER() paging
page.compile(dialect: MssqlDialect.forVersion(majorVersion: 16));
page.compile(dialect: MssqlDialect.forVersion(
  majorVersion: 16,          // SQL Server 2022 engine …
  compatibilityLevel: 100,   // … hosting a database left at level 100
));
```

`MssqlDialect` carries the **product major version and the database
compatibility level**, because a 2022 engine hosting a database still at level
100 rejects 2012 language exactly as a 2008 server would. Compiling that
database with `MssqlDialect.sql2012` is wrong, and the failure would arrive
from the server rather than from here.

An unsupported feature throws `MssqlCapabilityException` at compile time. It
is never rewritten into SQL that looks similar and means something else:

| Feature | Needs |
|---|---|
| `OFFSET … FETCH` paging | 2012 / compat 110 — otherwise `ROW_NUMBER()` is emitted instead |
| `LAG`, `LEAD`, `FIRST_VALUE`, `LAST_VALUE`, `ROWS`/`RANGE` frames | 2012 / 110 |
| `DATEFROMPARTS`, `EOMONTH`, `TRY_CONVERT` | 2012 / 110 |
| `STRING_AGG` | 2017 / 140 |
| `DATE_BUCKET` (`dateBucket()`) | 2022 / 160 |
| `monthStart()`, `truncatedTo()`, recursive CTEs, `MAXRECURSION` | no gate |

Paging is the one exception, because it has two honest shapes rather than one
correct one and one approximation.

If you have an ORM `AppDatabase`, `db.query(...)` resolves the real dialect
once from the live server through a capability cache, so you do not have to
pass one at all.

---

## Level 4 · Hard

### 4.1 Recursive walks with `MssqlHierarchy`

`MssqlTypedCte.recursive` written by hand is the general form. When a table
walks itself through one self-referencing key, `MssqlHierarchy` is the same
walk without naming the columns twice:

```dart
final statement = CategoryQuery.hierarchy      // generated, or hand-built
    .descendantsOf(
      rootCategoryId,
      maxDepth: 4,
      includeRoot: false,
      cycles: MssqlCycleHandling.error,
      maxRecursion: 20,
    )
    .compile();
```

`descendantsCte(root, …)` gives you the recursive expression **on its own**,
for a statement you own that needs the walk as one of its `WITH` members — a
generated `descendantsOf` on an entity query does exactly this, which is how it
stays an ordinary query with its own scopes, ordering and paging. SQL Server
allows `WITH` only at the start of a statement, which is why the walk can never
be a subquery.

`MssqlCycleHandling.error` lets `MAXRECURSION` raise 530 on a cyclic graph;
`skipVisited` carries the visited path instead, at the cost of a string
comparison per row.

### 4.2 Keyset chunking over a large table

```dart
await MssqlQuery.from('dbo.LabelEvents')
    .where(Col('SeenAt').gte(since))
    .orderBy([Col('Id').asc()])            // required, and must be named columns
    .chunk(session, 5000, (rows) async {
      await sink.writeAll(rows);
      return true;                          // false stops the walk early
    });
```

This is keyset paging, not `OFFSET`: each chunk continues from the last row's
keys, so the cost of chunk 1000 is the same as chunk 1. `chunk` without an
`orderBy` throws — without one, two pages can return the same row and never
return another.

A mutable order column is still not a snapshot: a row edited into an earlier
key position while you walk will not be revisited.

### 4.3 Raw SQL fragments, and what they cost

```dart
final q = MssqlQuery.from('dbo.Orders', as: 'o')
    .select([
      Col('o.Id'),
      raw('DATEDIFF(day, MIN(o.PlacedAt), MAX(o.PlacedAt))').as('SpanDays'),
    ])
    .where(raw('o.Total > o.PaidTotal'));
```

`raw` is the escape hatch for SQL this builder does not model. Two things
follow, and neither is hidden:

- `MssqlStatement.containsRawSql` becomes `true`, and the execution extensions
  then **do not** mark the statement as safely retryable. A `SELECT` the
  builder wrote entirely is repeatable after a lost connection; one with a
  fragment in it is not something the package will claim to understand.
- The fragment is your responsibility. Never interpolate user input into it —
  bind it instead:

```dart
// ✗ injection
.where(raw("o.Code = '$userInput'"))
// ✓ let the builder allocate a parameter
.where(Col('o.Code').eq(userInput))
```

### 4.4 Parameter allocation, and why names never collide

```dart
final stmt = q.compile();
print(stmt.parameters);   // {q0: …, q1: …, q2: …}
```

An `MssqlParameterAllocator` hands out `q0`, `q1`, … as the query compiles,
and subqueries share the parent's allocator. So a value used in a `WHERE`, in
a correlated subquery and in a `HAVING` gets three distinct names — and the
same allocator is why you can never accidentally shadow a parameter by
building the two halves of a query independently.

The names are an implementation detail. Do not write SQL that references `@q0`
and do not reorder the map.

### 4.5 Locking hints, when you actually need them

```dart
await connection.transaction((tx) async {
  final row = await MssqlQuery.from('dbo.Stock')
      .where(Col('Id').eq(productId))
      .lockForUpdate()                 // WITH (UPDLOCK, ROWLOCK)
      .first(tx);

  await MssqlUpdate.table('dbo.Stock')
      .set({'Quantity': raw('Quantity - 1')})
      .where(Col('Id').eq(productId))
      .run(tx);
});
```

`lockForUpdate()`, `sharedLock()` (`HOLDLOCK, ROWLOCK`) and the general
`withHint('…')`. A hint outside a transaction is usually a mistake: the lock is
released at the end of the statement, so the read it was meant to protect is
already over.

### 4.6 The refusals, collected

Every one of these is a Dart **runtime** error raised while you build or
compile — not an analyzer error, and not a server round trip.

| What you wrote | What happens | Write instead |
|---|---|---|
| `Col('x').eq(null)` | `ArgumentError` | `Col('x').isNull()` |
| `Col('x').inList([])` | `ArgumentError` | decide what empty means |
| `.paged(...)` with no `orderBy` | `StateError` | add a stable order |
| `.chunk(...)` with no `orderBy` | `StateError` | add a keyed order |
| `MssqlUpdate` / `MssqlDelete` with no predicate | `StateError` | `.where(...)` or `.allRows()` |
| `MssqlWindow(frame:)` with no `orderBy` | `ArgumentError` | add `orderBy`, or drop the frame |
| a frame on `rank()` | `ArgumentError` | ranking functions take none |
| `dateBucket()` on a pre-2022 dialect | `MssqlCapabilityException` | `monthStart()` / `truncatedTo()` |
| `.contains('5')` on a typed `decimal` column | does not compile | text operators need a text type (untyped `Col` is not checked) |
| `MssqlUpsert` whose `matching` is not in `insertValues` | `ArgumentError` | make them agree |

Errors raised while **running** the statement are the driver's
(`MssqlException` and its subtypes) — see the
[driver cookbook](https://github.com/Aksoyhlc/mssql_native/blob/main/doc/EXAMPLES.md#38-failures-by-the-decision-you-make-about-them).

---

## Where to go next

| Question | Document |
|---|---|
| Typed tables, relations, writes | [ORM examples](EXAMPLES_ORM.md) |
| Terminal semantics, written out | [doc/API.md](API.md) |
| What is refused per SQL Server version | [doc/CAPABILITIES.md](CAPABILITIES.md) |
| Connections, parameters, bulk, pooling | [driver examples](https://github.com/Aksoyhlc/mssql_native/blob/main/doc/EXAMPLES.md) |
| Five runnable worked examples | `example/advanced_examples.dart`, [doc/EXAMPLES_ADVANCED.md](EXAMPLES_ADVANCED.md) |
