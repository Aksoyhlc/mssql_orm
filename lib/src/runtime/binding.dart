import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../api_version.dart';
import '../source_ref.dart';
import 'scope.dart';

/// How a row's key comes back from an insert.
///
/// Chosen when code is generated, not at runtime: whether `OUTPUT` is usable
/// is a fact about the table that `sys.triggers` answers exactly.
enum MssqlInsertStrategy {
  /// `INSERT … OUTPUT INSERTED.* VALUES …` — one round trip, and defaults and
  /// computed columns come back too.
  outputInserted,

  /// `INSERT …; SELECT SCOPE_IDENTITY()` — for a table carrying an enabled
  /// trigger, where SQL Server rejects an `OUTPUT` clause without `INTO`
  /// (error 334). Only the identity value comes back.
  scopeIdentity,

  /// No identity column: nothing to read back.
  noKeyReadback,
}

/// Converts between a Dart type and what SQL Server stores.
///
/// Applied in both directions: reading a row and writing one. `null` never
/// reaches a converter — a nullable column's `null` stays `null` — so a
/// converter that must handle it declares nullable type arguments.
abstract class MssqlTypeConverter<TDart, TSql> {
  const MssqlTypeConverter();

  TDart fromSql(TSql value);
  TSql toSql(TDart value);
}

/// One column, as generated code describes it to the runtime.
@immutable
class MssqlBoundColumn {
  MssqlBoundColumn({
    required this.name,
    required this.type,
    this.nullable = false,
    this.isIdentity = false,
    this.isComputed = false,
    this.isRowVersion = false,
    this.hasDefault = false,
    this.isReadOnly = false,
    this.maxLength = 0,
    this.precision = 18,
    this.scale = 0,
    this.converter,
  });

  final String name;
  final MssqlType type;
  final bool nullable;
  final bool isIdentity;
  final bool isComputed;
  final bool isRowVersion;
  final bool hasDefault;

  /// `sys.columns.max_length`, in bytes: an `nvarchar(50)` is 100 and a `max`
  /// column is -1. Binds a null with the declared size.
  final int maxLength;

  final int precision;
  final int scale;

  /// The schema permits writing this column but the application must not.
  ///
  /// Audit columns are the usual case. A full-row update writes every column,
  /// so without this a read-modify-write round trip puts `CreatedAt` back and
  /// clobbers whatever changed it in between.
  final bool isReadOnly;

  final MssqlTypeConverter<Object?, Object?>? converter;

  /// Whether an `INSERT` or `UPDATE` may name this column.
  ///
  /// Two different reasons collapse here: the server owns the value
  /// (identity, computed, rowversion), or the application has been told not to
  /// write it.
  bool get writable =>
      !isIdentity && !isComputed && !isRowVersion && !isReadOnly;

  Object? decode(Object? value) =>
      value == null || converter == null ? value : converter!.fromSql(value);

  Object? encode(Object? value) =>
      value == null || converter == null ? value : converter!.toSql(value);

  /// What this column is, in the driver's own terms.
  ///
  /// `sys.columns.max_length` is in bytes, and an n-type stores two per
  /// character, so the size is converted here rather than at each use. A `max`
  /// column reports -1, which becomes 0: "unbounded".
  MssqlColumnType get columnType {
    final bytes = maxLength < 0 ? 0 : maxLength;
    final wide = switch (type) {
      MssqlType.nchar || MssqlType.nvarchar => true,
      _ => false,
    };
    return MssqlColumnType(
      type: type,
      size: wide ? bytes ~/ 2 : bytes,
      precision: precision,
      scale: scale,
      nullable: nullable,
      columnName: name,
    );
  }

  /// The codec for this column, built once and shared by every use of it.
  ///
  /// Reading a row, comparing in a predicate, inserting, updating and grouping
  /// children by a foreign key all go through the same object, so they cannot
  /// disagree about what the column is.
  late final MssqlTypeCodec<Object?> codec = MssqlTypeCodecs.forColumn(
    columnType,
  );

  /// The value to hand the driver for this column.
  ///
  /// Bound through [codec], which means with this column's own SQL type — not
  /// the driver's inference. Inference sees a Dart `String` and sends
  /// `nvarchar`, a Dart number and sends `float`; against a `varchar` or a
  /// `decimal` column SQL Server then converts the column rather than the
  /// parameter, which changes what the comparison means for money and takes
  /// the column's index out of play.
  MssqlValue bind(Object? value) => codec.encode(encode(value));

  /// A key for grouping rows by this column's value.
  Object keyValue(Object value) => codec.keyValue(encode(value));

  /// A typed null for this column.
  MssqlValue get nullValue {
    // Characters are declared in bytes, and an n-type stores two per
    // character; a `max` column reports -1, which the driver reads as
    // "unbounded" when the size is left at zero.
    final chars = maxLength < 0 ? 0 : maxLength;
    final wideChars = maxLength < 0 ? 0 : maxLength ~/ 2;
    return switch (type) {
      MssqlType.bit => const MssqlValue.bit(null),
      MssqlType.tinyInt => const MssqlValue.tinyInt(null),
      MssqlType.smallInt => const MssqlValue.smallInt(null),
      MssqlType.int32 => const MssqlValue.int32(null),
      MssqlType.int64 => const MssqlValue.int64(null),
      MssqlType.real => const MssqlValue.real(null),
      MssqlType.float64 => const MssqlValue.float64(null),
      MssqlType.decimal => MssqlValue.decimal(
        null,
        precision: precision,
        scale: scale,
      ),
      MssqlType.numeric => MssqlValue.numeric(
        null,
        precision: precision,
        scale: scale,
      ),
      MssqlType.money => MssqlValue.money(null),
      MssqlType.smallMoney => MssqlValue.smallMoney(null),
      MssqlType.char => MssqlValue.char(null, size: chars == 0 ? 1 : chars),
      MssqlType.varchar => MssqlValue.varchar(null, size: chars),
      MssqlType.nchar => MssqlValue.nchar(
        null,
        size: wideChars == 0 ? 1 : wideChars,
      ),
      MssqlType.nvarchar => MssqlValue.nvarchar(null, size: wideChars),
      MssqlType.text => const MssqlValue.text(null),
      MssqlType.ntext => const MssqlValue.ntext(null),
      MssqlType.binary => MssqlValue.binary(null, size: chars == 0 ? 1 : chars),
      MssqlType.varbinary => MssqlValue.varbinary(null, size: chars),
      MssqlType.image => const MssqlValue.image(null),
      MssqlType.date => MssqlValue.date(null),
      MssqlType.time => MssqlValue.time(null, scale: scale),
      MssqlType.smallDateTime => MssqlValue.smallDateTime(null),
      MssqlType.dateTime => MssqlValue.dateTime(null),
      MssqlType.dateTime2 => MssqlValue.dateTime2(null, scale: scale),
      MssqlType.dateTimeOffset => MssqlValue.dateTimeOffset(null, scale: scale),
      MssqlType.uniqueIdentifier => const MssqlValue.uniqueIdentifier(null),
      MssqlType.xml => const MssqlValue.xml(null),
    };
  }
}

/// Everything generated code tells the runtime about one table.
///
/// The logic lives in [MssqlRepository]; a generated file writes one of these
/// and nothing more. That is what makes a bug in paging a version bump rather
/// than a regeneration against every consumer's live database.
@immutable
class MssqlTableBinding<TRow> {
  MssqlTableBinding({
    required this.schema,
    required this.table,
    required List<MssqlBoundColumn> columns,
    required this.fromRow,
    required this.toColumns,
    required this.readColumn,
    this.applyIdentity,
    this.applyRelations,
    this.isRelationLoaded,
    List<String> primaryKey = const <String>[],
    this.identityColumn,
    this.insertStrategy = MssqlInsertStrategy.noKeyReadback,
    this.schemaFingerprint = '',
    this.decimalMode = MssqlDecimalMode.exact,
    this.apiVersion = MssqlApiVersion.current,
    MssqlSoftDelete? softDelete,
    MssqlTimestamps timestamps = const MssqlTimestamps(),
    List<MssqlScope> scopes = const <MssqlScope>[],
  }) : columns = List<MssqlBoundColumn>.unmodifiable(columns),
       primaryKey = List<String>.unmodifiable(primaryKey),
       scopes = List<MssqlScope>.unmodifiable(scopes),
       // Convention columns are resolved to the schema's own spelling here,
       // once, rather than at each place that reads them. Lookup is
       // case-insensitive, so a configuration saying `deletedat` validates
       // against `DeletedAt` — and then every predicate and assignment built
       // from it has to say `DeletedAt` too, or the SQL breaks on a database
       // with a case-sensitive collation.
       softDelete = _canonicalSoftDelete(softDelete, columns),
       timestamps = _canonicalTimestamps(timestamps, columns) {
    for (final key in this.primaryKey) {
      if (column(key) == null) {
        throw ArgumentError.value(
          key,
          'primaryKey',
          'Names a column $schema.$table does not have.',
        );
      }
    }
    // Validation reads the fields, not the parameters: those are the
    // canonicalized values, and they are what every message should name.
    final soft = this.softDelete;
    _validateConventionColumn(soft?.column, 'softDelete');
    if (soft != null) {
      final softColumn = column(soft.column)!;
      if (soft.deletedValue == null && !_storesServerClock(softColumn)) {
        throw ArgumentError.value(
          soft.column,
          'softDelete',
          'A timestamp soft-delete column must use a date/time SQL type.',
        );
      }
      if (soft.aliveValue == null && !softColumn.nullable) {
        throw ArgumentError.value(
          soft.column,
          'softDelete',
          'A null-means-live soft-delete column must be nullable.',
        );
      }
      if (soft.aliveValue != null && soft.deletedValue == null) {
        throw ArgumentError.value(
          soft.column,
          'softDelete',
          'A value-based soft-delete convention needs deletedValue.',
        );
      }
    }
    final stamps = this.timestamps;
    _validateConventionColumn(stamps.createdColumn, 'timestamps.createdColumn');
    _validateConventionColumn(stamps.updatedColumn, 'timestamps.updatedColumn');
    for (final name in <String?>[stamps.createdColumn, stamps.updatedColumn]) {
      if (name != null && !_storesServerClock(column(name)!)) {
        throw ArgumentError.value(
          name,
          'timestamps',
          'Timestamp columns must use a date/time SQL type.',
        );
      }
    }
    if (stamps.createdColumn != null &&
        stamps.createdColumn!.toLowerCase() ==
            stamps.updatedColumn?.toLowerCase()) {
      throw ArgumentError.value(
        stamps.createdColumn,
        'timestamps',
        'Created and updated timestamps must use different columns.',
      );
    }
    if (!MssqlApiVersion.supports(apiVersion)) {
      throw ArgumentError(
        MssqlApiVersion.mismatchMessage(apiVersion, '$schema.$table'),
      );
    }
    final softName = softDelete?.column.toLowerCase();
    if (softName != null &&
        (softName == timestamps.createdColumn?.toLowerCase() ||
            softName == timestamps.updatedColumn?.toLowerCase())) {
      throw ArgumentError.value(
        softDelete!.column,
        'softDelete',
        'A soft-delete column cannot also be a timestamp column.',
      );
    }
    final scopeNames = <String>{};
    for (final scope in this.scopes) {
      final name = scope.name.trim();
      if (name.isEmpty) {
        throw ArgumentError.value(
          scope.name,
          'scopes',
          'A scope needs a name.',
        );
      }
      if (!scopeNames.add(name)) {
        throw ArgumentError.value(
          scope.name,
          'scopes',
          'Scope names must be unique within $schema.$table.',
        );
      }
    }
  }

  void _validateConventionColumn(String? name, String argument) {
    if (name == null) return;
    final configured = column(name);
    if (configured == null) {
      throw ArgumentError.value(
        name,
        argument,
        'Names a column $schema.$table does not have.',
      );
    }
    if (!configured.writable) {
      throw ArgumentError.value(
        name,
        argument,
        'The convention column must be writable.',
      );
    }
  }

  bool _storesServerClock(MssqlBoundColumn column) => switch (column.type) {
    MssqlType.date ||
    MssqlType.time ||
    MssqlType.smallDateTime ||
    MssqlType.dateTime ||
    MssqlType.dateTime2 ||
    MssqlType.dateTimeOffset => true,
    _ => false,
  };

  final String schema;
  final String table;
  final List<MssqlBoundColumn> columns;
  final List<String> primaryKey;
  final String? identityColumn;
  final MssqlInsertStrategy insertStrategy;

  /// The schema this binding was generated from. Read by the drift check.
  final String schemaFingerprint;

  /// Whether the generated row types assume `DECIMAL` arrives as `double`.
  final MssqlDecimalMode decimalMode;

  /// The ORM API contract the generated file was written against.
  final int apiVersion;

  /// Non-null when the table soft-deletes.
  final MssqlSoftDelete? softDelete;

  /// The created/updated columns the runtime maintains, if any.
  final MssqlTimestamps timestamps;

  /// Predicates applied to every read unless switched off by name.
  final List<MssqlScope> scopes;

  bool get softDeletes => softDelete != null;

  final TRow Function(MssqlRow row) fromRow;
  final Map<String, Object?> Function(TRow row) toColumns;

  /// One column of [row], without building a map of every column.
  ///
  /// Relation key extraction only needs the local/foreign key columns.
  /// `toColumns` allocates a map of the whole row; this reads one field.
  final Object? Function(TRow row, String column) readColumn;

  /// Puts a server-generated identity value back into a row.
  ///
  /// Needed only by [MssqlInsertStrategy.scopeIdentity], where the insert
  /// returns the key alone and the rest of the row is what the caller already
  /// had. Generated code supplies `(row, id) => row.copyWith(id: id as int)`;
  /// the runtime cannot write it because only the generated class knows which
  /// field the identity column is.
  final TRow Function(TRow row, Object? identity)? applyIdentity;

  /// Puts loaded related rows into a row, and records which were loaded.
  ///
  /// Rows are immutable, so attaching a relation produces a new row, and only
  /// the generated class knows which field each relation name belongs to.
  /// Null means the table has no generated relations.
  final TRow Function(TRow row, Map<String, Object?> relations)? applyRelations;

  /// Whether [row] already carries [name], for [MssqlEntityQuery.loadMissing].
  ///
  /// Null means "treat every name as missing": loadMissing reloads the
  /// requested paths on every row. Generated rows pass `row.isLoaded`.
  final bool Function(TRow row, String name)? isRelationLoaded;

  /// [toColumns] without the type argument.
  ///
  /// Dart checks generic function values at runtime, so tearing off
  /// `toColumns` from an `MssqlTableBinding<Object?>` fails when the binding is
  /// really an `MssqlTableBinding<CustomerRow>`. The relation loader works
  /// across table types, so it goes through this instead.
  Map<String, Object?> columnsOf(Object? row) => toColumns(row as TRow);

  /// [readColumn] without the type argument.
  Object? columnOf(Object? row, String column) =>
      readColumn(row as TRow, column);

  /// The named columns of [row], and nothing else.
  ///
  /// Relation grouping only needs the key columns. Building the whole
  /// row map to pick two names out of it is the allocation this avoids.
  Map<String, Object?> columnsNamed(TRow row, Iterable<String> names) =>
      <String, Object?>{for (final name in names) name: readColumn(row, name)};

  /// [columnsNamed] without the type argument.
  Map<String, Object?> namedColumnsOf(Object? row, Iterable<String> names) =>
      columnsNamed(row as TRow, names);

  /// [fromRow] without the type argument, for the same reason.
  Object? rowFrom(MssqlRow row) => fromRow(row);

  /// Whether this table has generated relations to attach.
  ///
  /// A separate flag rather than a null check on [applyRelations], because
  /// reading that field across table types is itself the runtime cast this
  /// method exists to avoid.
  bool get hasRelations => applyRelations != null;

  /// [applyRelations] without the type argument, for the same reason as
  /// [columnsOf].
  Object? withRelations(Object? row, Map<String, Object?> relations) =>
      applyRelations == null ? row : applyRelations!(row as TRow, relations);

  /// Erases [TRow] so through and morph maps can hold mixed tables.
  ///
  /// Dart generics are reified: `MssqlTableBinding<Order>` is not a
  /// `MssqlTableBinding<Object?>`. A belongsToMany pivot and a morphTo
  /// target list have to be one type, and [columnsOf]/[rowFrom] already
  /// do the cast this wrapper would otherwise repeat at every call.
  MssqlTableBinding<Object?> erase() => MssqlTableBinding<Object?>(
    schema: schema,
    table: table,
    columns: columns,
    fromRow: fromRow,
    toColumns: (row) => toColumns(row as TRow),
    readColumn: (row, name) => readColumn(row as TRow, name),
    applyIdentity: applyIdentity == null
        ? null
        : (row, id) => applyIdentity!(row as TRow, id),
    applyRelations: applyRelations == null
        ? null
        : (row, relations) => applyRelations!(row as TRow, relations),
    isRelationLoaded: isRelationLoaded == null
        ? null
        : (row, name) => isRelationLoaded!(row as TRow, name),
    primaryKey: primaryKey,
    identityColumn: identityColumn,
    insertStrategy: insertStrategy,
    schemaFingerprint: schemaFingerprint,
    decimalMode: decimalMode,
    apiVersion: apiVersion,
    softDelete: softDelete,
    timestamps: timestamps,
    scopes: scopes,
  );

  /// This binding pointed at a different table.
  ///
  /// Eloquent's `protected $table`. The columns, key, relations and
  /// conventions stay as generated — what changes is which table they are
  /// read from and written to. An archive table with the same shape, a
  /// per-tenant copy, or a synonym are the cases this exists for.
  ///
  /// The name is not re-validated against a live schema, because there is no
  /// connection here to ask; the drift check is where that question belongs.
  MssqlTableBinding<TRow> forTable({String? schema, String? table}) {
    if (schema == null && table == null) return this;
    // Parsed here rather than left to the first query, so a name that cannot
    // be an identifier is reported where it was written.
    MssqlSql.quoteMultipartIdentifier(<String>[
      schema ?? this.schema,
      table ?? this.table,
    ]);
    return MssqlTableBinding<TRow>(
      schema: schema ?? this.schema,
      table: table ?? this.table,
      columns: columns,
      fromRow: fromRow,
      toColumns: toColumns,
      readColumn: readColumn,
      applyIdentity: applyIdentity,
      applyRelations: applyRelations,
      isRelationLoaded: isRelationLoaded,
      primaryKey: primaryKey,
      identityColumn: identityColumn,
      insertStrategy: insertStrategy,
      // Deliberately dropped: the fingerprint describes the table it was
      // generated from, and carrying it onto another one would make the drift
      // check compare a schema against a description of a different table.
      schemaFingerprint: '',
      decimalMode: decimalMode,
      apiVersion: apiVersion,
      softDelete: softDelete,
      timestamps: timestamps,
      scopes: scopes,
    );
  }

  String get quoted =>
      MssqlSql.quoteMultipartIdentifier(<String>[schema, table]);

  String get qualifiedName => '$schema.$table';

  /// The schema and table as separate parts.
  ///
  /// What every statement is built from, so a table whose name carries a dot
  /// or a space is never re-parsed out of a joined string.
  List<String> get nameParts => <String>[schema, table];

  /// This table's identity, for the columns that belong to it.
  ///
  /// A query built from this binding registers it, so that generated columns
  /// resolve to whatever the statement called the table — its own name, an
  /// alias, or another schema entirely when the binding was pointed at one.
  MssqlSourceRef get sourceRef => MssqlSourceRef(schema: schema, table: table);

  bool get hasPrimaryKey => primaryKey.isNotEmpty;

  /// The rowversion/timestamp column, if the table has one.
  ///
  /// Optimistic concurrency is this column or nothing. A table without one
  /// has no token to put in a WHERE, and `expectedVersion` is refused.
  MssqlBoundColumn? get rowVersionColumn =>
      columns.firstWhereOrNull((c) => c.isRowVersion);

  /// The schema's own spelling of [name], or [name] when nothing matches.
  ///
  /// Returning the input unchanged rather than null keeps this usable from an
  /// initializer list; the constructor body is what reports a name the table
  /// does not have.
  static String? _canonicalColumnName(
    String? name,
    List<MssqlBoundColumn> columns,
  ) {
    if (name == null) return null;
    final lower = name.toLowerCase();
    for (final column in columns) {
      if (column.name.toLowerCase() == lower) return column.name;
    }
    return name;
  }

  static MssqlSoftDelete? _canonicalSoftDelete(
    MssqlSoftDelete? declared,
    List<MssqlBoundColumn> columns,
  ) {
    if (declared == null) return null;
    final name = _canonicalColumnName(declared.column, columns)!;
    if (name == declared.column) return declared;
    return MssqlSoftDelete(
      column: name,
      aliveValue: declared.aliveValue,
      deletedValue: declared.deletedValue,
    );
  }

  static MssqlTimestamps _canonicalTimestamps(
    MssqlTimestamps declared,
    List<MssqlBoundColumn> columns,
  ) {
    final created = _canonicalColumnName(declared.createdColumn, columns);
    final updated = _canonicalColumnName(declared.updatedColumn, columns);
    if (created == declared.createdColumn &&
        updated == declared.updatedColumn) {
      return declared;
    }
    return MssqlTimestamps(createdColumn: created, updatedColumn: updated);
  }

  MssqlBoundColumn? column(String name) => columns.firstWhereOrNull(
    (c) => c.name.toLowerCase() == name.toLowerCase(),
  );

  /// The columns an `INSERT` or `UPDATE` may name.
  List<MssqlBoundColumn> get writableColumns =>
      columns.where((c) => c.writable).toList(growable: false);

  @override
  String toString() => 'MssqlTableBinding($qualifiedName)';
}
