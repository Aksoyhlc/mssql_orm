# mssql_orm

A typed query builder and a database-first ORM for Microsoft SQL Server.

`mssql_orm` sits on top of the [`mssql_native`](https://pub.dev/packages/mssql_native)
driver and provides two independent libraries. The query builder composes SQL
from immutable Dart values and needs no code generation. The ORM runtime backs
the typed API that [`mssql_orm_dev`](https://pub.dev/packages/mssql_orm_dev)
generates from your schema.

The schema is the source of truth. There are no migrations to write or apply;
the generator reads the database and produces Dart that matches it.

Both libraries run on the same `MssqlSession`, so a generated query, a
composed query and hand-written SQL can share one connection and one
transaction.

```dart
final page = await db.orders
    .whereStatus('open')
    .where((o) => o.total.gte(MssqlDecimal.parse('1000')))
    .include((o) => [o.customer.asInclude, o.lines.asInclude])
    .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
    .page(size: 25, total: true);

print(page.rows.first.customer?.name);
```

`whereStatus` is a generated method, so a misspelling is a compile error.
`o.total` is a typed column, so a text operation on a `decimal` does not
compile. A relation that was not included throws rather than returning an
empty list.

## Contents

- [The two libraries](#the-two-libraries)
- [Install](#install)
- [Connecting](#connecting)
- [Generating the ORM](#generating-the-orm)
- [The query builder](#the-query-builder)
- [The generated API](#the-generated-api)
- [Reads](#reads)
- [Relations](#relations)
- [Writes](#writes)
- [Transactions](#transactions)
- [Scopes, soft deletes and timestamps](#scopes-soft-deletes-and-timestamps)
- [Custom SQL](#custom-sql)
- [Error handling](#error-handling)
- [Documentation](#documentation)

## The two libraries

| Import | Provides | Needs generation |
|---|---|---|
| `package:mssql_orm/query.dart` | the query builder | no |
| `package:mssql_orm/orm.dart` | the ORM runtime | yes |

The builder is usable on its own against any schema, including one this
package knows nothing about. The ORM needs the generated classes, because
those are what carry the column names and types.

Compilation is separate from execution in both. A query compiles to an
`MssqlStatement` holding the SQL and its parameter values, and values are
never written into the SQL text.

## Install

Dart 3.10 or newer. Three packages, of which two reach a production build:

| Package | Where | What it is |
|---|---|---|
| `mssql_native` | `dependencies` | the driver; the native SQL Server client libraries travel inside it |
| `mssql_orm` | `dependencies` | this package: the query builder and the ORM runtime |
| `mssql_orm_dev` | `dev_dependencies` | the generator, which never reaches a production build |

```yaml
dependencies:
  mssql_native: ^0.1.1
  mssql_orm: ^0.1.1
dev_dependencies:
  mssql_orm_dev: ^0.1.1     # only if you want the generated ORM
```

Nothing else is installed. There is no ODBC driver, no SQL Server client and
no compiler on the machine that runs the application: the driver package
carries its own libraries for every platform it supports.

Leave `mssql_orm_dev` out if you only want the query builder. It needs no
generation, no configuration file and no database at build time.

The three packages are released together, so keep their versions in step.

## Connecting

Both libraries run on an `MssqlSession` from the driver — a connection, a
pool, or a transaction. The query builder takes one directly:

```dart
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/query.dart';

final connection = await MssqlConnection.connect(
  host: 'sql.example.com',
  database: 'warehouse',
  username: 'app',
  password: password,
);

final rows = await MssqlQuery.from('dbo.Orders')
    .where(Col('Status').eq('open'))
    .get(connection);
```

The generated ORM wraps the same session in an `AppDatabase`. Which
constructor you use is a question of who closes what:

```dart
AppDatabase.borrow(connection);   // you opened the connection, you close it
AppDatabase.withPool(pool);       // you opened the pool, you close it
await AppDatabase.open(config);   // it owns the connection; await db.close()
```

A pooled database takes a lease per statement and holds one lease for the
whole of a `transaction` callback, which is why it keeps the pool rather than
only the pool's session.

The driver loads its native libraries on the first connection, so
`MssqlRuntime.instance.initialize()` is optional in a Dart program. In a
Flutter application call it in `main()` before `runApp`, so no widget can
reach an uninitialized runtime. Encryption and certificate trust are the
driver's to configure; see its
[TLS guide](https://github.com/Aksoyhlc/mssql_native/blob/main/doc/TLS.md).

One setting has to agree on both sides: `decimal_mode` in the generator
configuration and `decimalMode` on `MssqlConnectionConfig`. Generated code
that expects `MssqlDecimal` and a connection handing out `double` is a
mismatch nothing else will catch.

## Generating the ORM

The database is the source of truth. You do not write migrations; you change
the schema and run the generator, and three read-only commands tell you when
the Dart and the database have drifted apart.

### 1. Lay out the project

```bash
dart run mssql_orm_dev:init
```

`init` writes only what is missing and overwrites nothing:

| Path | What it is |
|---|---|
| `tool/mssql_orm.yaml` | the configuration, below |
| `lib/db/generated/` | rewritten by every run — never edit |
| `lib/db/models/` | your row subclasses, created once |
| `lib/db/extensions/` | your named scopes, created once |
| `lib/db/queries/` | your hand-written `.sql` files, with one example |
| `.gitignore` entries | the generator's crash-recovery artifacts |

### 2. Configure

```yaml
connection:
  from: env:MSSQL_CONNECTION_STRING   # or host/port/database/user/password
output: lib/db/generated
extensions_output: lib/db/extensions
models_output: lib/db/models
snapshot: tool/mssql_schema.json
queries_input: lib/db/queries
database_class: AppDatabase
decimal_mode: exact                   # exact | text | double
schemas: [dbo]
```

Any connection value may be written as `env:NAME` and read from the
environment instead of the file; a password written into the file is reported
as a warning on every run. `connection.from` is a whole .NET connection
string and cannot be combined with the individual keys.

Everything else is optional, and this is the part worth knowing before the
first run:

```yaml
include: ['dbo.Orders', 'dbo.Order*']   # or exclude:; include_views: true
class_names:
  dbo.Orders: Order                     # OrderRow / OrderQuery / OrderFields
field_names:
  dbo.Orders.PlacedAt: placedOn
query_methods:
  dbo.Orders.Status: withStatus         # renames the generated whereStatus
soft_delete_columns:
  dbo.Orders: DeletedAt
timestamps:
  dbo.Orders: { created: CreatedAt, updated: UpdatedAt }
hierarchy_parents:
  dbo.Employees: ManagerId              # which self-reference is the parent
enum_columns:
  dbo.Orders.Status:
    dart: OrderStatus
    import: package:app/order_status.dart
    unknown: error                      # or member / wrap
converters:
  dbo.Orders.Amount:
    dart: Money
    converter: MoneyConverter
    import: package:app/money.dart
readonly_columns: ['*.RowVersion']
hidden_columns: ['dbo.Users.PasswordHash']
projections:
  OrderListItem:
    table: dbo.Orders
    fields: [Id, Code, Total, {path: Customer.Name, alias: CustomerName}]
```

`include` and `exclude` are the only keys that take a pattern — `*` stands for
any run of characters, and `exclude` wins over `include`. `readonly_columns`
and `hidden_columns` accept the single form `*.Column`. Everything else names
one table, column or relation exactly, with or without its schema and in any
case; there is no `class_names: 'dbo.*'`. The
[generation reference](doc/GENERATION.md#how-names-are-matched) has the table.

Three rules hold for the whole file, so that a configuration cannot quietly
stop taking effect:

- A key that matches no selected table or column is an error, not a no-op. A
  `class_names` entry for a table you later excluded fails the run.
- A key the generator does not read is an error, and the message names the
  closest key it does read. `outut:` does not silently leave `output` on its
  default.
- A value of the wrong type is an error. `scaffold: ture` stops the run
  instead of meaning `false`.

Conventions the generator detects on its own — `deleted_at` soft deletes,
created/updated timestamps — are reported as warnings when they are applied,
and `soft_delete_columns: dbo.Orders: false` opts a table out. A `tenant_id`
column is never turned into a tenant scope by itself.

### 3. Point it at a database

```bash
export MSSQL_CONNECTION_STRING='Server=localhost;Database=app;User Id=sa;Password=…'
dart run mssql_orm_dev:doctor
```

`doctor` is local by default: SDK, native assets, TLS, the configuration, the
output directories and the generated API contract version, with what to do
about anything that failed. `doctor --connect` also opens the database.

Generation connects in plaintext unless `connection.encrypt` asks for
`request`, `require` or `strict`. Because FreeTDS decides certificate trust
once per process, the generator reads `MSSQL_TLS_CA`, `MSSQL_TLS_SYSTEM=1` or
`MSSQL_TLS_INSECURE=1` for its own connection rather than a key in the file.

### 4. Generate

```bash
dart run mssql_orm_dev:snapshot     # record the schema as JSON
dart run mssql_orm_dev:generate
```

| Option on `generate` | What it does |
|---|---|
| `--dry-run` | prints create / replace / remove / unchanged, writes nothing |
| `--check` | the same plan, and a non-zero exit if the output would change |
| `--only TABLE` | limits the run to named tables; does not sweep for stale files |
| `--snapshot` | generates from `tool/mssql_schema.json`, with no live database |
| `--report json` | the whole plan as one JSON object |

Committing the snapshot means a checkout can generate — and a CI job can
verify — without a database or a password. `generate` falls back to it on its
own when the connection environment variables are unset.

Stale files are removed only when the generation manifest records them as
generated. A hand-written file in the output directory is left alone.

### 5. Then, in the application

```dart
import 'package:app/db/generated/generated.dart';

final db = await AppDatabase.open(config);
final orders = await db.orders.whereStatus('open').get();
```

### 6. Keep the two in step

| Question | Command |
|---|---|
| Is the generated Dart stale against the schema? | `generate --check` |
| Did a live table move since it was generated? | `check_schema` |
| Did a hand-written `.sql` file's result shape move? | `verify_queries` |

All three write nothing and exit `1` on a drift finding, which is what makes
them CI steps; a configuration or database failure gets its own exit code
instead. Command names use underscores: `check_schema`, not `check-schema`.

Generated files stamp the API contract version they were written against, and
the runtime refuses a binding from a different one rather than misreading it.

[`doc/GENERATION.md`](doc/GENERATION.md) is the complete reference.

## The query builder

The builder is most useful where the shape of a query changes at runtime, such
as a search screen whose filters are each optional.

```dart
import 'package:mssql_orm/query.dart';

final page = MssqlQuery.from('dbo.Orders', as: 'o')
    .innerJoin('dbo.Customers', as: 'c', on: Col('o.CustomerId').eqCol('c.Id'))
    .where(Col('o.DeletedAt').isNull())
    .when(term != null && term.trim().isNotEmpty,
        (q) => q.where(whereAny(['o.Code', 'c.Name'],
            (column) => column.contains(term!))))
    .whenNotNull(since, (q, from) => q.where(Col('o.PlacedAt').gte(from)))
    .when(statuses.isNotEmpty, (q) => q.where(Col('o.Status').inList(statuses)))
    .select([Col('o.Id'), Col('o.Code'), Col('c.Name').as('Customer')])
    .orderBy([Col('o.PlacedAt').desc(), Col('o.Id').desc()])
    .paged(offset: 0, rows: 25);

final rows = await page.get(session);
```

A filter that was not filled in adds nothing to the SQL. There is no
`AND 1 = 1`, and the server sees one statement shape per combination that
actually occurred rather than one per combination that might.

Queries are immutable, so a base query can be shared and branched from:

```dart
final base = MssqlQuery.from('dbo.Orders').where(Col('Status').eq('open'));
final total = await base.countRows().get(session);
final first = await base.top(10).get(session);
```

Compile it yourself when you want to inspect or reuse the SQL. Pass both
halves of the result; using only `.sql` discards the bound values:

```dart
final statement = page.compile();
final rows = await session.queryRows(
  statement.sql,
  parameters: statement.parameters,
);
```

Joins, `GROUP BY` and `HAVING`, aggregates, `DISTINCT`, `TOP`, `UNION`, CTEs
including recursive ones, window functions, scalar and `EXISTS` subqueries,
`INSERT`, `UPDATE`, `DELETE`, upsert, locking hints, `CASE`, date bucketing
and keyset chunking all compose.

### Refusals

Some SQL is legal but almost never intended. The builder rejects it while the
query is being constructed, before anything is sent:

```dart
Col('Note').eq(null);                      // ArgumentError: `= NULL` is never true
Col('Status').inList([]);                  // ArgumentError: an empty IN list
q.paged(offset: 0, rows: 10);              // StateError: paging without orderBy
MssqlUpdate.table('dbo.Orders').set({…});  // StateError: a write with no predicate
```

`allRows()` is the explicit opt-in for a write that really should affect every
row. A statement carrying both `where()` and `allRows()` is refused, because
the two contradict each other.

Raw SQL remains available:

```dart
q.where(MssqlRaw('o.Total > dbo.fn_Threshold(@id)', {'id': 7}));
```

A statement containing a raw fragment is marked as such, and the runtime stops
treating it as a provably read-only statement, so the driver will not repeat
it after a lost connection.

## The generated API

For each table the generator writes a row class, a fields class of typed
columns, a query class with a `whereX` method per column, create and patch
inputs, relations inferred from foreign keys, and the entries that make up
`AppDatabase`. A barrel file covers the whole database in one import:

```dart
import 'package:app/db/generated/generated.dart';
```

Names like `OrderQuery`, `whereStatus` and `OrderRowBaseCreate` are examples.
Your schema and the `class_names` configuration determine the real ones.

Row subclasses and query scopes live in `models_output` and
`extensions_output`, which are created once and never rewritten, so what you
add to them survives every regeneration. `output` is rewritten in full on
every run and belongs to the generator alone.

## Reads

A generated query keeps its concrete type through the whole chain, so your own
extension methods remain available at the end of it.

```dart
final one       = await db.orders.whereId(42).first();        // null if absent
final mustExist = await db.orders.whereId(42).firstOrFail();  // throws if absent
final only      = await db.orders.whereCode('SO-1').single(); // throws if several
final all       = await db.orders.whereStatus('open').get();
final count     = await db.orders.whereStatus('open').count();
```

Both paging styles require deterministic ordering:

```dart
final offsetPage = await db.orders
    .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
    .page(size: 50, total: true);

final cursorPage = await db.orders
    .orderBy((o) => [o.id.asc()])
    .cursorPage(size: 50);
```

`page` gives rows, `hasMore` and an optional total. `cursorPage` uses keyset
paging, which stays stable while rows are inserted.

For results too large to hold in memory, `chunk`, `lazy` and `stream` walk
them in bounded batches. `watch` re-runs a query when the tables behind it may
have changed.

Optional filters have dedicated forms, so a search screen does not become a
chain of `if` statements:

```dart
final results = await db.orders
    .search(term, (o) => [o.code])
    .whereIfNotNull(from, (o, value) => o.placedAt.gte(value))
    .whereInIfNotEmpty(statuses, (o, list) => o.status.inList(list))
    .get();
```

A projection returns a typed object instead of a full row, and selects only
the columns it needs:

```dart
final items = await db.orders.select(OrderListItem.projection).get();
final pairs = await db.orders.select2<int, String>((o) => (o.id, o.code)).get();
```

## Relations

Relations are generated from foreign keys: `belongsTo`, `hasOne`, `hasMany`,
`belongsToMany`, `hasOneThrough` and `hasManyThrough`, plus the polymorphic
`morphTo`, `morphOne` and `morphMany`.

Loading is explicit and batched. One query runs per relation level, never one
per parent row:

```dart
final orders = await db.orders
    .include((o) => [o.customer.asInclude, o.lines.asInclude])
    .get();
```

Two conditions that are easy to miss are reported rather than absorbed:

- Reading a relation that was not included throws
  `MssqlRelationNotLoadedException`. It does not issue a lazy query and it does
  not read as empty.
- An include that reached its configured row ceiling throws
  `MssqlRelationTruncatedException` instead of returning a partial list.

## Writes

Writes use create and patch inputs rather than a mutable row. That is what
makes "leave this column alone" and "set this column to NULL" two different
statements.

```dart
final order = await db.orders.create(OrderRowBaseCreate(
  customerId: 7,
  code: 'SO-2026-1001',
  status: 'open',
  total: MssqlDecimal.parse('1499.90'),
));
```

`create` returns the stored row, including the identity and any server
defaults. Identity, computed, `rowversion` and read-only columns are absent
from the input, because the server owns them.

A column that is nullable and also has a SQL `DEFAULT` is a `Field`, since for
that combination omitting the value and setting it to null are different
writes:

```dart
OrderRowBaseCreate(note: const Field.absent());     // the DEFAULT applies
OrderRowBaseCreate(note: const Field.value(null));  // NULL is written
```

A patch is `Field` throughout, for the same reason:

```dart
await db.orders.whereId(order.id).whereStatus('open').update(
  const OrderRowBasePatch(status: Field.value('closed')),
  expectAffected: 1,
);
```

`expectAffected` turns the update into a compare-and-set. The guard is in the
`WHERE`, the expectation is on the row count, and a mismatch raises
`MssqlAffectedRowsException` and rolls the write back.

Bulk and graph writes are separate methods:

```dart
await db.orderLines.createMany(lines);
await db.orders.createGraph(orderInput, lines: lineInputs);
```

`createMany` uses one multi-row statement unless a strategy asks for bulk
copy. `createGraph` inserts a parent and its children in one transaction, and
does not imply cascade delete.

## Transactions

```dart
final id = await db.transaction((tx) async {
  final order = await tx.orders.getById(42);
  await tx.orders.whereId(order.id).update(
    const OrderRowBasePatch(status: Field.value('processing')),
  );
  return order.id;
});
```

`tx` is the same `AppDatabase` type, bound to the transaction. Tables,
`reports` and `procedures` are all available on it, so a function that takes an
`AppDatabase` behaves the same inside and outside a transaction.

A connection-backed database opens a transaction on its connection. A pooled
one holds a single lease for the whole callback. A nested call becomes a
savepoint. A session that cannot open a transaction is rejected rather than
run without one.

## Scopes, soft deletes and timestamps

The generator detects these conventions and the runtime applies them without
being asked each time.

```dart
await db.orders.get();                  // soft-deleted rows excluded
await db.orders.withTrashed().get();    // included
await db.orders.onlyTrashed().get();    // only those
```

Created and updated timestamps are stamped from the server clock on write.
Tenant predicates, optimistic concurrency and relation load limits work the
same way.

Your own named filters live in an extension file that the generator creates
once and never overwrites:

```dart
extension OrderScopes on OrderQuery {
  OrderQuery open() => whereStatus('open');
}

await db.orders.open().get();
```

The runtime resolves the server dialect once through a shared capability
cache. Passing an explicit dialect pins it; otherwise nothing assumes a newer
SQL Server's paging syntax.

## Custom SQL

A `.sql` file under `queries_input` becomes a typed method. The result shape
is described by SQL Server, or declared by hand where the server cannot
describe it.

```sql
-- lib/db/queries/category_trend.sql
-- name: categoryTrend
-- param: rootId int
-- param: since datetime2
-- returns: list
WITH tree AS (…) SELECT … WHERE c.RootId = @rootId AND o.PlacedAt >= @since;
```

```dart
final rows = await db.reports.categoryTrend(rootId: 1, since: month);
```

These methods use the same session, transaction, dialect and observer as
generated table queries.

## Error handling

Everything this layer refuses has its own type, all extending
`MssqlOrmException`:

| Exception | Raised when |
|---|---|
| `MssqlRowNotFoundException` | `firstOrFail` or `getById` found nothing |
| `MssqlCardinalityException` | `single` matched more than one row |
| `MssqlAffectedRowsException` | `expectAffected` did not hold; the write was rolled back |
| `MssqlConcurrencyException` | an optimistic-concurrency guard failed |
| `MssqlRelationNotLoadedException` | a relation was read without being included |
| `MssqlRelationTruncatedException` | an include reached its row ceiling |
| `MssqlUnsafeWriteException` | a write with no predicate and no explicit opt-in |
| `MssqlUniqueConflictException` | a unique index rejected the row |
| `MssqlUnexpectedNullException` | a non-null column returned null |
| `MssqlCapabilityException` | the target SQL Server cannot do what was asked |
| `MssqlReadbackUnavailableException` | the stored row cannot be read back |

Database-level failures keep their `mssql_native` types, such as
`MssqlConstraintException` and `MssqlQueryTimeoutException`, so one handler
can cover both layers.

## Documentation

| | |
|---|---|
| [ORM examples](doc/EXAMPLES_ORM.md) | the generated API, end to end |
| [Query builder examples](doc/EXAMPLES_QUERY_BUILDER.md) | every clause, with the SQL it produces |
| [Advanced examples](doc/EXAMPLES_ADVANCED.md) | five worked screens: search, detail, report, tree, write flow |
| [API guide](doc/API.md) | what the generated names mean |
| [API contract](doc/API_CONTRACT.md) | the naming rules the generator and runtime share |
| [Architecture](doc/ARCHITECTURE.md) | compilation, execution and relation loading |
| [Capabilities](doc/CAPABILITIES.md) | what compiles to what, per dialect |
| [Generation](doc/GENERATION.md) | what the generator produces and what you own |

[`example/advanced_examples.dart`](example/advanced_examples.dart) renders the
SQL this package builds for five realistic screens, and runs without a server:

```bash
dart run example/advanced_examples.dart
```

The package also ships `skills/mssql-orm-usage/SKILL.md` for compatible AI
coding agents.

## Related packages

- [`mssql_native`](https://pub.dev/packages/mssql_native) — the SQL Server
  driver this runs on. Required.
- [`mssql_orm_dev`](https://pub.dev/packages/mssql_orm_dev) — the generator.
  A development dependency, and optional: the query builder needs no
  generation.

The three packages are versioned and released together.

## License

MIT. See [LICENSE](LICENSE).
