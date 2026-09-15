// GENERATED — do not edit. Rewritten on every run.
//
// Source: dbo.Customers
// Generator: mssql_orm_dev 0.1.0
// API contract: 2
// Schema fingerprint: 1f547b82eb1a24bdc6879a30df963bb6698c24f9ae1246ddd0c587fcc81cbbde
//
// Application code belongs in ../models/customers.dart,
// which this generator creates once and never touches again.

import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import '../models/customers.dart';
import '../models/orders.dart';

/// One row of dbo.Customers.
///
/// `copyWith` and `==` cover the fields declared here. A
/// field added to CustomerRow is not carried by either, which
/// is inherent to the split; adding behaviour is free.
@immutable
class CustomerRowBase {
  const CustomerRowBase({
    required this.id,
    required this.code,
    required this.name,
    this.city,
    required this.isActive,
    required this.createdAt,
    this.updatedAt,
    this.deletedAt,
    List<OrderRow>? orders,
    Set<String> loadedRelations = const <String>{},
    Map<String, int> truncatedRelations = const <String, int>{},
  }) : _orders = orders,
       _loadedRelations = loadedRelations,
       _truncatedRelations = truncatedRelations;

  /// IDENTITY.
  final int id;
  final String code;
  final String name;
  final String? city;
  final bool isActive;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue createdAt;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue? updatedAt;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue? deletedAt;

  final List<OrderRow>? _orders;
  final Set<String> _loadedRelations;
  final Map<String, int> _truncatedRelations;

  /// Whether [relation] was loaded for this row.
  ///
  /// True for loaded-null and loaded-empty. Truncated is
  /// still loaded; [isTruncated] is the incomplete flag.
  bool isLoaded(String relation) => _loadedRelations.contains(relation);

  /// Typed form of [isLoaded]: the handle, not a string.
  bool relationLoaded<TChild>(MssqlRelation<CustomerRow, TChild> relation) =>
      isLoaded(relation.name);

  /// Whether [relation] hit maxLoadedRows.
  bool isTruncated(String relation) =>
      _truncatedRelations.containsKey(relation);

  /// Throws when the relation was not loaded. An empty
  /// list means loaded and none.
  List<OrderRow> get orders {
    if (!_loadedRelations.contains('orders')) {
      throw MssqlRelationNotLoadedException('dbo.Customers', 'orders');
    }
    if (_truncatedRelations.containsKey('orders')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.Customers',
        relation: 'orders',
        limit: _truncatedRelations['orders']!,
      );
    }
    return _orders ?? const [];
  }

  /// Reads a row by ordinal after checking column names.
  ///
  /// Name lookup on every field would rebuild a map the
  /// driver already has. Extra trailing columns are allowed
  /// so a withCount projection can append aggregates.
  static const List<String> columnOrder = <String>[
    'Id',
    'Code',
    'Name',
    'City',
    'IsActive',
    'CreatedAt',
    'UpdatedAt',
    'DeletedAt',
  ];
  static CustomerRow fromRow(MssqlRow row) {
    row.assertOrdinalNames(columnOrder);
    return CustomerRow(
      id: (row.at(0)! as num).toInt(),
      code: row.at(1)! as String,
      name: row.at(2)! as String,
      city: row.at(3) as String?,
      isActive: row.at(4)! as bool,
      createdAt: row.at(5)! as MssqlDateTimeValue,
      updatedAt: row.at(6) as MssqlDateTimeValue?,
      deletedAt: row.at(7) as MssqlDateTimeValue?,
    );
  }

  /// One column of this row, by SQL name.
  Object? columnValue(String name) => switch (name) {
    'Id' => id,
    'Code' => code,
    'Name' => name,
    'City' => city,
    'IsActive' => isActive,
    'CreatedAt' => createdAt,
    'UpdatedAt' => updatedAt,
    'DeletedAt' => deletedAt,
    _ => throw ArgumentError.value(
      name,
      'name',
      'CustomerRow has no column named "$name".',
    ),
  };

  Map<String, Object?> toColumns() => <String, Object?>{
    'Id': id,
    'Code': code,
    'Name': name,
    'City': city,
    'IsActive': isActive,
    'CreatedAt': createdAt,
    'UpdatedAt': updatedAt,
    'DeletedAt': deletedAt,
  };

  CustomerRow copyWith({
    int? id,
    String? code,
    String? name,
    String? city,
    bool? isActive,
    MssqlDateTimeValue? createdAt,
    MssqlDateTimeValue? updatedAt,
    MssqlDateTimeValue? deletedAt,
  }) => CustomerRow(
    id: id ?? this.id,
    code: code ?? this.code,
    name: name ?? this.name,
    city: city ?? this.city,
    isActive: isActive ?? this.isActive,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt ?? this.deletedAt,
    orders: _orders,
    loadedRelations: _loadedRelations,
    truncatedRelations: _truncatedRelations,
  );

  /// Returns a copy carrying the loaded relations.
  ///
  /// Rows are immutable, so the loader cannot write into
  /// one; it asks for a new row instead.
  CustomerRow withRelations(Map<String, Object?> relations) => CustomerRow(
    id: id,
    code: code,
    name: name,
    city: city,
    isActive: isActive,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
    orders: relations.containsKey('orders')
        ? (relations['orders']! as List<Object?>).cast<OrderRow>()
        : _orders,
    loadedRelations: <String>{
      ..._loadedRelations,
      for (final key in relations.keys)
        if (key != mssqlTruncatedRelationsKey) key,
    },
    truncatedRelations: <String, int>{
      ..._truncatedRelations,
      if (relations[mssqlTruncatedRelationsKey]
          case final Map<Object?, Object?> extra)
        for (final entry in extra.entries)
          entry.key.toString(): (entry.value as num).toInt(),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerRowBase &&
          other.id == id &&
          other.code == code &&
          other.name == name &&
          other.city == city &&
          other.isActive == isActive &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    code,
    name,
    city,
    isActive,
    createdAt,
    updatedAt,
    deletedAt,
  ]);

  @override
  String toString() =>
      'CustomerRow(id: $id, code: $code, name: $name, city: $city, isActive: $isActive, createdAt: $createdAt, updatedAt: $updatedAt, deletedAt: $deletedAt)';
}

/// Values for inserting one row into dbo.Customers.
///
/// Identity, computed, rowversion and read-only columns
/// are absent: the server owns them. A non-null column
/// without a default is required; a nullable or defaulted
/// column is optional, and omitting it means SQL DEFAULT.
@immutable
class CustomerRowBaseCreate {
  const CustomerRowBaseCreate({
    required this.code,
    required this.name,
    this.city,
    required this.isActive,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final String code;
  final String name;

  /// Nullable.
  final String? city;
  final bool isActive;

  /// Has a SQL DEFAULT.
  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue? createdAt;

  /// Nullable.
  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue? updatedAt;

  /// Nullable.
  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue? deletedAt;

  /// Builds the write assignments for [MssqlRepository.insert].
  MssqlWriteAssignments toAssignments(MssqlTableBinding<Object?> binding) {
    final values = <String, MssqlWriteValue>{};
    values['Code'] = MssqlBoundValue(binding.column('Code')!.bind(code));
    values['Name'] = MssqlBoundValue(binding.column('Name')!.bind(name));
    if (city != null || binding.column('City')!.nullable) {
      values['City'] = MssqlBoundValue(binding.column('City')!.bind(city));
    }
    values['IsActive'] = MssqlBoundValue(
      binding.column('IsActive')!.bind(isActive),
    );
    if (createdAt != null || binding.column('CreatedAt')!.nullable) {
      values['CreatedAt'] = MssqlBoundValue(
        binding.column('CreatedAt')!.bind(createdAt),
      );
    }
    if (updatedAt != null || binding.column('UpdatedAt')!.nullable) {
      values['UpdatedAt'] = MssqlBoundValue(
        binding.column('UpdatedAt')!.bind(updatedAt),
      );
    }
    if (deletedAt != null || binding.column('DeletedAt')!.nullable) {
      values['DeletedAt'] = MssqlBoundValue(
        binding.column('DeletedAt')!.bind(deletedAt),
      );
    }
    return MssqlWriteAssignments(values);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerRowBaseCreate &&
          other.code == code &&
          other.name == name &&
          other.city == city &&
          other.isActive == isActive &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    code,
    name,
    city,
    isActive,
    createdAt,
    updatedAt,
    deletedAt,
  ]);

  @override
  String toString() =>
      'CustomerRowBaseCreate(code: $code, name: $name, city: $city, isActive: $isActive, createdAt: $createdAt, updatedAt: $updatedAt, deletedAt: $deletedAt)';
}

/// A partial update of dbo.Customers.
///
/// Each field is a [Field]: [Field.absent] means "don't
/// touch", [Field.value] means "set to this". A nullable
/// column accepts `Field<T?>.value(null)` to clear it;
/// a non-null column's `Field<T>` cannot carry null.
@immutable
class CustomerRowBasePatch {
  const CustomerRowBasePatch({
    this.code = const Field.absent(),
    this.name = const Field.absent(),
    this.city = const Field.absent(),
    this.isActive = const Field.absent(),
    this.createdAt = const Field.absent(),
    this.updatedAt = const Field.absent(),
    this.deletedAt = const Field.absent(),
  });

  final Field<String> code;
  final Field<String> name;

  /// Nullable.
  final Field<String?> city;
  final Field<bool> isActive;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final Field<MssqlDateTimeValue> createdAt;

  /// Nullable.
  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final Field<MssqlDateTimeValue?> updatedAt;

  /// Nullable.
  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final Field<MssqlDateTimeValue?> deletedAt;

  /// Builds the write assignments for [MssqlRepository.update] / [MssqlRepository.updateWhere].
  MssqlWriteAssignments toAssignments(MssqlTableBinding<Object?> binding) {
    final values = <String, MssqlWriteValue>{};
    if (code.isPresent) {
      values['Code'] = MssqlBoundValue(
        binding.column('Code')!.bind(code.value),
      );
    }
    if (name.isPresent) {
      values['Name'] = MssqlBoundValue(
        binding.column('Name')!.bind(name.value),
      );
    }
    if (city.isPresent) {
      values['City'] = MssqlBoundValue(
        binding.column('City')!.bind(city.value),
      );
    }
    if (isActive.isPresent) {
      values['IsActive'] = MssqlBoundValue(
        binding.column('IsActive')!.bind(isActive.value),
      );
    }
    if (createdAt.isPresent) {
      values['CreatedAt'] = MssqlBoundValue(
        binding.column('CreatedAt')!.bind(createdAt.value),
      );
    }
    if (updatedAt.isPresent) {
      values['UpdatedAt'] = MssqlBoundValue(
        binding.column('UpdatedAt')!.bind(updatedAt.value),
      );
    }
    if (deletedAt.isPresent) {
      values['DeletedAt'] = MssqlBoundValue(
        binding.column('DeletedAt')!.bind(deletedAt.value),
      );
    }
    return MssqlWriteAssignments(values);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerRowBasePatch &&
          other.code == code &&
          other.name == name &&
          other.city == city &&
          other.isActive == isActive &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    code,
    name,
    city,
    isActive,
    createdAt,
    updatedAt,
    deletedAt,
  ]);

  @override
  String toString() =>
      'CustomerRowBasePatch(code: $code, name: $name, city: $city, isActive: $isActive, createdAt: $createdAt, updatedAt: $updatedAt, deletedAt: $deletedAt)';
}

/// Unique keys of dbo.Customers that getOrCreate may use.
///
/// Filtered and disabled indexes are omitted: they do not make a row unique across the table.
abstract final class CustomerUnique {
  /// `UQ_Customers_Code` on Code.
  static MssqlUniqueMatch code(String code) => MssqlUniqueMatch(
    indexName: 'UQ_Customers_Code',
    values: <String, Object?>{'Code': code},
  );
}

/// Typed column references for dbo.Customers.
abstract final class Customer {
  static const String table = 'dbo.Customers';

  /// Which table these columns belong to.
  ///
  /// The columns below name this rather than writing
  /// `[dbo].[Customers]` into
  /// themselves, so that a query that aliases the table, or
  /// one pointed at another schema, still refers to the
  /// source it actually has.
  static const MssqlSourceRef source = MssqlSourceRef(
    schema: 'dbo',
    table: 'Customers',
  );

  /// `dbo.Customers.Id` — int, NOT NULL, IDENTITY, read-only.
  static final MssqlIntColumn id = column$id(source);

  /// `dbo.Customers.Code` — nvarchar, NOT NULL.
  static final MssqlStringColumn code = column$code(source);

  /// `dbo.Customers.Name` — nvarchar, NOT NULL.
  static final MssqlStringColumn name = column$name(source);

  /// `dbo.Customers.City` — nvarchar, nullable.
  static final MssqlStringColumn city = column$city(source);

  /// `dbo.Customers.IsActive` — bit, NOT NULL.
  static final MssqlBoolColumn isActive = column$isActive(source);

  /// `dbo.Customers.CreatedAt` — datetime2, NOT NULL, has a default.
  static final MssqlDateTimeValueColumn createdAt = column$createdAt(source);

  /// `dbo.Customers.UpdatedAt` — datetime2, nullable.
  static final MssqlDateTimeValueColumn updatedAt = column$updatedAt(source);

  /// `dbo.Customers.DeletedAt` — datetime2, nullable.
  static final MssqlDateTimeValueColumn deletedAt = column$deletedAt(source);

  /// The same columns bound to another source.
  ///
  /// What `at(schema:, table:)` needs: the concrete column
  /// class is kept, so a rebound column offers the same
  /// predicates as the generated one.

  static MssqlIntColumn column$id(MssqlSourceRef source) => MssqlIntColumn.of(
    source: source,
    name: 'Id',
    quotedName: '[Id]',
    columnType: MssqlColumnType(
      type: MssqlType.int32,
      size: 0,
      precision: 0,
      scale: 0,
      nullable: false,
      columnName: 'Id',
    ),
  );

  static MssqlStringColumn column$code(MssqlSourceRef source) =>
      MssqlStringColumn.of(
        source: source,
        name: 'Code',
        quotedName: '[Code]',
        columnType: MssqlColumnType(
          type: MssqlType.nvarchar,
          size: 20,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'Code',
        ),
      );

  static MssqlStringColumn column$name(MssqlSourceRef source) =>
      MssqlStringColumn.of(
        source: source,
        name: 'Name',
        quotedName: '[Name]',
        columnType: MssqlColumnType(
          type: MssqlType.nvarchar,
          size: 100,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'Name',
        ),
      );

  static MssqlStringColumn column$city(MssqlSourceRef source) =>
      MssqlStringColumn.of(
        source: source,
        name: 'City',
        quotedName: '[City]',
        columnType: MssqlColumnType(
          type: MssqlType.nvarchar,
          size: 50,
          precision: 0,
          scale: 0,
          nullable: true,
          columnName: 'City',
        ),
      );

  static MssqlBoolColumn column$isActive(MssqlSourceRef source) =>
      MssqlBoolColumn.of(
        source: source,
        name: 'IsActive',
        quotedName: '[IsActive]',
        columnType: MssqlColumnType(
          type: MssqlType.bit,
          size: 0,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'IsActive',
        ),
      );

  static MssqlDateTimeValueColumn column$createdAt(MssqlSourceRef source) =>
      MssqlDateTimeValueColumn.of(
        source: source,
        name: 'CreatedAt',
        quotedName: '[CreatedAt]',
        columnType: MssqlColumnType(
          type: MssqlType.dateTime2,
          size: 0,
          precision: 0,
          scale: 7,
          nullable: false,
          columnName: 'CreatedAt',
        ),
      );

  static MssqlDateTimeValueColumn column$updatedAt(MssqlSourceRef source) =>
      MssqlDateTimeValueColumn.of(
        source: source,
        name: 'UpdatedAt',
        quotedName: '[UpdatedAt]',
        columnType: MssqlColumnType(
          type: MssqlType.dateTime2,
          size: 0,
          precision: 0,
          scale: 7,
          nullable: true,
          columnName: 'UpdatedAt',
        ),
      );

  static MssqlDateTimeValueColumn column$deletedAt(MssqlSourceRef source) =>
      MssqlDateTimeValueColumn.of(
        source: source,
        name: 'DeletedAt',
        quotedName: '[DeletedAt]',
        columnType: MssqlColumnType(
          type: MssqlType.dateTime2,
          size: 0,
          precision: 0,
          scale: 7,
          nullable: true,
          columnName: 'DeletedAt',
        ),
      );
}

/// Relations of dbo.Customers, from its foreign
/// keys. Pass these to `include:` to load them eagerly.
abstract final class CustomerRel {
  static MssqlRelation<CustomerRow, OrderRow> get orders =>
      MssqlRelation<CustomerRow, OrderRow>(
        name: 'orders',
        kind: MssqlRelationKind.hasMany,
        targetBinding: OrderRepositoryBase.tableBinding,
        localColumns: const <String>['Id'],
        foreignColumns: const <String>['CustomerId'],
      );
}

/// Typed include modifiers for CustomerRow.orders.
extension CustomerOrdersInclude on MssqlRelation<CustomerRow, OrderRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<CustomerRow, OrderRow> where(
    MssqlCondition Function(OrderFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const OrderFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<CustomerRow, OrderRow> orderBy(
    List<MssqlOrder> Function(OrderFields fields) ordering,
  ) => ordered(ordering(const OrderFields()));

  /// Nested includes of the target.
  MssqlRelation<CustomerRow, OrderRow> include(
    Iterable<MssqlRelation<OrderRow, Object?>> Function(OrderFields fields)
    nested,
  ) => withNested(nested(const OrderFields()));
}

/// Typed SQL columns of dbo.Customers.
///
/// A row this is not: there is no `id` integer here, only
/// the column that becomes `WHERE [Id] = @p`. The query
/// callback takes this type so `o` completes to columns.
class CustomerFields {
  /// Columns of the generated table, or — with a
  /// [MssqlSourceRef] — of the same table under another
  /// schema or name, as `at(schema:, table:)` produces.
  const CustomerFields([this._source]);

  final MssqlSourceRef? _source;

  /// Which source these columns resolve against.
  MssqlSourceRef get source => _source ?? Customer.source;

  /// `dbo.Customers.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// `whereId` ANDs an equality on this column.
  MssqlIntColumn get id {
    final ref = _source;
    return ref == null ? Customer.id : Customer.column$id(ref);
  }

  /// `dbo.Customers.Code` — nvarchar, NOT NULL.
  ///
  /// `whereCode` ANDs an equality on this column.
  MssqlStringColumn get code {
    final ref = _source;
    return ref == null ? Customer.code : Customer.column$code(ref);
  }

  /// `dbo.Customers.Name` — nvarchar, NOT NULL.
  ///
  /// `whereName` ANDs an equality on this column.
  MssqlStringColumn get name {
    final ref = _source;
    return ref == null ? Customer.name : Customer.column$name(ref);
  }

  /// `dbo.Customers.City` — nvarchar, nullable.
  ///
  /// `whereCity` ANDs an equality on this column.
  MssqlStringColumn get city {
    final ref = _source;
    return ref == null ? Customer.city : Customer.column$city(ref);
  }

  /// `dbo.Customers.IsActive` — bit, NOT NULL.
  ///
  /// `whereIsActive` ANDs an equality on this column.
  MssqlBoolColumn get isActive {
    final ref = _source;
    return ref == null ? Customer.isActive : Customer.column$isActive(ref);
  }

  /// `dbo.Customers.CreatedAt` — datetime2, NOT NULL, has a default.
  ///
  /// `whereCreatedAt` ANDs an equality on this column.
  MssqlDateTimeValueColumn get createdAt {
    final ref = _source;
    return ref == null ? Customer.createdAt : Customer.column$createdAt(ref);
  }

  /// `dbo.Customers.UpdatedAt` — datetime2, nullable.
  ///
  /// `whereUpdatedAt` ANDs an equality on this column.
  MssqlDateTimeValueColumn get updatedAt {
    final ref = _source;
    return ref == null ? Customer.updatedAt : Customer.column$updatedAt(ref);
  }

  /// `dbo.Customers.DeletedAt` — datetime2, nullable.
  ///
  /// `whereDeletedAt` ANDs an equality on this column.
  MssqlDateTimeValueColumn get deletedAt {
    final ref = _source;
    return ref == null ? Customer.deletedAt : Customer.column$deletedAt(ref);
  }

  /// Include handle for `orders`.
  ///
  /// `include((o) => [o.orders])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<CustomerRow, OrderRow> get orders => CustomerRel.orders;
}

/// Query over dbo.Customers.
///
/// Every entity-preserving call returns [CustomerQuery], so a user
/// extension (`extension on CustomerQuery`) stays in the chain.
/// `whereX` shortcuts AND an equality; OR stays in
/// `where((o) => … | …)`.
class CustomerQuery
    extends MssqlEntityQuery<CustomerRow, CustomerFields, CustomerQuery> {
  CustomerQuery(super.context, [super.state, super.included]);

  @override
  /// Columns bound to whatever source this query has.
  ///
  /// The constant instance for the generated table, and a
  /// rebound one after `at(schema:, table:)`, so a
  /// predicate written after a rebind names the table this
  /// statement actually reads.
  CustomerFields get fields => binding.sourceRef == Customer.source
      ? const CustomerFields()
      : CustomerFields(binding.sourceRef);

  @override
  CustomerQuery recreate(
    MssqlQueryState state,
    List<MssqlRelation<CustomerRow, Object?>> included,
  ) => CustomerQuery(context, state, included);

  @override
  CustomerQuery recreateAt(
    MssqlQueryContext<CustomerRow> context,
    MssqlQueryState state,
    List<MssqlRelation<CustomerRow, Object?>> included,
  ) => CustomerQuery(context, state, included);

  /// `dbo.Customers.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// ANDs `Id = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CustomerQuery whereId(int value) =>
      rebuild(state.where_(fields.id.eq(value)));

  /// `dbo.Customers.Code` — nvarchar, NOT NULL.
  ///
  /// ANDs `Code = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CustomerQuery whereCode(String value) =>
      rebuild(state.where_(fields.code.eq(value)));

  /// `dbo.Customers.Name` — nvarchar, NOT NULL.
  ///
  /// ANDs `Name = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CustomerQuery whereName(String value) =>
      rebuild(state.where_(fields.name.eq(value)));

  /// `dbo.Customers.City` — nvarchar, nullable.
  ///
  /// ANDs `City = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CustomerQuery whereCity(String value) =>
      rebuild(state.where_(fields.city.eq(value)));

  /// `dbo.Customers.IsActive` — bit, NOT NULL.
  ///
  /// ANDs `IsActive = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CustomerQuery whereIsActive(bool value) =>
      rebuild(state.where_(fields.isActive.eq(value)));

  /// `dbo.Customers.CreatedAt` — datetime2, NOT NULL, has a default.
  ///
  /// ANDs `CreatedAt = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CustomerQuery whereCreatedAt(MssqlDateTimeValue value) =>
      rebuild(state.where_(fields.createdAt.eq(value)));

  /// `dbo.Customers.UpdatedAt` — datetime2, nullable.
  ///
  /// ANDs `UpdatedAt = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CustomerQuery whereUpdatedAt(MssqlDateTimeValue value) =>
      rebuild(state.where_(fields.updatedAt.eq(value)));

  /// `dbo.Customers.DeletedAt` — datetime2, nullable.
  ///
  /// ANDs `DeletedAt = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CustomerQuery whereDeletedAt(MssqlDateTimeValue value) =>
      rebuild(state.where_(fields.deletedAt.eq(value)));

  /// UI sort: [column] must be a field of this table.
  ///
  /// A string from a query-string is not passed to SQL. The
  /// allowlist is the generated fields; anything else is an
  /// [ArgumentError] naming the legal keys.
  CustomerQuery orderByNamed(String column, {bool descending = false}) {
    switch (column) {
      case 'id':
      case 'Id':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.id.desc() : o.id.asc()],
        );
      case 'code':
      case 'Code':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.code.desc() : o.code.asc()],
        );
      case 'name':
      case 'Name':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.name.desc() : o.name.asc()],
        );
      case 'city':
      case 'City':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.city.desc() : o.city.asc()],
        );
      case 'isActive':
      case 'IsActive':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.isActive.desc() : o.isActive.asc(),
          ],
        );
      case 'createdAt':
      case 'CreatedAt':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.createdAt.desc() : o.createdAt.asc(),
          ],
        );
      case 'updatedAt':
      case 'UpdatedAt':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.updatedAt.desc() : o.updatedAt.asc(),
          ],
        );
      case 'deletedAt':
      case 'DeletedAt':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.deletedAt.desc() : o.deletedAt.asc(),
          ],
        );
      default:
        throw ArgumentError.value(
          column,
          'column',
          'CustomerQuery cannot sort by "$column". Allowed: id, code, name, city, isActive, createdAt, updatedAt, deletedAt.',
        );
    }
  }

  /// Writes against `orders` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.orders)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<CustomerRow, OrderRow> ordersOf(CustomerRow parent) =>
      related(parent, (f) => f.orders);

  /// Insert or return the live row with this unique Code.
  ///
  /// Insert-first; a 2601/2627 on `UQ_Customers_Code` reads the winner. A collision on a different unique key is rethrown.
  Future<CustomerRow> getOrCreateByCode(
    String code, {
    required String name,
    String? city,
    required bool isActive,
    MssqlDateTimeValue? createdAt,
    MssqlDateTimeValue? updatedAt,
    MssqlDateTimeValue? deletedAt,
    bool restoreExisting = false,
    bool includeDeleted = false,
  }) {
    return getOrCreate(
      key: CustomerUnique.code(code),
      create: CustomerRowBaseCreate(
        code: code,
        name: name,
        city: city,
        isActive: isActive,
        createdAt: createdAt,
        updatedAt: updatedAt,
        deletedAt: deletedAt,
      ).toAssignments(binding.erase()),
      restoreExisting: restoreExisting,
      includeDeleted: includeDeleted,
    );
  }

  /// Partial update of matching rows.
  ///
  /// Absent patch fields are not named. [expectedVersion] is the rowversion token; a table without one refuses it.
  Future<int> update(
    CustomerRowBasePatch patch, {
    Object? expectedVersion,
    int? expectAffected,
  }) => updateValues(
    patch.toAssignments(binding.erase()),
    expectedVersion: expectedVersion,
    expectAffected: expectAffected,
  );

  /// Inserts [input] and returns the stored row.
  ///
  /// Absent fields become SQL DEFAULT. Binding null would overwrite the default.
  Future<CustomerRow> create(CustomerRowBaseCreate input) =>
      createValues(input.toAssignments(binding.erase()));

  /// Batched insert. Never switches to BCP on its own.
  Future<MssqlCreateManyResult<CustomerRow>> createMany(
    List<CustomerRowBaseCreate> rows, {
    MssqlCreateManyStrategy strategy = MssqlCreateManyStrategy.insertValues,
    MssqlBulkOptions bulk = const MssqlBulkOptions(),
    bool atomic = true,
    bool returnRows = true,
  }) => createManyValues(
    <MssqlWriteAssignments>[
      for (final row in rows) row.toAssignments(binding.erase()),
    ],
    strategy: strategy,
    bulk: bulk,
    atomic: atomic,
    returnRows: returnRows,
  );

  /// Staging JOIN update keyed by Id.
  Future<int> updateMany(
    Map<int, CustomerRowBasePatch> byKey, {
    int? expectAffected,
  }) => updateManyKeyed(<MssqlKeyedPatch>[
    for (final entry in byKey.entries)
      MssqlKeyedPatch(
        key: <String, Object?>{'Id': entry.key},
        patch: entry.value.toAssignments(binding.erase()),
      ),
  ], expectAffected: expectAffected);

  /// Explicit graph insert in one transaction.
  ///
  /// Only the named relations are written. There is no cascade delete.
  Future<CustomerRow> createGraph(
    CustomerRowBaseCreate input, {
    List<OrderRowBaseCreate>? orders,
    MssqlCycleWrite cycleWrite = MssqlCycleWrite.refuse,
  }) {
    final ordersInput = orders;
    return createGraphValues(
      MssqlGraphInsert(
        input.toAssignments(binding.erase()),
        related: <MssqlGraphRelation>[
          if (ordersInput != null)
            MssqlGraphRelation(
              fields.orders.asInclude,
              <MssqlGraphInsert<Object?>>[
                for (final item in ordersInput)
                  MssqlGraphInsert(
                    item.toAssignments(fields.orders.targetBinding.erase()),
                  ),
              ],
            ),
        ],
      ),
      cycle: cycleWrite,
    );
  }

  /// The row with this primary key, or null.
  Future<CustomerRow?> find(int key) => whereId(key).first();

  /// The row with this primary key, or not-found.
  Future<CustomerRow> getById(int key) => whereId(key).firstOrFail();
}

/// Reads and writes dbo.Customers.
class CustomerRepositoryBase extends MssqlRepository<CustomerRow, int> {
  /// [schema] and [table] point this repository at another
  /// table of the same shape — Eloquent's `$table`.
  CustomerRepositoryBase(
    super.session, {
    super.dialect,
    super.schema,
    super.table,
  }) : super(binding: tableBinding);

  /// Named tableBinding rather than binding: a static cannot
  /// share a name with an inherited instance member.
  static final MssqlTableBinding<CustomerRow> tableBinding =
      MssqlTableBinding<CustomerRow>(
        schema: 'dbo',
        table: 'Customers',
        primaryKey: const <String>['Id'],
        identityColumn: 'Id',
        insertStrategy: MssqlInsertStrategy.outputInserted,
        decimalMode: MssqlDecimalMode.exact,
        schemaFingerprint:
            '1f547b82eb1a24bdc6879a30df963bb6698c24f9ae1246ddd0c587fcc81cbbde',
        apiVersion: 2,
        softDelete: const MssqlSoftDelete(column: 'DeletedAt'),
        timestamps: const MssqlTimestamps(
          createdColumn: 'CreatedAt',
          updatedColumn: 'UpdatedAt',
        ),
        columns: <MssqlBoundColumn>[
          MssqlBoundColumn(
            name: 'Id',
            type: MssqlType.int32,
            isIdentity: true,
            maxLength: 0,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'Code',
            type: MssqlType.nvarchar,
            maxLength: 40,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'Name',
            type: MssqlType.nvarchar,
            maxLength: 200,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'City',
            type: MssqlType.nvarchar,
            nullable: true,
            maxLength: 100,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'IsActive',
            type: MssqlType.bit,
            maxLength: 0,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'CreatedAt',
            type: MssqlType.dateTime2,
            hasDefault: true,
            maxLength: 0,
            precision: 0,
            scale: 7,
          ),
          MssqlBoundColumn(
            name: 'UpdatedAt',
            type: MssqlType.dateTime2,
            nullable: true,
            maxLength: 0,
            precision: 0,
            scale: 7,
          ),
          MssqlBoundColumn(
            name: 'DeletedAt',
            type: MssqlType.dateTime2,
            nullable: true,
            maxLength: 0,
            precision: 0,
            scale: 7,
          ),
        ],
        fromRow: CustomerRowBase.fromRow,
        toColumns: (row) => row.toColumns(),
        readColumn: (row, name) => row.columnValue(name),
        applyRelations: (row, relations) => row.withRelations(relations),
        isRelationLoaded: (row, name) => row.isLoaded(name),
      );
}
