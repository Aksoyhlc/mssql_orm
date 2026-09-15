# Generation

How `mssql_orm_dev` turns a SQL Server schema into Dart, and what
the application still owns.

Commands use underscores: `generate`, `check_schema`, `verify_queries`,
`snapshot`, `init`, `doctor`. Not `verify-queries` / `check-schema`.

```bash
dart run mssql_orm_dev:init
dart run mssql_orm_dev:doctor
dart run mssql_orm_dev:doctor --connect
dart run mssql_orm_dev:snapshot
dart run mssql_orm_dev:generate
dart run mssql_orm_dev:generate --snapshot   # no live password
dart run mssql_orm_dev:generate --check
dart run mssql_orm_dev:check_schema
dart run mssql_orm_dev:verify_queries
```

`init` writes `tool/mssql_orm.yaml` only when it is missing. It does not
overwrite an existing file, and it never writes a password.

`doctor` is local by default: SDK, native assets, TLS env, config,
generation output. It does not run tests. `--connect` opens the database.

## Offline generate

`generate --snapshot` (and generate when connection env vars are unset)
reads `tool/mssql_schema.json`. Custom `.sql` files still need a matching
`tool/mssql_schema.queries.json` cache or `-- describe: manual`. Missing
env passwords do not block that path.

Live generation is plaintext by default and needs no TLS trust. When
`connection.encryption` explicitly selects `require` or `strict`, configure
process-wide trust with one of:

- `MSSQL_TLS_CA` — PEM bundle path
- `MSSQL_TLS_SYSTEM=1` — system default trust paths
- `MSSQL_TLS_INSECURE=1` — encrypt, verify nothing

## Config

```yaml
connection:
  from: env:MSSQL_CONNECTION_STRING
output: lib/db/generated
extensions_output: lib/db/extensions
models_output: lib/db/models
snapshot: tool/mssql_schema.json
queries_input: lib/db/queries
database_class: AppDatabase
decimal_mode: exact
```

`decimal_as_double` is refused. `decimal_mode` is `exact` (default),
`text`, or `double`. The same value must match `MssqlConnectionConfig`.

Per-table keys (`class_names`, `field_names`, `query_methods`,
`soft_delete_columns`, `hierarchy_parents`, `timestamps`,
`relation_names`, `enum_columns`, `converters`, `projections`) that match
no selected table or column are errors. Nothing is ignored silently.

### How names are matched

| Keys | Matching |
|---|---|
| `include`, `exclude` | glob: `*` is any run of characters, anywhere in the pattern |
| `readonly_columns`, `hidden_columns` | the form `*.Column` only, plus exact names |
| every other keyed setting, and `generate --only` | exact names — no `*` |

All of them ignore case and take a table with or without its schema:
`Orders`, `dbo.Orders` and `DBO.ORDERS` are one table; column and relation
keys add a segment (`dbo.Orders.Status`, `dbo.Orders.customer`).

```yaml
include: ['dbo.Order*', 'Customers']
exclude: ['*_Archive']          # exclude wins where both match
readonly_columns: ['*.RowVersion']
class_names: {dbo.Orders: Order}  # no pattern here: dbo.* matches nothing
```

`*.RowVersion` means that column name on every selected table; anything else
under `readonly_columns` / `hidden_columns` is an exact
`schema.Table.Column`, so `dbo.Orders.*` matches nothing — and a key matching
nothing stops the run.

`include` and `exclude` are the exception to that: an entry matching no table
is allowed, because the default `exclude` is `sysdiagrams`. A misspelled
`include` entry leaves its table out rather than failing, and only an empty
selection stops the run — `generate --dry-run` shows what a long list
resolved to.

Relation keys want the generated relation name rather than the foreign key's:
a single-column foreign key whose column ends in `Id` drops it and
camel-cases the rest (`CustomerId` → `customer`), otherwise the target table
name is camel-cased; the other direction takes the owning table's name
(`OrderLines` → `orderLines`).

`soft_delete_columns: Table: false` opts that table out of the
`deleted_at` convention. Convention hits are reported as generate
warnings. A column named `tenant_id` is not turned into a tenant scope.

### Hierarchies

A generated `descendantsOf(root, {maxDepth, includeRoot, cycles,
maxRecursion})` appears on a table query when the shape leaves nothing to
guess: a single-column primary key, and exactly one single-column foreign
key from the table back to itself referencing that key. `dbo.Categories`
with `ParentId` gets one; nothing else has to be configured.

Two self-references are two different hierarchies, so an `Employees` table
with both `ManagerId` and `MentorId` gets none until it says which:

```yaml
hierarchy_parents:
  dbo.Employees: ManagerId
  dbo.Categories: false      # opt out of the walk its self-FK would give
```

The result is the ordinary generated query type. The recursive expression
is declared on that query's own statement — `WITH` is legal only at the
start of one, which is why the walk cannot be a subquery — and the rows
are narrowed to the keys it walked, so the query's scopes, ordering,
includes and paging all still apply. The walk itself is unscoped: a
soft-deleted parent still links its children, and the query's own
soft-delete filter is what hides rows.

String columns are not turned into Dart enums. Map them:

```yaml
enum_columns:
  dbo.Orders.Status:
    dart: OrderStatus
    import: package:app/order_status.dart
    unknown: error          # default; or member / wrap
    unknown_member: unknown # required for member/wrap
converters:
  dbo.Orders.Amount:
    dart: Money
    converter: MoneyConverter
    import: package:app/money.dart
```

## What you own

`lib/db/generated` is rewritten every run. Do not edit it.

`lib/db/models` and `lib/db/extensions` are created once. Regeneration
does not overwrite them and does not delete them. Prefer extensions on
the generated query types (`orders_scopes.dart`) for application filters.
The generated barrel does not export those extensions — import them from
application code.

`copyWith` and `==` on a generated row cover the schema fields at
generation time. A field you add on the subclass is not part of either;
put behaviour on the subclass or an extension, not extra persisted
columns.

Generated files stamp `API contract: N`. The runtime refuses a binding
written against a different `MssqlApiVersion`.

`class_names: dbo.Orders: Order` produces `OrderRow` / `OrderQuery` /
`OrderFields` / `OrderRowBaseCreate`. Relation targets honour the same
map (`CustomerRow`, not `CustomersRow`).

## Snapshot vs live drift

| Question | Command |
|---|---|
| Is generated Dart stale vs this schema snapshot / live catalog? | `generate --check` (writes nothing) |
| Did a live table move since its fingerprint header? | `check_schema` |
| Did a `.sql` file's described shape move? | `verify_queries` |

`generate --check` builds the same `GenerationPlan` as a real run,
including custom SQL. A green check cannot coexist with a stale
`queries.g.dart`. `--dry-run` prints create/replace/remove/unchanged.
`--report json` prints the plan as JSON.

Stale files are removed only when the generation manifest owns them. A
hand-written file in the output directory is left alone.

## Custom SQL — still the same database

Hand-written `.sql` under `queries_input` becomes `db.reports.*` on the
generated `AppDatabase`. It uses the same session, transaction, observer
and decimal mode as `db.orders`. You are not leaving the package.

```sql
-- lib/db/queries/category_trend.sql
-- name: categoryTrend
-- param: rootId int
-- param: since datetime2
-- describe: manual
-- column: CategoryId int notnull
-- column: MonthStart date notnull
-- column: Revenue decimal(18,4)
```

```dart
await db.transaction((tx) async {
  final rows = await tx.reports.categoryTrend(rootId: 1, since: month);
  await tx.orders.whereStatus('open').get();
});
```

`-- describe: manual` is **your** declared shape. The server does not
verify it. Prefer live `sp_describe_first_result_set` when the statement
is describable. Offline generate reuses
`tool/mssql_schema.queries.json` only while the `.sql` source hash
matches.

Directives: `-- name:` (required), `-- param: x nvarchar(50)`,
`-- returns: list|single|single_or_null|scalar|affected`,
`-- notnull: Col`, `-- read_only: true` (opt-in retry; returning rows
does not imply this), `-- procedure: dbo.sp_X`.
