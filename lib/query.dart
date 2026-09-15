/// A typed query builder for SQL Server, on top of the `mssql_native` driver.
///
/// Compilation is separate from execution: [MssqlQuery.compile] returns an
/// [MssqlStatement] (`sql` **and** `parameters`). Run both together:
/// `session.queryRows(stmt.sql, parameters: stmt.parameters)` or
/// `db.query(selectQuery)`. Passing only `.sql` drops the parameter map.
///
/// Query construction and `compile()` raise Dart *runtime* errors (missing
/// `ORDER BY` on a page, `eq(null)`, empty `inList`). They are not analyzer
/// type errors. Generated column methods such as `whereStatus` are ordinary
/// Dart methods; that is what turns a class of mistakes into compile-time
/// errors.
library;

export 'src/cte.dart'
    show
        MssqlCteField,
        MssqlCycleHandling,
        MssqlHierarchy,
        MssqlTypedCte,
        MssqlTypedCteClauses;
export 'src/dialect.dart' show MssqlDialect;
export 'src/dml.dart'
    show MssqlDelete, MssqlInsert, MssqlInsertSelect, MssqlUpdate, MssqlUpsert;
export 'src/expression.dart'
    show
        Col,
        MssqlAliased,
        MssqlBetween,
        MssqlColumnBase,
        MssqlColumnRef,
        MssqlComparison,
        MssqlCondition,
        MssqlCountAll,
        MssqlDistinctCount,
        MssqlExpression,
        MssqlFunction,
        MssqlInList,
        MssqlJunction,
        MssqlLike,
        MssqlLikePosition,
        MssqlLiteral,
        MssqlNegation,
        MssqlNullCheck,
        MssqlRaw,
        and,
        not,
        or,
        raw;
export 'src/operators.dart'
    show
        MssqlExpressionOperators,
        MssqlNulls,
        MssqlOrder,
        MssqlTemporalOperators,
        MssqlTextOperators,
        avg,
        caseWhen,
        coalesce,
        count,
        countAll,
        dateDiff,
        max,
        min,
        sum;
export 'src/predicates.dart'
    show
        MssqlArithmetic,
        MssqlArithmeticOperator,
        MssqlBetweenColumns,
        MssqlCalendarRange,
        MssqlCase,
        MssqlCaseBranch,
        MssqlCast,
        MssqlCoalesce,
        MssqlColumnGroup,
        MssqlDateBucket,
        MssqlDateBucketUnit,
        MssqlDateDiff,
        MssqlDateDiffUnit,
        MssqlDatePart,
        MssqlDatePartComparison,
        MssqlDateTruncate,
        MssqlNotBetween,
        MssqlOperator,
        MssqlServerClock,
        MssqlServerNow,
        MssqlSqlType,
        MssqlStableExpression,
        MssqlTemporalGrain,
        MssqlTypeFamily,
        MssqlTypedExpression,
        whereAll,
        whereAny,
        whereColumn,
        whereNone;
export 'src/query.dart'
    show
        MssqlCte,
        MssqlJoin,
        MssqlJoinKind,
        MssqlQuery,
        MssqlSelectQuery,
        MssqlSetQuery,
        MssqlSource,
        query;
export 'src/source_ref.dart' show MssqlSourceRef, MssqlSourceScope;
export 'src/statement.dart' show MssqlParameterAllocator, MssqlStatement;
export 'src/subquery.dart'
    show
        MssqlExistsSubquery,
        MssqlExistsValue,
        MssqlInSubquery,
        MssqlScalarSubquery,
        MssqlSubqueryClauses,
        MssqlSubqueryExpressionOperators,
        existsValue,
        scalarSubquery;

export 'src/typed_column.dart'
    show
        MssqlBinaryColumn,
        MssqlBoolColumn,
        MssqlDateTimeColumn,
        MssqlDateTimeValueColumn,
        MssqlDecimalColumn,
        MssqlDoubleColumn,
        MssqlEmptyIn,
        MssqlEnumColumn,
        MssqlGuidColumn,
        MssqlIntColumn,
        MssqlNumericExpression,
        MssqlStringColumn,
        MssqlTemporalExpression,
        MssqlTextExpression,
        MssqlTimeColumn,
        MssqlTypedColumn,
        MssqlTypedInList,
        MssqlTypedLiteral,
        MssqlWriteScope;
export 'src/window.dart'
    show
        MssqlAggregate,
        MssqlAggregateFunction,
        MssqlFrameBound,
        MssqlFrameUnit,
        MssqlIntegerAverage,
        MssqlWindow,
        MssqlWindowExpression,
        MssqlWindowFrame,
        MssqlWindowFunction;
