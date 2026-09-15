# Examples — the ORM

`import 'package:myapp/db/generated/database.g.dart';`
`import 'package:myapp/db/generated/generated.dart';`

The ORM is the generated half: you point the generator at a SQL Server
database, and it writes typed row classes, query classes with a
`whereStatus(...)` per column, relations, projections and an `AppDatabase`
that ties them to a session. **The database is the source of truth; Dart is
generated from it.** There are no migrations.

Everything here assumes the generated sales schema used by
`example/advanced_examples.dart`, with `class_names: { dbo.Orders: Order }` —
so the row is `OrderRow`, the query is `OrderQuery`, and the table getter is
`db.orders`.

| Level | What it covers | Read it when |
|---|---|---|
| [0 · Setup](#level-0--setup) | generate, open, close | first hour |
| [1 · Simple](#level-1--simple) | find, filter, order, read terminals | first screen |
| [2 · Everyday](#level-2--everyday) | optional filters, paging, projections, create/update/delete, transactions | ordinary application code |
| [3 · Advanced](#level-3--advanced) | relations, aggregates, batch writes, soft delete, custom SQL, cursors | a real product |
| [4 · Hard](#level-4--hard) | scopes, concurrency, graph writes, streaming, watch, observers, drift | the edges |

---

## Level 0 · Setup

### 0.1 Three packages, one of which never ships

| Package | Role | Where it goes |
|---|---|---|
| `mssql_native` | the TDS driver | `dependencies` |
| `mssql_orm` | this runtime: query builder, `AppDatabase`, schema reader | `dependencies` |
| `mssql_orm_dev` | the generator CLI | `dev_dependencies` — never deployed |

```yaml
dependencies:
  mssql_native:
  mssql_orm:
dev_dependencies:
  mssql_orm_dev:
```

The split is not cosmetic: a `bin/` script resolves against *its own* package's
`dependencies`, so a generator living in the runtime package would put `args`,
`yaml` and `dart_style` into every production build.

### 0.2 Generate

```bash
dart run mssql_orm_dev:init       # writes tool/mssql_orm.yaml if missing
dart run mssql_orm_dev:doctor     # SDK, native assets, TLS env, config
dart run mssql_orm_dev:generate
```

```yaml
# tool/mssql_orm.yaml
connection:
  from: env:MSSQL_CONNECTION_STRING
output: lib/db/generated
extensions_output: lib/db/extensions
models_output: lib/db/models
snapshot: tool/mssql_schema.json
queries_input: lib/db/queries
database_class: AppDatabase
decimal_mode: exact
class_names:
  dbo.Orders: Order
  dbo.OrderLines: OrderLine
```

`decimal_mode` must match the `MssqlConnectionConfig` you connect with.
`decimal_as_double` is refused; the choices are `exact` (default), `text`,
`double`.

Live generation is plaintext by default. If `connection.encryption` selects
`require` or `strict`, configure trust with
`MSSQL_TLS_CA=/path/ca.pem` or `MSSQL_TLS_SYSTEM=1`. Offline generation from
the committed snapshot needs neither a password nor trust:

```bash
dart run mssql_orm_dev:snapshot            # refresh tool/mssql_schema.json
dart run mssql_orm_dev:generate --snapshot # offline
dart run mssql_orm_dev:generate --check    # CI: non-zero if stale
```

**Two directories, two owners:**

```
lib/db/
  generated/*.g.dart     rewritten every run — never edit
  models/*.dart          created once — yours
  extensions/*.dart      created once — yours (scopes)
  queries/*.sql          yours → becomes db.reports.*
```

Regeneration does not overwrite or delete what you own.

### 0.3 Open, use, close

```dart
import 'package:mssql_native/mssql_native.dart';
import 'package:myapp/db/generated/database.g.dart';
import 'package:myapp/db/generated/generated.dart';

Future<void> main() async {
  await MssqlRuntime.instance.initialize();

  final db = await AppDatabase.open(const MssqlConnectionConfig(
    host: 'localhost',
    database: 'AdventureWorks',
    username: 'sa',
    password: '…',
  ));

  final open = await db.orders.whereStatus('open').get();
  print(open.first.code);          // typed String

  await db.close();
  await MssqlRuntime.instance.shutdown();
}
```

### 0.4 Which constructor

| Constructor | Owns | You close |
|---|---|---|
| `AppDatabase.open(config)` | a connection it opened | `await db.close()` |
| `AppDatabase.openPool(config)` | a pool it created | `await db.close()` |
| `AppDatabase.borrow(connection)` | nothing | the connection |
| `AppDatabase.withPool(pool)` | nothing | the pool |
| `AppDatabase(session)` | nothing | the session |

`close()` closes only what the database opened. In a server, open a pool once
at startup:

```dart
final db = AppDatabase.openPool(config,
    pool: const MssqlPoolConfig(minimumSize: 2, maximumSize: 8));
```

Do **not** construct `MssqlTableBinding` by hand, and do not look for an
`MssqlExecutor` — there is no executor adapter. Generated code talks to
`MssqlSession` from the driver.

---

## Level 1 · Simple

### 1.1 By primary key

```dart
final order = await db.orders.find(42);        // OrderRow? — null if absent
final must  = await db.orders.getById(42);     // OrderRow — throws if absent
```

`getById` throws `MssqlRowNotFoundException`. The pair exists so "not found"
is a decision you make, not a null that travels three layers before crashing.

### 1.2 Filter with generated methods

One `whereX` per column is emitted, so a typo is a **compile** error:

```dart
final rows = await db.orders
    .whereStatus('open')
    .whereCustomerId(7)
    .get();
```

For anything past equality, `where` hands you the table's fields:

```dart
final rows = await db.orders
    .where((o) => o.total.gte(MssqlDecimal.parse('1000')))
    .where((o) => o.placedAt.gte(placedFrom))
    .where((o) => o.status.inList(['open', 'shipped']))
    .get();
```

`o` is an `OrderFields` — SQL **columns**, not a row. The columns are typed,
so `o.total.contains('5')` on a `decimal` does not compile, and
`o.status.eq(42)` does not either.

### 1.3 Order

```dart
final rows = await db.orders
    .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
    .thenBy((o) => [o.code.asc()])
    .get();

// When the column name is data (a sortable table header):
final sorted = db.orders.orderByNamed(userColumn, descending: true);
```

`orderByNamed` validates the name against the table's real columns and throws
on anything else — that is what makes a user-chosen sort safe.

### 1.4 The read terminals, and what each one does about surprises

```dart
await db.orders.whereStatus('open').get();            // List<OrderRow>
await db.orders.whereStatus('open').first();          // OrderRow?
await db.orders.whereStatus('open').firstOrFail();    // OrderRow
await db.orders.whereCode('A-1').single();            // OrderRow
await db.orders.whereCode('A-1').singleOrNull();      // OrderRow?
await db.orders.whereStatus('open').count();          // int
```

| Method | Zero rows | Many rows |
|---|---|---|
| `get()` | `[]` | every match — **no hidden limit** |
| `first()` | `null` | the first in the requested order |
| `firstOrFail()` | `MssqlRowNotFoundException` | the first |
| `single()` | `MssqlRowNotFoundException` | `MssqlCardinalityException` |
| `singleOrNull()` | `null` | `MssqlCardinalityException` |
| `count()` | `0` | the **result-row** count |

`single` is how you assert a uniqueness you believe in. "Two rows for one
code" then arrives as its own exception instead of a `.first` that quietly
picks one.

`first()` and `page()` with no `orderBy` fall back to the primary key; a
keyless table is refused rather than paged arbitrarily.

---

## Level 2 · Everyday

### 2.1 A search screen

```dart
Future<MssqlPage<OrderListItem>> search({
  String? term,
  DateTime? placedFrom,
  List<String> statuses = const [],
  int page = 0,
}) {
  final from = placedFrom == null
      ? null
      : MssqlDateTimeValue.fromDateTime(placedFrom);

  return db.orders
      .search(term, (o) => [o.code])              // null/empty/blank ⇒ no LIKE
      .whereIfNotNull(from, (o, value) => o.placedAt.gte(value))
      .whereInIfNotEmpty(statuses, (o, list) => o.status.inList(list))
      .whereIf(onlyBig, (o) => o.total.gte(MssqlDecimal.parse('1000')))
      .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
      .select(OrderListItem.projection)
      .page(size: 25, offset: page * 25, total: true);
}
```

The conditional helpers exist so an unfilled filter appends nothing at all:

| Helper | Adds the clause when |
|---|---|
| `search(term, columns)` | `term` is non-null and not blank |
| `whereIf(test, predicate)` | `test` |
| `whereIfNotNull(value, predicate)` | `value != null` — arrives non-null in the callback |
| `whereInIfNotEmpty(list, predicate)` | `list.isNotEmpty` |
| `when(test, (q) => …)` | `test`, for a whole sub-chain |

### 2.2 Paging

```dart
final result = await db.orders
    .whereStatus('open')
    .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
    .page(size: 25, offset: 50, total: true);

result.rows;           // List<OrderRow>
result.hasMore;        // bool
result.total;          // int? — non-null only because total: true
result.offset;         // 50
```

- `hasMore` is answered by fetching one extra row and dropping it — not by a
  second `COUNT`.
- `total` costs a second statement, so it is computed only when you ask.
- `MssqlReadConsistency.snapshot` runs the page, its total **and** its
  includes inside one SNAPSHOT transaction, so the three cannot disagree.

```dart
await db.orders
    .orderBy((o) => [o.id.desc()])
    .page(size: 25, total: true,
        consistency: MssqlReadConsistency.snapshot);
```

### 2.3 Projections — read only the columns you use

```dart
// Generated, from `projections:` in the config.
final page = await db.orders
    .orderBy((o) => [o.id.desc()])
    .select(OrderListItem.projection)
    .page(size: 25);
print(page.rows.first.code);          // typed OrderListItem, not OrderRow

// Ad hoc tuples, when a named class would be noise.
final pairs = await db.orders.select2<int, String>((o) => (o.id, o.code)).get();
for (final (id, code) in pairs) { print('$id $code'); }
```

`select2` through `select4` exist. A projection is not a row: it has no
relations and no `copyWith`, because it is not the table.

### 2.4 Create

```dart
final order = await db.orders.create(OrderRowBaseCreate(
  customerId: customer.id,
  code: 'SO-2026-1001',
  status: 'open',
  total: MssqlDecimal.parse('1499.90'),
  placedAt: MssqlDateTimeValue.fromDateTime(DateTime.utc(2026, 9, 8)),
));

print(order.id);        // the identity the server assigned
```

`create` returns the **stored** row: identity values, `DEFAULT`s and anything
a trigger wrote are read back, so you do not follow an insert with a select.

**Absent is not null.** A Create field you omit is not named in the `INSERT`
at all, so the column's SQL `DEFAULT` runs. Binding `null` would overwrite
that default with NULL, which is a different statement and usually not what
was meant.

### 2.5 Update

```dart
final affected = await db.orders
    .whereId(order.id)
    .whereStatus('open')                 // a guard, not just a filter
    .update(
      const OrderRowBasePatch(status: Field.value('closed')),
      expectAffected: 1,
    );
```

A patch names only the fields you set:

```dart
const OrderRowBasePatch()                          // touches nothing
OrderRowBasePatch(status: Field.value('closed'))   // sets Status
OrderRowBasePatch(note: Field.value(null))         // sets Note = NULL
```

An empty patch does **not** stamp `updated_at` as a side effect.

`expectAffected: 1` raises `MssqlAffectedRowsException` when the count differs
— which is how "someone closed this order while the form was open" becomes an
error instead of a silent no-op. Combined with `whereStatus('open')` in the
same statement, this is a compare-and-set with no read-then-write race.

**A user predicate is required.** A global scope does not count, and
`allRows()` is the explicit whole-table opt-in.

### 2.6 Delete

```dart
await db.orders.whereId(id).delete(expectAffected: 1);
await db.orders.whereId(id).forceDelete();   // bypasses the soft-delete filter
await db.orders.whereId(id).restore();       // only rows that ARE soft-deleted
```

When the table has a soft-delete column (the `deleted_at` convention, or
`soft_delete_columns:` in the config), `delete()` sets it and the ordinary
query filters it out. `forceDelete()` bypasses **only** that filter — it is not
a licence to ignore the rest of the `WHERE`.

### 2.7 Transactions

```dart
await db.transaction((tx) async {
  final customer = await tx.customers.getOrCreateByCode('ACME',
      name: 'ACME Ltd', city: 'İstanbul', isActive: true);

  final order = await tx.orders.create(OrderRowBaseCreate(
    customerId: customer.id, code: 'SO-1', status: 'open',
    total: MssqlDecimal.parse('100.00'),
    placedAt: MssqlDateTimeValue.fromDateTime(DateTime.utc(2026, 9, 8)),
  ));

  await tx.orderLines.createMany([...]);
  final rows = await tx.reports.categoryTrend(rootId: 1, since: month);
});
```

`tx` is the **same `AppDatabase` type**, bound to the transaction's session.
Every getter — tables, `reports`, `procedures` — uses it. That is why a
repository function can take an `AppDatabase` and work identically inside and
outside a transaction, with no "did you remember to pass the transaction"
class of bug.

It opens a real transaction in all three ownership models: on the connection,
on one pool lease held for the whole callback, or — when the database is
already inside a transaction — on a savepoint of it. A session that can do
none of those is **refused** rather than run without a transaction.

`getOrCreateByCode` is generated for a unique column: it inserts first and,
on 2627/2601, reads the winner. That is one round trip in the common case and
correct under concurrency, which a select-then-insert is not.

---

## Level 3 · Advanced

### 3.1 Relations, eagerly

```dart
final page = await db.orders
    .where((o) => o.status.ne('draft'))
    .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
    .include((o) => [
      o.customer.asInclude,
      o.lines
          .ordered([OrderLine.id.asc()])            // NOT .orderBy — see below
          .takePerParent(20)
          .then(OrderLineRel.product.then(ProductRel.category))
          .asInclude,
    ])
    .page(size: 50, offset: 0);

final first = page.rows.first;
print(first.customer?.name);
print(first.lines.first.product?.category?.name);
print(first.isLoaded('lines'));   // true
```

Each include level is one batched `IN` query, so a 50-row page does not become
51 statements. What the statement count tracks is include **depth**,
through-relations and `takePerParent` (which adds a `ROW_NUMBER`) — **not**
page size. It is not "always four queries".

Two exceptions that are exceptions on purpose:

```dart
final o = page.rows.first;
o.lines;      // MssqlRelationNotLoadedException if you did not include it
              // MssqlRelationTruncatedException if takePerParent cut it off
```

A relation you forgot to load throws instead of reading as empty, and a
truncated one throws instead of looking complete. Both are the bugs that
otherwise ship.

**`.ordered(...)`, not `.orderBy(...)`.** The generated relation extension's
`orderBy` is shadowed by `MssqlRelation.orderBy`, which is a *field* holding
the stored list. `.ordered([...])` is the method.

Load a relation after the fact:

```dart
final orders = await db.orders.whereStatus('open').get();
final filled = await db.orders.loadMissing(orders, (o) => [o.lines.asInclude]);
```

### 3.2 Filtering by a relation

```dart
// Customers who have at least one open order — EXISTS, not a join, so a
// customer with ten orders is still one customer.
final active = await db.customers
    .whereHas((c) => c.orders.where((o) => o.status.eq('open')))
    .get();

// …who have none.
final dormant = await db.customers.whereDoesntHave((c) => c.orders).get();

// Filter AND load the same children, from one handle, so the loaded rows
// are exactly the ones the filter named.
final withOpen = await db.customers
    .withWhereHas((c) => c.orders.where((o) => o.status.eq('open')))
    .get();
```

`withWhereHas` is the fix for the most common eager-loading bug: filtering
parents by one predicate and loading children by another, then wondering why
a "customer with open orders" shows a closed one.

### 3.3 Relation aggregates

```dart
final counted = await db.orders.withCount((o) => o.lines).get();
for (final (order, lineCount) in counted) { … }

// The operand is a column expression — the generated static, not a callback.
final revenue = await db.orders
    .withSum<OrderLineRow, MssqlDecimal>((o) => o.lines, OrderLine.lineTotal)
    .get();
for (final (order, total) in revenue) { … }   // total is MssqlDecimal?

await db.orders.withExists((o) => o.lines).get();          // (OrderRow, bool)
await db.orders
    .withMin<OrderLineRow, MssqlDecimal>((o) => o.lines, OrderLine.unitPrice);
await db.orders
    .withAvgExact<OrderLineRow>((o) => o.lines, OrderLine.unitPrice);
await db.orders
    .withAvgTruncating<OrderLineRow, int>((o) => o.lines, OrderLine.quantity);
```

These are projections, not fields: a count is not a column of the table, and
stuffing it onto `OrderRow` would make `fromRow` and `==` lie. An aggregate of
zero children is SQL `NULL`, not zero — "the sum of no rows" has no value —
which is why every result is `V?`.

Two design decisions you will run into:

- The value type parameter is **unbounded**, not `V extends num`. `num` would
  read as the safe bound and be the lossy one, because `MssqlDecimal` is not a
  `num` — it would push an exact money column's sum through `double`. A `V`
  the value cannot become is an error naming the aggregate, never a quietly
  rounded answer.
- `withAvgExact` and `withAvgTruncating` are separate methods because `AVG` of
  an integer column is **integer division** in SQL Server. A flag whose
  result type the caller could not see would hide that.

`withCount` defaults to `COUNT_BIG`, so a busy relation cannot overflow
(error 8115). `big: false` when you know it fits.

### 3.4 Batch writes

```dart
// Many inserts, batched. Never switches to BCP on its own.
final result = await db.orderLines.createMany(
  lines,
  strategy: MssqlCreateManyStrategy.insertValues,   // or .bulkCopy
  atomic: true,
  returnRows: true,
);
print('${result.insertedRows} rows, strategy ${result.strategy}');

// One row per key, one statement, via a staging join.
await db.orders.updateMany({
  1: const OrderRowBasePatch(status: Field.value('closed')),
  2: const OrderRowBasePatch(note: Field.value(null)),
}, expectAffected: 2);

// Grouped stock decrement: the same product twice becomes one UPDATE.
await db.products.decrementQuantities(
  keyColumn: 'Id',
  quantityColumn: 'Stock',
  requests: [(key: 11, amount: 2), (key: 12, amount: 1), (key: 11, amount: 3)],
);
```

`MssqlCreateManyStrategy.bulkCopy` uses the driver's BCP path — much faster
for large batches, but it bypasses `OUTPUT`, so `returnRows` cannot be
honoured the same way. The strategy is explicit precisely so this is a choice
and not a surprise.

`updateMany` groups patches by **which columns they name**, so a column one
patch leaves absent is never written as NULL for that row, and a `DEFAULT`
stays the target's own. Two patches for the same row are **refused**: a
staging join would apply both in no defined order.

Batch writes carry the query's scopes — they reach exactly the rows a
single-row `update()` on the same query would: not another tenant's, and not a
soft-deleted one unless `withTrashed()` asked for it. `createMany` and
`createGraph` apply none, because an insert has no `WHERE` to apply one to; a
tenant column on a new row belongs in the Create values.

### 3.5 Soft delete and scopes

```dart
await db.orders.get();                 // live rows only (the default)
await db.orders.withTrashed().get();   // live + soft-deleted
await db.orders.onlyTrashed().get();   // just the soft-deleted
await db.orders.withoutTrashed().get();

await db.orders.withoutScope('tenant').get();
await db.orders.withoutGlobalScopes().get();
```

Your own filters go in **extensions on the generated query type**, in
`lib/db/extensions/` — a file the generator writes once and never overwrites:

```dart
// lib/db/extensions/orders_scopes.dart
extension OrderScopes on OrderQuery {
  OrderQuery open()            => whereStatus('open');
  OrderQuery placedSince(DateTime d) =>
      where((o) => o.placedAt.gte(MssqlDateTimeValue.fromDateTime(d)));
}
```

```dart
import 'package:myapp/db/extensions/orders_scopes.dart';   // not in the barrel

final rows = await db.orders
    .where((o) => o.customerId.eq(customerId))
    .open()                        // your extension
    .whereStatus('open')           // generated
    .get();
```

The generated barrel deliberately does not export your extensions — importing
them is how you say which scopes are in play in this file.

### 3.6 Custom SQL and stored procedures, still on the same session

Put a `.sql` file under `queries_input`:

```sql
-- lib/db/queries/category_trend.sql
-- name: categoryTrend
-- param: rootId int
-- param: since datetime2
-- returns: list
-- describe: manual
-- column: CategoryId int notnull
-- column: MonthStart date notnull
-- column: Revenue decimal(18,4)
WITH tree AS (…)
SELECT … WHERE c.RootId = @rootId AND o.PlacedAt >= @since;
```

and it becomes a typed method:

```dart
await db.transaction((tx) async {
  final rows = await tx.reports.categoryTrend(rootId: 1, since: month);
  await tx.procedures.recalculateStock(companyId: 1);
  await tx.orders.whereStatus('open').get();      // same transaction
});
```

Directives: `-- name:` (required), `-- param: x nvarchar(50)`,
`-- returns: list|single|single_or_null|scalar|affected`, `-- notnull: Col`,
`-- read_only: true` (opt into retry — returning rows does not imply it),
`-- procedure: dbo.sp_X`, `-- describe: manual` with `-- column:` lines.

Shapes come from `sp_describe_first_result_set` when the statement is
describable. It sees the **first** result set only, and cannot see `#temp`
tables, `EXEC(@sql)`, or a first result set whose shape depends on a branch.
For those, `-- describe: manual` is **your declaration** — the server does not
verify it, and if the SQL changes shape Dart will not notice until you update
the directives.

You are not leaving the package by writing SQL: same session, same
transaction, same observer, same decimal mode.

### 3.7 Keyset (cursor) pagination

```dart
final first = await db.orders
    .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
    .cursorPage(size: 25);

final next = await db.orders
    .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
    .cursorPage(size: 25, after: first.next);
```

The cursor encodes the order **and** the filter, so a cursor minted by one
query is refused by a different one (`MssqlCursorMismatchException`) rather
than silently returning a wrong page. Order columns must be named columns —
not expressions — and a nullable one needs an explicit `MssqlNulls` policy,
because "where do NULLs sort" has no default that is right for everyone.

`after` and `before` cannot be combined: one direction per call.

---

## Level 4 · Hard

### 4.1 Tenant and user scopes: one snapshot per terminal

A scope is a factory — `MssqlCondition? Function()` — and it is called **once
per terminal**, not once per statement. So the two halves of a page (rows and
total) and all of its includes see the same value. Two halves of one page can
never land on two tenants across an `await`. The same holds for every chunk of
a `chunkById` walk and every batch of a batch write.

That is the property to remember when you wire a scope to a request-scoped
value: read it in the factory, not before.

### 4.2 Optimistic concurrency

```dart
final order = await db.orders.getById(id);

try {
  await db.orders.whereId(id).update(
    OrderRowBasePatch(status: Field.value('closed')),
    expectedVersion: order.rowVersion,      // the rowversion token
  );
} on MssqlConcurrencyException {
  return Conflict('someone else changed this order');
}
```

`expectedVersion` matching zero rows raises `MssqlConcurrencyException`; a
table with no `rowversion` column refuses the argument outright. A doomed
session is **not** retried.

For a unique-constraint race, name the index rather than matching a message:

```dart
try {
  await db.customers.create(input);
} on MssqlConstraintException catch (e) {
  if (!e.isDuplicateKey) rethrow;                        // 2601 / 2627
  if (duplicateKeyIs(e, 'UX_Customers_Code')) return Conflict('code taken');
  rethrow;                     // a different unique index — not our business
}
```

`duplicateKeyIs` reads the index name out of the server's message, so the
handler says which uniqueness was violated rather than treating every
duplicate as the same problem. `duplicateKeyName(e.message)` gives you the
name itself.

`getOrCreate` / `getOrCreateByCode` raise `MssqlUniqueConflictException` when
the insert collided **and** the session is already doomed, so the winning row
cannot be read back — roll the transaction back and retry. And
`sessionIsDoomed(session)` is the check to make before assuming a transaction
can still do anything.

### 4.3 Graph writes — explicit, never a cascade

```dart
final order = await db.orders.createGraph(
  OrderRowBaseCreate(
    customerId: 42, code: 'SO-2001', status: 'open',
    total: MssqlDecimal.parse('100.00'),
    placedAt: MssqlDateTimeValue.fromDateTime(DateTime.utc(2026, 9, 8)),
  ),
  lines: [
    OrderLineRowBaseCreate(orderId: 0, productId: 11, quantity: 1,
        unitPrice: MssqlDecimal.parse('50.00'),
        lineTotal: MssqlDecimal.parse('50.00')),
  ],
);
```

Only the relations you name are written, in one transaction, parents before
children (the `orderId: 0` placeholder is filled from the inserted parent).
There is no change tracker, no identity map, no `save()` that walks an object
graph, and no cascade delete. What gets written is what you passed.

Relation writes are equally explicit:

```dart
await db.transaction((tx) async {
  final lines = tx.orderLines.linesOf(order);   // or .related(order, (o) => o.lines)
  await lines.create(OrderLineRowBaseCreate(...));
  await lines.attach([existingLine]);           // many-to-many pivot
  await lines.detach(someLine);
  await lines.sync(finalSet, detaching: true);
  await lines.associate(child);                 // to-one
  await lines.dissociate();
});
```

They need a transaction and they do not cascade.

### 4.4 Streaming and chunking large tables

```dart
// Bounded memory, keyed walk, ordered by the primary key.
await for (final batch in db.orderLines
    .where((l) => l.orderId.gt(0))
    .chunkById(size: 5000)) {
  await sink.writeAll(batch);
}

// Row at a time.
await for (final row in db.orderLines.lazy(size: 5000)) { … }

// The driver's native row stream — cancel the subscription to cancel the
// native operation.
final sub = db.orderLines.stream().listen(process);
await sub.cancel();
```

One thing worth knowing: `stream()` **with `include`** is not the native
stream. A session runs one operation at a time, so an include query cannot be
issued while a row stream is still open — it would queue behind a stream that
cannot finish until the consumer takes the next row. With includes, `stream()`
becomes a keyset walk of `parentBatch` parents, memory stays bounded to one
batch plus its children, and it orders by the primary key.

### 4.5 Watching a query

```dart
final sub = db.orders
    .whereStatus('open')
    .watch(strategy: MssqlWatchStrategy.polling,
           interval: const Duration(seconds: 5))
    .listen(rebuildUi);
```

| Strategy | Sees |
|---|---|
| `localWrites` (default) | committed writes made through this `AppDatabase` family |
| `polling` | those, plus external writers, after `interval` |

`watch` **re-runs the query**. There is no CDC, no change-tracking push, and
no claim of one. `localWrites` is free and covers the common case — your own
app wrote the row. `polling` costs one query per interval and is the honest
answer for external writers.

### 4.6 Seeing the SQL: observers

```dart
final recorder = MssqlQueryRecorder();
final db = AppDatabase(connection.observedBy(recorder.record));

await db.orders.whereStatus('open').include((o) => [o.lines.asInclude]).get();

print(recorder.describe());     // every statement, in order, with timings
```

```dart
// In production, feed your logger instead — and note what is NOT included.
final observed = connection.observedBy(
  (event) => log.fine('${event.kind} ${event.queryName} ${event.elapsed}'),
  options: const MssqlObserverOptions(includeParameterValues: false),
);
```

`includeParameterValues` is `false` by default. Parameter values are the
payload — a password on its way into a users table, a customer's address —
and the default is not to log them. `mssqlRedactParameters` is there when you
want the names without the values.

An observer that throws **after** a statement succeeded does not surface
through your `catch`: the write already happened, and routing that error
through the caller would make a successful DML look like a failed one and
could trip a retry. It goes to a separate `MssqlDiagnosticSink`.

### 4.7 Schema drift

There are no migrations, so the counterpart is a drift check. In CI:

```bash
dart run mssql_orm_dev:generate --check    # is generated Dart stale?
dart run mssql_orm_dev:check_schema        # did a live table move?
dart run mssql_orm_dev:verify_queries      # did a .sql file's shape move?
```

At runtime, when you want a startup guard:

```dart
final report = await MssqlSchemaCheck.verify(
  connection,
  bindings: [
    OrderRepositoryBase.tableBinding,
    OrderLineRepositoryBase.tableBinding,
    CustomerRepositoryBase.tableBinding,
  ],
);

for (final difference in report.differences) {
  // describe() is one line: severity, table.column, kind, expected/actual,
  // and `remedy` — what to do about it, in a sentence.
  log.warning(difference.describe());
}
if (report.hasBreakingChanges) throw StateError('schema drift');
```

It returns a **report** rather than throwing. What to do about drift is your
decision — fail startup in development, log in production, stop only on
breaking changes — and a library making that choice for everyone would be
wrong for most of them.

Generated files also stamp `API contract: N`; the runtime refuses a binding
written against a different `MssqlApiVersion`, so a stale `.g.dart` against a
newer runtime is a clear error rather than mysterious behaviour.

### 4.8 Naming: what the generator actually emits

With `class_names: { dbo.Orders: Order }`, the **stem** is `Order`:

| Kind | Type |
|---|---|
| Row | `OrderRow` (extends `OrderRowBase`) |
| Query | `OrderQuery` |
| Fields (the `o` in `where`) | `OrderFields` |
| Insert input | `OrderRowBaseCreate` |
| Patch | `OrderRowBasePatch` |
| Unique keys | `OrderUnique` |
| Column statics | `Order` — typed handles (`Order.id`, `OrderLine.lineTotal`) |
| Relations | `OrderRel` |
| Table getter | `db.orders` |

The suffix-free `Order` is the generated column-statics holder, not a row
type: `Order.id` and friends are expression handles. There is no suffix-free
row class and no `OrdersRepository` on the getting-started path. `copyWith`
and `==` on a generated row cover the schema
fields **at generation time** — a field you add on a subclass is not part of
either, so put behaviour on the subclass or an extension, not extra persisted
columns.

### 4.9 The exceptions, collected

| Exception | Raised when |
|---|---|
| `MssqlRowNotFoundException` | `firstOrFail` / `single` / `getById` found nothing |
| `MssqlCardinalityException` | `single` / `singleOrNull` found more than one |
| `MssqlAffectedRowsException` | `expectAffected` did not match |
| `MssqlConcurrencyException` | `expectedVersion` matched zero rows |
| `MssqlUniqueConflictException` | a unique index rejected the write |
| `MssqlRelationNotLoadedException` | a relation getter was not included |
| `MssqlRelationTruncatedException` | an include hit `takePerParent` / `maxLoadedRows` |
| `MssqlCursorMismatchException` | a cursor from a different order or filter |
| `MssqlCapabilityException` | the SQL needs a newer SQL Server than the dialect says |
| `MssqlUnsafeWriteException` | an `UPDATE`/`DELETE` with no user predicate |
| `MssqlUnexpectedNullException` | SQL NULL arrived in a non-nullable Dart field |
| `MssqlBindingMismatchException` | a generated binding does not match the runtime contract |

Construction and `compile()` failures are plain Dart errors (`ArgumentError`,
`StateError`). Driver and server failures are `MssqlException` subtypes. Do
not treat one family as the other — see the
[driver cookbook](https://github.com/Aksoyhlc/mssql_native/blob/main/doc/EXAMPLES.md#38-failures-by-the-decision-you-make-about-them).

---

## Where to go next

| Question | Document |
|---|---|
| Terminal semantics, in a table | [doc/API.md](API.md) |
| Config keys, directives, ownership | [doc/GENERATION.md](GENERATION.md) |
| What is refused per SQL Server version | [doc/CAPABILITIES.md](CAPABILITIES.md) |
| Composing SQL by hand | [query builder examples](EXAMPLES_QUERY_BUILDER.md) |
| Connections, parameters, pooling, bulk | [driver examples](https://github.com/Aksoyhlc/mssql_native/blob/main/doc/EXAMPLES.md) |
| Five runnable worked examples | `example/advanced_examples.dart` |
