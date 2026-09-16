/// The repository runtime: what generated table code stands on.
///
/// Application code imports the generated `AppDatabase` barrel
/// (`lib/db/generated/generated.dart` and `database.g.dart`), then uses
/// `db.orders.whereId(1).get()`. This library is what those generated files
/// import. Do not construct [MssqlTableBinding] or a hand-rolled executor in
/// the getting-started path — there is no `MssqlExecutor`; the session is
/// [MssqlSession] from `mssql_native`.
///
/// Query-builder types (`MssqlQuery`, [MssqlHierarchy], [MssqlTypedCte],
/// [MssqlWindow], [MssqlExistsValue], [MssqlCalendarRange], `inYear`,
/// `onDate`, `dateBucket`, `caseWhen`, `coalesce`) come through `query.dart`.
/// Generator support types that applications do not need are in
/// `generation.dart`.
library;

export 'query.dart';
export 'schema.dart';
export 'src/api_version.dart' show MssqlApiVersion;
export 'src/dml.dart'
    show
        MssqlDefault,
        MssqlOutputClause,
        MssqlOutputColumn,
        MssqlOutputSource,
        MssqlOutputTarget;
export 'src/projection.dart' show MssqlProjection, MssqlProjectionColumn;
export 'src/runtime/binding.dart'
    show
        MssqlBoundColumn,
        MssqlInsertStrategy,
        MssqlTableBinding,
        MssqlTypeConverter;
export 'src/runtime/bulk_write.dart'
    show
        MssqlBulkWriter,
        MssqlCreateManyResult,
        MssqlCreateManyStrategy,
        MssqlKeyedPatch;
export 'src/runtime/capability_cache.dart' show MssqlCapabilityCache;
export 'src/runtime/concurrency.dart'
    show MssqlUniqueMatch, duplicateKeyIs, duplicateKeyName, sessionIsDoomed;
export 'src/runtime/cursor.dart' show MssqlCursor, MssqlCursorPage;
export 'src/runtime/database.dart' show MssqlAppDatabase, MssqlUntypedDatabase;
export 'src/runtime/date_time.dart' show MssqlDateTimeConversion;
export 'src/runtime/entity_query.dart' show MssqlEntityQuery;
export 'src/runtime/exception.dart'
    show
        MssqlAffectedRowsException,
        MssqlBindingMismatchException,
        MssqlCapabilityException,
        MssqlCardinalityException,
        MssqlConcurrencyException,
        MssqlCursorMismatchException,
        MssqlIncludeConflictException,
        MssqlMissingOutputException,
        MssqlOrmException,
        MssqlReadbackUnavailableException,
        MssqlRelationNotLoadedException,
        MssqlRelationTruncatedException,
        MssqlRowNotFoundException,
        MssqlUnexpectedNullException,
        MssqlUnexpectedResultSetException,
        MssqlUniqueConflictException,
        MssqlUnknownEnumValueException,
        MssqlUnsafeWriteException,
        mssqlRequireNonNull;
export 'src/runtime/field.dart' show AbsentField, Field, ValueField;
export 'src/runtime/graph_write.dart'
    show
        MssqlCycleWrite,
        MssqlGraphInsert,
        MssqlGraphRelation,
        MssqlGraphWriter;
export 'src/runtime/observer.dart'
    show
        MssqlDiagnosticSink,
        MssqlObservedSession,
        MssqlObservedSessionExtension,
        MssqlObserverOptions,
        MssqlQueryEvent,
        MssqlOrmQueryKind,
        MssqlQueryObserver,
        MssqlQueryRecorder,
        mssqlNoteCompileElapsed,
        mssqlRedactParameters;
export 'src/runtime/page.dart' show MssqlPage, MssqlReadConsistency;
export 'src/runtime/projected_query.dart' show MssqlProjectedQuery;
export 'src/runtime/query_context.dart'
    show MssqlClock, MssqlQueryContext, MssqlScopeCompiler;
export 'src/runtime/query_state.dart' show MssqlQueryState;
export 'src/runtime/relation.dart'
    show
        MssqlIncludeStrategy,
        MssqlMorph,
        MssqlMorphUnknown,
        MssqlPivoted,
        MssqlRelation,
        MssqlRelationKey,
        MssqlRelationKind,
        MssqlRelationThrough,
        batchKeys,
        mergeIncludes,
        mssqlTruncatedRelationsKey,
        relationKeyOf,
        relationParameterCeiling,
        relationPredicate;
export 'src/runtime/relation_filter.dart'
    show MssqlRelationAggregate, relationExistsQuery;
export 'src/runtime/relation_write.dart' show MssqlRelationMutation;
export 'src/runtime/repository.dart' show MssqlRepository;
export 'src/runtime/run_query.dart'
    show
        MssqlDeleteExecution,
        MssqlInsertExecution,
        MssqlInsertSelectExecution,
        MssqlQueryExecution,
        MssqlSelectQueryExecution,
        MssqlStatementExecution,
        MssqlUpdateExecution,
        MssqlUpsertExecution;
export 'src/runtime/schema_check.dart'
    show
        MssqlDifferenceKind,
        MssqlDifferenceSeverity,
        MssqlSchemaCheck,
        MssqlSchemaDifference,
        MssqlSchemaReport,
        diffSchemas;
export 'src/runtime/scope.dart'
    show
        MssqlScope,
        MssqlScopeSelection,
        MssqlSoftDelete,
        MssqlTimestamps,
        MssqlTrashed;
export 'src/runtime/watch.dart' show MssqlChangeHub, MssqlWatchStrategy;
export 'src/runtime/write_commands.dart'
    show
        MssqlAffectedRowsSource,
        MssqlBoundValue,
        MssqlDefaultValue,
        MssqlServerValue,
        MssqlTriggerKind,
        MssqlWriteAssignments,
        MssqlWriteEngine,
        MssqlWriteOutcome,
        MssqlWriteReadback,
        MssqlWriteValue;
