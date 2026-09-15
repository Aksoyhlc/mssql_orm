/// Reads table and view shapes from SQL Server's catalog views.
///
/// The generator, the schema drift check and any later tooling all start by
/// asking what a table looks like, so this is public API rather than a private
/// detail of any one of them.
library;

export 'src/schema/fingerprint.dart' show fingerprintOf;
export 'src/schema/model.dart'
    show
        MssqlColumnSchema,
        MssqlForeignKeySchema,
        MssqlPrimaryKeySchema,
        MssqlTableSchema,
        MssqlTriggerSchema,
        MssqlUniqueKeySchema;
export 'src/schema/reader.dart' show MssqlSchemaReader;
export 'src/schema/snapshot.dart' show MssqlSchemaSnapshot;
export 'src/schema/type_map.dart'
    show mssqlTypeForSqlTypeName, textOnlySqlTypes;
