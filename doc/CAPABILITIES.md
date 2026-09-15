# Capabilities

What SQL this package will emit, and what it will refuse.

`MssqlDialect` carries **two** numbers: product major version (10 = 2008,
11 = 2012, 16 = 2022) and database `compatibility_level` (100 / 110 / 160).
A 2022 engine hosting a database left at 100 rejects 2012 language the same
way a 2008 server would. Compiling with `MssqlDialect.sql2012` against that
database is therefore wrong; pass the real level with
`MssqlDialect.forVersion(majorVersion: 16, compatibilityLevel: 100)`.

**Rule:** an unsupported feature throws `MssqlCapabilityException`. It is
not rewritten to SQL that looks similar and means something else.

| Feature | SQL 2008 / compat 100 | 2012+ / compat 110 | 2017+ / 140 | 2022+ / 160 |
|---|---|---|---|---|
| `OFFSET … FETCH` paging | no — `ROW_NUMBER()` subquery | yes | yes | yes |
| `DATEFROMPARTS`, `EOMONTH`, `TRY_CONVERT` | **refused** | yes | yes | yes |
| Window `ROWS`/`RANGE` frames | no (2008 has `ROW_NUMBER`/`RANK` without a frame) | yes | yes | yes |
| `LAG` / `LEAD` / `FIRST_VALUE` / `LAST_VALUE` | **refused** | yes | yes | yes |
| `STRING_AGG` | **refused** | **refused** until 2017 | yes | yes |
| `DATE_BUCKET` (`dateBucket()`) | **refused** | **refused** | **refused** | yes |
| `monthStart()` / `truncatedTo(month)` | emitted (DATEADD/DATEDIFF style; no version gate) | same | same | same |
| Recursive CTE (`MssqlTypedCte.recursive`, `MssqlHierarchy.descendantsOf`, generated `descendantsOf`) | yes | yes | yes | yes |
| `MAXRECURSION` | statement option | same | same | same |
| `datetime2` / `datetimeoffset` / `time` types | yes (driver types) | yes | yes | yes |
| `sp_describe_first_result_set` | first result set only; not on every edition/permission | same | same | same |

`dateBucket()` vs `monthStart()`: a calendar month is not a `DATE_BUCKET`
width. Older servers keep `monthStart()`. A ten-minute bucket has no
honest 2012 spelling in this compiler, so it is refused until 2022.

Temporal values: `datetime2(7)`, `time(7)` and `datetimeoffset` map to
`MssqlDateTimeValue` (100 ns). Lower `datetime2`/`time` precision may be
`DateTime` / `Duration`. Filters must use the same type the column has.

Procedure describe cannot see `#temp` tables, `EXEC(@sql)`, or a first
result set whose shape depends on a branch. `-- describe: manual` is then
the application's declaration, not a substitute analysis.

Window functions without a matching dialect throw rather than drop the
`LAG` into a self-join. Paging is the exception that already has two
honest shapes (`OFFSET` vs `ROW_NUMBER`), selected by the same descriptor.
