# Examples

This package includes a complete database-first example under `example/db`.

- `generated/` shows replaceable output produced from a SQL Server schema.
- `models/` shows application-owned row subclasses.
- `extensions/` shows application-owned query scopes.
- `queries/` contains hand-written SQL that becomes typed database methods.
- `mssql_orm.yaml` is the generator configuration used by the example.

Start with the package [README](../README.md), then use the focused
[ORM examples](../doc/EXAMPLES_ORM.md) or
[query builder examples](../doc/EXAMPLES_QUERY_BUILDER.md).

Generated files are included to make the resulting API inspectable. Do not
edit files under `example/db/generated`; regenerate them with
`mssql_orm_dev`.
