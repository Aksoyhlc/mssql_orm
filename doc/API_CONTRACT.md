# mssql_orm — public API contract

This file fixes the names and the meaning of every user-facing type and method
across `mssql_native`, `mssql_orm` and `mssql_orm_dev`. A name written here is
the name the generator emits, the name the runtime declares and the name the
documentation uses; the three cannot drift apart without this file changing
first.

Contract version: `2` (`MssqlApiVersion.current`). Generated code records this
number in its header and the runtime refuses a mismatch, so a tree generated
against version 1 is a build-time error rather than a query that silently
names the wrong table.

Version 2 adds two members to the generator support surface: a query
overrides `recreateAt(context, state, included)` alongside `recreate`, and its
`fields` getter resolves columns against `binding.sourceRef` rather than
returning a fixed constant. Both exist so `at(schema:, table:)` can rebind a
query's table — see section 7.

## 1. Two surfaces, one engine

A user sees two data-access surfaces:

- **Query builder** — `MssqlQuery.from('dbo.Orders').where(...).compile()`
  returns an `MssqlStatement` (`sql` and `parameters`). Run both; do not
  pass `.sql` alone.
- **ORM** — a generated `AppDatabase` whose table getters return immutable,
  concretely typed queries.

Both build the same AST, run through the same compiler and execute on the same
`MssqlSession`. There is no second SQL compiler and no third query system: the
generator is a development-time dependency that emits Dart against these two
surfaces.

`db.query(selectQuery)` and `db.execute(statement)` run a hand-built query
through the ORM's session and dialect resolution. Table scopes and the
entity-mapping observer belong to generated table queries; they are not
applied to hand-built rows. Raw SQL stays reachable through the session API.

## 2. Naming

| Concept | Name | Notes |
|---|---|---|
| Database entry point | `AppDatabase` (configurable) | `db.orders`, `db.customers`, `db.reports`, `db.procedures` |
| Read model | `{Stem}Row` e.g. `OrderRow` | `class_names: dbo.Orders: Order` sets the stem; SQL nullability preserved |
| Table query | `{Stem}Query` e.g. `OrderQuery` | Concrete type preserved along the whole chain |
| Callback fields | `{Stem}Fields` e.g. `OrderFields` | Typed SQL columns, not a row |
| Insert input | `{Stem}RowBaseCreate` e.g. `OrderRowBaseCreate` | Optional defaulted columns are `T?` so they can be omitted |
| Partial update | `{Stem}RowBasePatch` | `Field<T>.absent()` vs `Field<T>.value(v)` |
| Unique match | `{Stem}Unique.code(value)` | Only from real unique metadata |
| Exact number | `MssqlDecimal` | BigInt coefficient + scale, in the driver |
| Projection | `MssqlProjection<R>` / `MssqlProjectedQuery<R>` | Generated DTO or typed record |
| Page | `MssqlPage<R>` / `MssqlCursorPage<R>` | |
| Session | `MssqlSession` | Connection, transaction and pool all implement it |
| Execution settings | `MssqlQueryOptions` | `.options(o)` on the ORM |
| Compiled SQL | `MssqlStatement` | `sql`, `parameters`, raw-SQL classification |
| Window / CTE | `MssqlWindow*`, `MssqlTypedCte`, `MssqlHierarchy` | Exported from `query.dart` / `orm.dart` |
| Exists / calendar | `MssqlExistsValue`, `MssqlCalendarRange` | `existsValue`, `inYear`, `onDate` |
| Typed SQL | `MssqlSqlType`, `MssqlTypedExpression`, `MssqlStableExpression` | `caseWhen`, `coalesce`, `dateBucket` |

### Replaced names

The packages have no external consumers yet, so generated application code
uses the current names without compatibility aliases. `MssqlRepository`
remains public as generator/runtime machinery, but generated table queries are
the application-facing entry point.

| Old public name | Replacement |
|---|---|
| Direct `MssqlRepository<TRow, TKey>` application access | Generated `OrderQuery`; generated `*RepositoryBase` may still extend `MssqlRepository` internally |
| `OrdersRow` without `class_names` | `{Stem}Row`; stem from table or `class_names` |
| `OrdersRepository` as the app type | `{Stem}Query`, reached as `db.orders` |
| `Order` / `OrderCreate` nicknames | `OrderRow` / `OrderRowBaseCreate` (what the emitter writes) |
| `selectCount()` | `countRows()` / entity `count()` |
| DML `whereAll()` | `allRows()` (`whereAll` remains the AND-of-columns combinator) |
| `MssqlExecutor` / `MssqlConnectionExecutor` / `MssqlTransactionExecutor` | `MssqlSession`; the ORM adapter is a thin delegation |
| `repository.findById` | `find` |
| `repository.findAll` | `get` |
| `repository.findWhere(cond)` | `where((f) => …).get()` |
| `repository.firstWhere` | `first` / `firstOrFail` |
| `repository.firstOrCreate` / `createOrFirst` | `getOrCreate(key:, create:)` and generated `getOrCreateByCode(…)` |
| `repository.insert(row)` | `create(OrderRowBaseCreate…)` |
| `repository.insertAll` | `createMany` |
| `repository.update(row, columns:)` | `update(OrderRowBasePatch…, expectAffected:)` |
| `repository.updateOne` | `update(patch, expectAffected: 1)` |
| `repository.withoutGlobalScopes()` | `withoutScopes()` |
| `MssqlConnection.decimalAsDouble` (bool) | `MssqlDecimalMode` enum |
| `page(...)` returning positional args | `page(size: 25, offset: 0, total: false)` |

## 3. Read terminals

| Method | Rows matched | Result | Zero rows | Many rows |
|---|---|---|---|---|
| `get()` | all | `List<R>` | `[]` | all rows, no hidden limit |
| `first()` | first in the requested order | `R?` | `null` | first row |
| `firstOrFail()` | first in the requested order | `R` | throws `MssqlRowNotFoundException` | first row |
| `single()` | exactly one | `R` | throws `MssqlRowNotFoundException` | throws `MssqlCardinalityException` |
| `singleOrNull()` | at most one | `R?` | `null` | throws `MssqlCardinalityException` |
| `find(key)` | by primary key | `R?` | `null` | — |
| `getById(key)` | by primary key | `R` | throws `MssqlRowNotFoundException` | — |
| `count()` | — | `int` | `0` | count of **result rows** (`countRows()`) |

`first` requires an ordering to be meaningful; without one, `page`/`first` fall
back to the entity's primary key order and a keyless source is rejected.
`single` is a cardinality assertion, not "first row". The same distinction holds
in the driver, in generated custom-SQL methods and in generated procedures.

There is no `exists()` terminal on the ORM query; the boolean probe is the
query builder's `q.exists(session)`.

## 4. Write surface

| Method | Meaning |
|---|---|
| `create(OrderRowBaseCreate)` | One insert; returns the stored row |
| `createMany(List<OrderRowBaseCreate>, {strategy})` | Batched insert; `insertValues` or `bulkCopy` |
| `createGraph(…)` | Explicit relation graph insert, one transaction |
| `update(OrderRowBasePatch, {expectAffected, expectedVersion})` | Filtered update |
| `delete({expectAffected})` | Soft delete when configured, otherwise a real delete |
| `forceDelete()` | Bypasses only the soft-delete filter |
| `restore()` | Only rows that are soft-deleted |
| `increment(f, by:)` / `decrement(f, by:)` | Typed arithmetic on one column |
| `getOrCreate(key:, create:)` | Race-safe on a real unique key |

An update or delete without a user predicate is refused; a scope does not count
as one. `allRows()` is the explicit opt-in for whole-table writes.

`Field<T>` distinguishes three things that must never collapse into each other:

```dart
OrderRowBasePatch()                                    // leave the column alone
OrderRowBasePatch(note: Field<String?>.value(null))    // set it to NULL
OrderRowBaseCreate(
  customerId: 1,
  code: 'A-1',
  status: 'open',
  total: MssqlDecimal.parse('10.00'),
  placedAt: MssqlDateTimeValue.fromDateTime(DateTime.now().toUtc()),
)                                                       // omitted defaulted cols → SQL DEFAULT
```

## 5. Predicates

- Comparisons: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `inList`, `between`,
  `isNull`, `isNotNull`. No synonym families.
- Column shortcut: exactly one `whereX(nonNullValue)` per queryable column,
  ANDed into the query. No `whereXAndY`, no column × operator product.
- Grouping: `MssqlCondition operator &` and `operator |`, always parenthesised.
  Dart's `&&`, `||` and `==` are not part of the DSL.
- `eq(null)` is an error; NULL needs `isNull` / `isNotNull`.
- `inYear` / `onDate` compile to half-open ranges on the bare column
  (sargable). `whereYear` / `whereMonth` / `whereDay` compile to date-part
  expressions. They are not the same SQL and are not a performance feature.

## 6. Concrete query typing

```dart
abstract class MssqlEntityQuery<R, F, S extends MssqlEntityQuery<R, F, S>> {
  S where(MssqlCondition Function(F fields) predicate);
  S rebuild(MssqlQueryState state);
  Future<List<R>> get();
}
```

`OrderQuery extends MssqlEntityQuery<OrderRow, OrderFields, OrderQuery>`.
Every entity-preserving call returns `S`, so a user extension composes
without losing the type:

```dart
extension OrderScopes on OrderQuery {
  OrderQuery open() => whereStatus('open');
}

final rows = await db.orders
    .where((o) => o.customerId.eq(id))
    .open()
    .whereStatus('open')
    .get();
```

`rebuild` is public (not name-private) because generated code lives in a
separate Dart library and must override it. It is part of the generator support
surface exported from `package:mssql_orm/generation.dart`, not something
an application calls.

No `dynamic`, no `noSuchMethod`, no method names parsed from strings.

## 7. Resources

| Constructor | Ownership |
|---|---|
| `AppDatabase(session)` / `.borrow(connection)` | Borrowed — the caller closes the connection |
| `AppDatabase.withPool(pool)` | Borrowed — the caller closes the pool |
| `AppDatabase.open(config)` | Owned connection — `await db.close()` closes it, once |
| `AppDatabase.openPool(config)` | Owned pool — `await db.close()` closes it, once |

`at(schema:, table:)` returns a new query root over another schema or table
name, with its fields rebound to that source, for a tenant-per-schema
deployment. Relation *targets* are not moved: a foreign key names one table,
and assuming every related table lives in the same tenant schema would be a
guess about the deployment. It has to come first in the chain — a predicate
built before the rebind was built from the old source and would still name it
— and calling it after `where` / `orderBy` / `include` is an error rather than
a statement referring to a source it does not have.

`db.transaction(callback)` hands the callback the same `AppDatabase` type with
a transaction-bound context: identical API, one native lease, every table,
report and procedure getter on that transaction. The context is disposed when
the callback returns; using it afterwards is an error.

There is no case where it runs the callback without a transaction. On a
connection it opens one; on a pool it takes one lease and holds it for the
whole callback, so every statement is on one physical connection; inside an
existing transaction it opens a savepoint, so a failure in the callback rolls
back the callback's writes and leaves the outer scope to its own commit. A
session that can do none of those — the pool's own per-statement convenience
session, say — is refused with an error that names it.

## 8. Defaults

| Setting | Default |
|---|---|
| Decimal | `MssqlDecimalMode.exact` |
| Retry | `MssqlRetryPolicy.never` for arbitrary SQL, procedures and writes |
| Page | `size: 25`, `offset: 0`, `total: false` |
| `get()` | every matching row; no hidden limit |
| Isolation baseline | `READ COMMITTED`, restored on release |
| Result cache | off |

## 9. Errors

Query construction and `compile()` raise Dart runtime errors — they are not
build-time type errors, and the documentation says so. The typed surface is
what turns a class of mistakes into compile errors; the checks below are the
remainder.

| Exception | Raised when |
|---|---|
| `MssqlRowNotFoundException` | `getById`, `firstOrFail`, `single` found nothing |
| `MssqlCardinalityException` | `single` / `singleOrNull` saw more than one row |
| `MssqlAffectedRowsException` | `expectAffected` did not match |
| `MssqlConcurrencyException` | `expectedVersion` matched zero rows |
| `MssqlBindingMismatchException` | Generated binding disagrees with the runtime |
| `MssqlCapabilityException` | The feature needs a newer SQL Server than the target |
| `MssqlRelationNotLoadedException` | An unloaded relation getter was read |
| `MssqlRelationTruncatedException` | Include hit a row ceiling (`takePerParent` / `maxLoadedRows`) |
| `MssqlUnsafeWriteException` | Update/delete without a predicate and without `allRows()` |
