---
name: mssql-orm-usage
description: Use when writing, reviewing, or debugging Dart code that uses the mssql_orm SQL builder or a generated database-first ORM, including typed queries, relations, scopes, paging, writes, transactions, and resource ownership.
---

# Use mssql_orm

Use `package:mssql_orm/query.dart` for runtime-built SQL and the application's
generated database for typed rows and table operations. Keep schema discovery
and source generation in the `mssql_orm_dev` development dependency.

## Start from generated reality

Read [README](../../README.md) and [API](../../doc/API.md). For a generated
application, inspect `tool/mssql_orm.yaml`, `database.g.dart`, the generated
barrel, and the relevant table file before naming a class or method. Schema and
configuration determine names; examples such as `db.orders` and `OrderRowBase`
are not universal.

Generated files are replaceable. Change configuration, models, extensions, or
custom SQL input instead of editing generated output.

## Query-builder pattern

```dart
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/query.dart';

Future<List<Map<String, Object?>>> loadOpenOrders(MssqlSession session) async {
  final statement = MssqlQuery.from('dbo.Orders', as: 'o')
      .select([Col('o.Id'), Col('o.Code')])
      .where(Col('o.Status').eq('open'))
      .orderBy([Col('o.Id').asc()])
      .paged(offset: 0, rows: 25)
      .compile();

  return session.queryRows(
    statement.sql,
    parameters: statement.parameters,
  );
}
```

Always execute both `MssqlStatement.sql` and
`MssqlStatement.parameters`. Compilation allocates bound values; using only the
SQL text loses them.

## Generated ORM pattern

```dart
final rows = await db.orders
    .whereStatus('open')
    .include((o) => [o.customer.asInclude])
    .orderBy((o) => [o.placedAt.desc(), o.id.desc()])
    .get();
```

Adapt every generated identifier after inspecting the consumer's output.

## Preserve runtime invariants

- Build immutable query chains and finish with a documented terminal.
- Include a relation before reading its getter; unloaded relations throw and
  are not lazy-loaded.
- Call `at(schema:, table:)` before predicates, ordering, or includes.
- Use deterministic ordering for paging and cursor traversal.
- Let the shared capability cache resolve the dialect unless the application
  deliberately pins one.
- Preserve query scopes across reads, includes, counts, and batch writes. A
  global scope does not replace the explicit predicate required by a write.
- Treat omitted create/patch fields, explicit SQL `NULL`, and `DEFAULT` as
  different states.
- Keep write predicates and affected-row expectations explicit. Do not replace
  guarded write, trigger readback, concurrency, or transaction failures with a
  fallback.
- Use `db.transaction` when operations must share a transaction. A borrowed
  database does not own its connection or pool; close only resources the
  application created through the database.

For execution boundaries use [architecture](../../doc/ARCHITECTURE.md); check
[capabilities](../../doc/CAPABILITIES.md) before promising streaming, relation,
custom-SQL, or write behavior.
