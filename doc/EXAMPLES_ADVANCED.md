# Advanced examples

Five worked examples against the generated sales schema. They are not tests
and they do not talk to SQL Server.

```
dart run example/advanced_examples.dart
```

`RecordingSession` implements `MssqlSession` so generated `AppDatabase` can
run. The SQL it prints is a **rendering** of what this package builds. It is
not evidence that a server accepted the statement or returned these rows.

The generated files under `example/db/` are committed. They are produced from
a declared snapshot rather than a live catalog, by a tool in the
[`mssql_orm_dev`](https://github.com/Aksoyhlc/mssql_orm_dev) repository; only a
maintainer of this suite regenerates them.

`class_names` maps `dbo.Orders` → `Order`, so the owned row is `OrderRow`
rather than `OrdersRow`. Query type is `OrderQuery`; create input is
`OrderRowBaseCreate` (scaffold split). User scopes live in
`example/db/extensions/orders_scopes.dart` (`open()`).

## 1. Search screen

Optional search (null / empty / whitespace add no `LIKE`), optional date and
status, typed `Order` / `Customer` columns, `OrderListItem` projection, stable
`orderBy` + `page(total: true)`.

**INNER JOIN vs LEFT JOIN:** an inner join to `Customers` drops orders whose
customer row is missing. A left join keeps those orders and leaves customer
columns NULL. The two are not the same query.

The ORM side searches `Orders.Code` only: related text columns are not on
`OrderFields` until a join exists. The builder side searches code, customer
name and city together.

## 2. Relations

`include` of `customer`, `lines` (ordered, `takePerParent`), then `product` →
`category`. Statement count grows with include **depth**, through-relations and
`takePerParent` (`ROW_NUMBER`), not with page size. It is not “exactly four
queries at every size”.

## 3. Revenue

`COUNT(DISTINCT order Id)` after joining lines — `COUNT(order Id)` would
count line duplicates. `SUM(LineTotal)` is revenue.

`AVG(UnitPrice)` is the **unweighted mean of line rows**. Quantity-weighted
unit price is `SUM(LineTotal) / SUM(Quantity)`. Those are different numbers.

Date range, cancelled status and `DeletedAt IS NULL` are the same predicates
on the outer query, the last-order subquery and the cancellation `EXISTS`.
Last order is **in-range**, not all-time.

## 4. Category tree and monthly trend

Typed recursive CTE (`MssqlTypedCte`) plus `MssqlHierarchy.descendantsOf`.
**Depth** (`maxDepth` / `Depth <= 4`) filters the result. **MAXRECURSION** is
SQL Server’s runaway guard and fails the query (error 530). Cycle policy
`error` is that guard; `skipVisited` would carry the path instead.

`dateBucket()` needs SQL Server 2022 / compatibility 160 and is refused on
2012. `monthStart()` is `DATEADD`/`DATEDIFF` and needs no version gate.

`db.reports.categoryTrend(rootId:, since:)` is the typed SQL file
(`example/db/queries/category_trend.sql`). `since` is one parameter.

## 5. Writes

One transaction: `getOrCreateByCode`, `OrderRowBaseCreate`, `createMany`
lines, `decrementQuantities` (amounts for the same product key are grouped
into one UPDATE), guarded `whereStatus('open').update(..., expectAffected: 1)`,
archive `INSERT … SELECT`.

Graph insert is a **separate** function (`example5GraphInsertAlternative`) so
the same order is not written twice.
