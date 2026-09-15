/// Support types the code generator and generated files depend on.
///
/// Application code does not import this. Import the generated
/// `AppDatabase` barrel. The generator (`mssql_orm_dev`) imports this
/// rather than the full `orm.dart`, so its dependency surface is explicit:
/// binding, field, write-command and scope types, and nothing else.
/// Repository, relation loader and observer stay out of the generator's
/// import graph.
library;

// Schema — what the generator reads to produce bindings.
export 'schema.dart';

// Binding — what generated code describes one table as.
export 'src/runtime/binding.dart'
    show
        MssqlBoundColumn,
        MssqlInsertStrategy,
        MssqlTableBinding,
        MssqlTypeConverter;

// Database — the entry point generated AppDatabase extends.
export 'src/runtime/database.dart' show MssqlAppDatabase, MssqlUntypedDatabase;

// Entity query — the F-bound base generated queries extend.
export 'src/runtime/entity_query.dart' show MssqlEntityQuery;

// Field — the absent/value distinction for Create and Patch.
export 'src/runtime/field.dart' show AbsentField, Field, ValueField;

// Query state and context — what generated entity queries carry.
export 'src/runtime/query_context.dart'
    show MssqlClock, MssqlQueryContext, MssqlScopeCompiler;
export 'src/runtime/query_state.dart' show MssqlQueryState;

// Scope — immutable scope selection and soft-delete conventions.
export 'src/runtime/scope.dart'
    show
        MssqlScope,
        MssqlScopeSelection,
        MssqlSoftDelete,
        MssqlTimestamps,
        MssqlTrashed;

// Write commands — the engine generated Create/Patch feeds.
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
