# Public API — mssql_orm

User-facing semantics for the generated `AppDatabase` and the query builder.
Names match what the generator actually emits. The binding contract is
[API_CONTRACT.md](API_CONTRACT.md).

Application import:

```dart
import 'package:myapp/db/generated/database.g.dart';
import 'package:myapp/db/generated/generated.dart';
```

Generator support (`MssqlTableBinding` construction, `rebuild`) is
`package:mssql_orm/generation.dart`. Do not start there.

## Naming the generator emits

`class_names` sets the **stem**. For `dbo.Orders: Order`:

| Kind | Type |
|---|---|
| Row (scaffold) | `OrderRow` extends `OrderRowBase` |
| Query | `OrderQuery` |
| Fields (callback `o`) | `OrderFields` |
| Insert input | `OrderRowBaseCreate` |
| Patch | `OrderRowBasePatch` (`Field<T>`) |
| Unique | `OrderUnique` |
| Column statics | `Order` — typed expression handles (`Order.id`, `Order.code`) |
| Table getter | `db.orders` |

The suffix-free `Order` type is that statics holder: column handles for
building expressions, not a row or a repository. There is no suffix-free row
class and no `OrdersRepository` app type on the getting-started path;
`*RepositoryBase` still exists for generated write machinery, call it through
`OrderQuery`.

## Construction vs compile vs execute

| When | What fails | Kind |
|---|---|---|
| Analyzer | unknown method, wrong type on `OrderRow` / `OrderQuery` | Dart **build-time** |
| Building a query / `compile()` | `eq(null)`, empty `inList`, page without order, write without predicate | Dart **runtime** (`ArgumentError` / `StateError` / `MssqlUnsafeWriteException`) |
| Running SQL | server / driver | `MssqlException` subtypes |
| Terminals | empty/many rows, affected count, version, capability | ORM exceptions below |

`YEAR` / `MONTH` helpers (`whereYear`, `whereMonth`) compile to date-part
expressions. They are not a performance feature. Use `inYear` / `onDate`
when you want a sargable range. No speed-up is claimed for either.

## Read terminals

| Method | Result | Zero rows | Many rows |
|---|---|---|---|
| `get()` | `List<R>` | `[]` | all matches, no hidden limit |
| `first()` | `R?` | `null` | first in the requested order |
| `firstOrFail()` | `R` | `MssqlRowNotFoundException` | first |
| `single()` | `R` | `MssqlRowNotFoundException` | `MssqlCardinalityException` |
| `singleOrNull()` | `R?` | `null` | `MssqlCardinalityException` |
| `find(key)` | `R?` | `null` | — |
| `getById(key)` | `R` | `MssqlRowNotFoundException` | — |
| `count()` | `int` | `0` | **result row** count (`countRows()` under the hood) |

`first` / `page` without an order fall back to the primary key. A keyless
source is refused:

```dart
final page = await db.orders.page(size: 25); // ORDER BY [Id] added for you
```

There is no `exists()` terminal on the ORM query. Use `count()` or the query
builder's `q.exists(session)` (see the
[QB cookbook §1.6](EXAMPLES_QUERY_BUILDER.md#16-one-value-in-one-round-trip)).

Query-builder counterparts on `MssqlQuery`: `countRows()`,
`countDistinct(...)`, `aggregateRows(...)`. There is no `selectCount()`.

## Page, cursor, stream, watch

```dart
final page = await db.orders
    .whereStatus('open')
    .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
    .page(size: 25, offset: 0, total: true);
```

- `hasMore` is answered by fetching one extra row and dropping it.
- `total` is computed only when `total: true`.
- `MssqlReadConsistency.snapshot` runs the page (and optional total, and
  includes) in one SNAPSHOT transaction.
- The page, its total and its includes share **one scope snapshot**. A
  tenant or user scope is a factory (`MssqlCondition? Function()`), and it
  is called once per terminal, not once per statement, so two halves of one
  page cannot land on two tenants across an `await`. Same for `chunkById`
  across all its chunks, and for a batch write across all its batches.

`cursorPage` is keyset pagination. Nullable cursor columns need an explicit
`MssqlNulls` policy.

`stream()` maps native row batches. Cancel the subscription to cancel the
native operation.

With `include` it is a **keyset walk** of `parentBatch` parents instead: a
session runs one operation at a time, so an include query cannot be issued
while a row stream is still open — it would queue behind a stream that
cannot finish until the consumer takes the next row. Memory stays bounded
to one batch plus its children, and this path orders by the primary key.

`watch(strategy:, interval:, tables:)` re-runs the query.

| Strategy | Sees |
|---|---|
| `MssqlWatchStrategy.localWrites` (default) | committed writes on this `AppDatabase` family |
| `MssqlWatchStrategy.polling` | those, plus external writers after `interval` |

There is no CDC / change-tracking push.

## Writes

| Method | Meaning |
|---|---|
| `create(OrderRowBaseCreate)` | one insert; returns the stored row |
| `createMany(..., {strategy})` | batched insert; `insertValues` or `bulkCopy` |
| `createGraph(...)` | explicit graph, one transaction — not a cascade save |
| `update(OrderRowBasePatch, {expectAffected, expectedVersion})` | filtered update |
| `delete({expectAffected})` | soft delete when configured |
| `forceDelete()` | bypasses only the soft-delete filter |
| `restore()` | only rows that are soft-deleted |
| `getOrCreate` / `getOrCreateByCode` | insert-first; 2627/2601 then read the winner |
| `updateMany(byKey)` | staging-join update, one row per key |
| `decrementQuantities` | grouped stock decrement |
| `descendantsOf(root)` | generated when the table walks itself through one self-FK |

A user predicate is required. A global scope does not count.
`allRows()` is the explicit whole-table opt-in.

Batch writes carry the query's scopes. `updateMany` and
`decrementQuantities` reach exactly the rows a single-row `update()` on the
same query would: not another tenant's, and not a soft-deleted one unless
`withTrashed()` asked for it. `createMany` and `createGraph` apply none,
because an insert has no `WHERE` to apply one to — a tenant column on a new
row belongs in the Create values.

`updateMany` groups patches by which columns they name, so a column one
patch leaves absent is never written as NULL for that row, and a `DEFAULT`
stays the target's own default. Two patches for the same row are refused: a
staging join would apply both in no defined order.

```dart
OrderRowBaseCreate(
  customerId: 1,
  code: 'A-1',
  status: 'open',
  total: MssqlDecimal.parse('10.00'),
  placedAt: MssqlDateTimeValue.fromDateTime(DateTime.now().toUtc()),
) // omitted defaulted cols → SQL DEFAULT
OrderRowBasePatch()                             // leave columns alone
OrderRowBasePatch(note: Field.value(null))      // set NULL
```

`expectAffected` → `MssqlAffectedRowsException`. `expectedVersion` matching
zero rows → `MssqlConcurrencyException` (doomed session is not retried).
Retry is `MssqlRetryPolicy.never` for writes, procedures and arbitrary SQL.

## Relations

```dart
final page = await db.orders.whereId(id).include(
  (o) => [
    o.customer.asInclude,
    o.lines
        .ordered([OrderLine.id.asc()])
        .takePerParent(20)
        .then(OrderLineRel.product.then(ProductRel.category))
        .asInclude,
  ],
);
```

Statement count grows with depth and `takePerParent`, not “always N
queries”. Unloaded getters throw `MssqlRelationNotLoadedException`.
Truncation throws `MssqlRelationTruncatedException`.

`whereHas` / `withCount` / `withAggregates` compile to `EXISTS` /
`COUNT_BIG` subqueries. Relation writes (`create` / `associate` / `attach`
/ `sync`) take a transaction and do not cascade.

Relation aggregates are typed, and the type parameter is unbounded:

| Call | Result |
|---|---|
| `withCount((o) => o.lines)` | `(OrderRow, int)` |
| `withExists((o) => o.lines)` | `(OrderRow, bool)` |
| `withSum<OrderLineRow, MssqlDecimal>(…, operand)` | `(OrderRow, MssqlDecimal?)` |
| `withMin<…, V>` / `withMax<…, V>` | `(OrderRow, V?)` |
| `withAvgExact(…)` | `(OrderRow, MssqlDecimal?)` |
| `withAvgTruncating<…, V>(…)` | `(OrderRow, V?)` |

`V extends num` would read as the safe bound and would be the lossy one:
`MssqlDecimal` is not a `num`, so it would push an exact column's sum
through `double`. A `V` the value cannot become is an error naming the
aggregate, never a rounded answer. `AVG` of an integer column is integer
division in SQL Server, which is why the two averages are separate methods
rather than a flag whose result type the caller cannot see.

Use `.ordered` for include sort. `MssqlRelation.orderBy` is a field.

## Procedures and custom SQL

Generated `db.reports.*` and `db.procedures.*` run on the same session as
`db.orders`. Cardinality follows `-- returns:` (`list` / `single` /
`single_or_null` / `scalar` / `affected`). Extra result sets are typed when
declared. TVP parameters use `MssqlTableRows`.

`sp_describe_first_result_set` sees the first shape only. Temporary tables,
variable `EXEC`, and varying first result sets need `-- describe: manual`.
That is a declared shape, not a server-verified analysis.

## NULL, default, unloaded

| Situation | What it is |
|---|---|
| SQL NULL on a nullable Dart field | `null` |
| unexpected SQL NULL on a non-null field | `MssqlUnexpectedNullException` |
| omitted Create field with a default | server DEFAULT; not Dart null |
| relation getter, not included | `MssqlRelationNotLoadedException` |
| include hit `maxLoadedRows` / `takePerParent` | `MssqlRelationTruncatedException` |
| `affected` vs `OUTPUT` vs `@@ROWCOUNT` | see `MssqlAffectedRowsSource` on the write engine |

## Resources

| Constructor | Ownership |
|---|---|
| `AppDatabase(session)` / `.borrow(connection)` | borrowed |
| `AppDatabase.withPool(pool)` | borrowed pool |
| `AppDatabase.open(config)` | owned connection; `await close()` once |
| `AppDatabase.openPool(config)` | owned pool; `await close()` once |

`close()` is async and closes only what the database opened. A borrowed
connection or pool is the caller's to close.

`db.transaction` opens a real transaction in all three cases: on the
connection, on one lease taken from the pool for the whole callback, or —
when the database is already inside a transaction — on a savepoint of it.
A session that can do none of those is refused rather than run without a
transaction.

`db.query(select)` / `db.execute(statement)` run a hand-built statement
inside the same observer, dialect cache and transaction. The dialect
defaults to whatever the server actually is, resolved once through the
same capability cache the generated table queries use; pass `dialect:` to
pin it.
