# Architecture

This document explains how `mssql_orm` works internally and where to
look before changing behavior. Source code is authoritative if another
document disagrees.

## Package boundaries

| Library | Responsibility |
|---|---|
| `lib/query.dart` | Immutable SQL expressions, queries, DML, dialects, and statement compilation |
| `lib/orm.dart` | Runtime used by generated databases, queries, rows, relations, and writes |
| `lib/schema.dart` | SQL Server catalog model, readers, snapshots, and schema comparison |
| `lib/generation.dart` | Generator-facing contracts; application code normally does not import it |

Code generation lives in `mssql_orm_dev`. Transport, native libraries,
connection ownership, and wire values live in `mssql_native`.

## Query compilation

```text
MssqlQuery / generated MssqlEntityQuery
                 |
                 v
 expressions + immutable query state
                 |
                 v
 SQL Server dialect compiler
                 |
                 v
 MssqlStatement(sql, parameters)
```

Identifiers are quoted by the compiler. Values are allocated into the
statement parameter map. Compilation never executes SQL. A standalone builder
caller must pass both statement fields to the driver.

The dialect controls features such as paging syntax. ORM execution resolves
the server dialect through `MssqlCapabilityCache`; an explicitly supplied
dialect is a deliberate pin.

Key source areas:

- `lib/src/query.dart`: immutable SELECT model
- `lib/src/expression.dart`, `predicates.dart`, `operators.dart`: expression tree
- `lib/src/compiler/`: SQL rendering
- `lib/src/statement.dart`: SQL and parameter allocation
- `lib/src/dialect.dart`: SQL Server capability levels

## Generated ORM runtime

A generated `AppDatabase` extends
`MssqlAppDatabase<AppDatabase>`. Each table getter creates a generated query
bound to an `MssqlQueryContext`. The context carries the session, binding,
dialect resolution, clock, scopes, change hub, and observer.

```text
AppDatabase
  -> generated table getter
  -> generated concrete query + fields
  -> MssqlEntityQuery runtime
  -> compile
  -> MssqlSession
  -> row mapper
  -> generated row type
```

Generated queries use a self type. Operations such as `where`, `orderBy`,
`include`, and `withTrashed` therefore preserve generated helpers and
application extensions.

The table binding defines columns, keys, write permissions, mapping, scopes,
timestamps, soft delete, and concurrency metadata. Applications should not
hand-build bindings as their normal entry point.

## Reads and relations

A terminal resolves scopes once for the operation, compiles a statement,
executes it through `MssqlSession`, and maps each `MssqlRow` through the
generated binding.

Includes are explicit post-parent loads. Loaded state keeps these cases
distinct:

- relation not requested: accessor throws
- requested to-one relation with no target: `null`
- requested to-many relation with no targets: empty list
- configured load ceiling reached: truncated accessor throws

Relation filters use correlated `EXISTS`, avoiding parent duplication from a
join. Nested includes retain their own filters, ordering, limits, and
soft-delete selection.

The driver permits one active operation per session. Consequently,
`stream()` with includes uses primary-key keyset batches rather than issuing
relation queries during an open native result stream.

## Writes

Generated create inputs omit server-owned columns. Generated patch inputs use
`Field<T>`:

- `Field.absent()`: do not mention the column
- `Field.value(value)`: assign the value
- `Field<T?>.value(null)`: explicitly clear a nullable column

The write engine compiles guarded INSERT, UPDATE, and DELETE statements and
validates requested affected-row counts. Readback uses SQL Server OUTPUT when
the table and trigger shape make it reliable; unsafe readback is refused.

Bulk and graph writes are explicit strategies. They share binding and scope
rules with single-row writes. Graph creation writes only named relations, runs
transactionally, and never implies cascade deletion.

Key source areas:

- `lib/src/runtime/write_commands.dart`: single-write compilation and readback
- `lib/src/runtime/bulk_write.dart`: batch strategies
- `lib/src/runtime/graph_write.dart`: graph insertion
- `lib/src/runtime/relation_write.dart`: relation mutations
- `lib/src/runtime/concurrency.dart`: unique and concurrency helpers

## Transactions and resource ownership

`MssqlAppDatabase` distinguishes borrowed from owned resources. Closing a
borrowed database is a no-op; closing an owned database closes its connection
or pool once.

Transactions have no silent fallback:

- a connection opens a driver transaction
- a pool lends one physical connection for the whole callback
- an existing transaction nests through a savepoint
- another session implementation is rejected

A transaction database is a fork over the transaction session. It shares
capabilities, observers, and the local-change hub with its parent. Pending
local-write notifications appear only after commit and are discarded after
rollback.

## Schema and generation seam

`lib/schema.dart` models database metadata and deterministic snapshots. The
development package reads a live schema or snapshot and emits the application
layer. The runtime validates the generated API contract version, but it does
not migrate the database.

Generated files and user files have different ownership. Generated output may
be replaced atomically. Model subclasses, extensions, and custom SQL input are
application-owned and must survive regeneration.

## Invariants

1. SQL and values travel together as `MssqlStatement`.
2. Query building is immutable.
3. ORM execution resolves capabilities instead of silently choosing a dialect.
4. Generated types describe the database; runtime code does not guess metadata.
5. A relation is never lazy-loaded by property access.
6. Transactions never degrade to individually committed statements.
7. Borrowed resources are never closed by the ORM.
8. Decimal mode must match between generation and driver.
9. Generated and application-owned files have separate overwrite policies.
10. Unsafe write and readback cases fail explicitly.

## Observability

`MssqlQueryObserver` receives ORM compile, execute, mapping, and relation-load
information. `MssqlObservedSession` can observe direct driver calls.
Parameter redaction is available; sensitive values should not be logged by
default.
