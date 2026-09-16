// GENERATED — do not edit. Rewritten on every run.
//
// Source: dbo.Orders
// Generator: mssql_orm_dev 0.1.1
// API contract: 2
// Schema fingerprint: f35f869b6dac9c73712f57a415d6bc1f70c073ad42034675251f211a36b3983a
//
// Foreign keys:
//   CustomerId -> dbo.Customers (Id)
//
// Application code belongs in ../models/orders.dart,
// which this generator creates once and never touches again.

import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import '../models/customers.dart';
import '../models/order_lines.dart';
import '../models/orders.dart';

/// One row of dbo.Orders.
///
/// `copyWith` and `==` cover the fields declared here. A
/// field added to OrderRow is not carried by either, which
/// is inherent to the split; adding behaviour is free.
@immutable
class OrderRowBase {
  const OrderRowBase({
    required this.id,
    required this.customerId,
    required this.code,
    required this.status,
    required this.total,
    required this.placedAt,
    required this.createdAt,
    this.updatedAt,
    this.deletedAt,
    CustomerRow? customer,
    List<OrderLineRow>? lines,
    Set<String> loadedRelations = const <String>{},
    Map<String, int> truncatedRelations = const <String, int>{},
  }) : _customer = customer,
       _lines = lines,
       _loadedRelations = loadedRelations,
       _truncatedRelations = truncatedRelations;

  /// IDENTITY.
  final int id;
  final int customerId;
  final String code;
  final String status;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final MssqlDecimal total;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue placedAt;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue createdAt;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue? updatedAt;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue? deletedAt;

  final CustomerRow? _customer;
  final List<OrderLineRow>? _lines;
  final Set<String> _loadedRelations;
  final Map<String, int> _truncatedRelations;

  /// Whether [relation] was loaded for this row.
  ///
  /// True for loaded-null and loaded-empty. Truncated is
  /// still loaded; [isTruncated] is the incomplete flag.
  bool isLoaded(String relation) => _loadedRelations.contains(relation);

  /// Typed form of [isLoaded]: the handle, not a string.
  bool relationLoaded<TChild>(MssqlRelation<OrderRow, TChild> relation) =>
      isLoaded(relation.name);

  /// Whether [relation] hit maxLoadedRows.
  bool isTruncated(String relation) =>
      _truncatedRelations.containsKey(relation);

  /// Throws when the relation was not loaded, so that a
  /// null answer means exactly one thing: there is no
  /// counterpart. Without the guard, forgetting to load
  /// would read as "no counterpart" and quietly give the
  /// wrong answer.
  CustomerRow? get customer {
    if (!_loadedRelations.contains('customer')) {
      throw MssqlRelationNotLoadedException('dbo.Orders', 'customer');
    }
    if (_truncatedRelations.containsKey('customer')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.Orders',
        relation: 'customer',
        limit: _truncatedRelations['customer']!,
      );
    }
    return _customer;
  }

  /// Throws when the relation was not loaded. An empty
  /// list means loaded and none.
  List<OrderLineRow> get lines {
    if (!_loadedRelations.contains('lines')) {
      throw MssqlRelationNotLoadedException('dbo.Orders', 'lines');
    }
    if (_truncatedRelations.containsKey('lines')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.Orders',
        relation: 'lines',
        limit: _truncatedRelations['lines']!,
      );
    }
    return _lines ?? const [];
  }

  /// Reads a row by ordinal after checking column names.
  ///
  /// Name lookup on every field would rebuild a map the
  /// driver already has. Extra trailing columns are allowed
  /// so a withCount projection can append aggregates.
  static const List<String> columnOrder = <String>[
    'Id',
    'CustomerId',
    'Code',
    'Status',
    'Total',
    'PlacedAt',
    'CreatedAt',
    'UpdatedAt',
    'DeletedAt',
  ];
  static OrderRow fromRow(MssqlRow row) {
    row.assertOrdinalNames(columnOrder);
    return OrderRow(
      id: (row.at(0)! as num).toInt(),
      customerId: (row.at(1)! as num).toInt(),
      code: row.at(2)! as String,
      status: row.at(3)! as String,
      total: row.at(4)! as MssqlDecimal,
      placedAt: row.at(5)! as MssqlDateTimeValue,
      createdAt: row.at(6)! as MssqlDateTimeValue,
      updatedAt: row.at(7) as MssqlDateTimeValue?,
      deletedAt: row.at(8) as MssqlDateTimeValue?,
    );
  }

  /// One column of this row, by SQL name.
  Object? columnValue(String name) => switch (name) {
    'Id' => id,
    'CustomerId' => customerId,
    'Code' => code,
    'Status' => status,
    'Total' => total,
    'PlacedAt' => placedAt,
    'CreatedAt' => createdAt,
    'UpdatedAt' => updatedAt,
    'DeletedAt' => deletedAt,
    _ => throw ArgumentError.value(
      name,
      'name',
      'OrderRow has no column named "$name".',
    ),
  };

  Map<String, Object?> toColumns() => <String, Object?>{
    'Id': id,
    'CustomerId': customerId,
    'Code': code,
    'Status': status,
    'Total': total,
    'PlacedAt': placedAt,
    'CreatedAt': createdAt,
    'UpdatedAt': updatedAt,
    'DeletedAt': deletedAt,
  };

  OrderRow copyWith({
    int? id,
    int? customerId,
    String? code,
    String? status,
    MssqlDecimal? total,
    MssqlDateTimeValue? placedAt,
    MssqlDateTimeValue? createdAt,
    MssqlDateTimeValue? updatedAt,
    MssqlDateTimeValue? deletedAt,
  }) => OrderRow(
    id: id ?? this.id,
    customerId: customerId ?? this.customerId,
    code: code ?? this.code,
    status: status ?? this.status,
    total: total ?? this.total,
    placedAt: placedAt ?? this.placedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt ?? this.deletedAt,
    customer: _customer,
    lines: _lines,
    loadedRelations: _loadedRelations,
    truncatedRelations: _truncatedRelations,
  );

  /// Returns a copy carrying the loaded relations.
  ///
  /// Rows are immutable, so the loader cannot write into
  /// one; it asks for a new row instead.
  OrderRow withRelations(Map<String, Object?> relations) => OrderRow(
    id: id,
    customerId: customerId,
    code: code,
    status: status,
    total: total,
    placedAt: placedAt,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deletedAt: deletedAt,
    customer: relations.containsKey('customer')
        ? relations['customer'] as CustomerRow?
        : _customer,
    lines: relations.containsKey('lines')
        ? (relations['lines']! as List<Object?>).cast<OrderLineRow>()
        : _lines,
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
      other is OrderRowBase &&
          other.id == id &&
          other.customerId == customerId &&
          other.code == code &&
          other.status == status &&
          other.total == total &&
          other.placedAt == placedAt &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    customerId,
    code,
    status,
    total,
    placedAt,
    createdAt,
    updatedAt,
    deletedAt,
  ]);

  @override
  String toString() =>
      'OrderRow(id: $id, customerId: $customerId, code: $code, status: $status, total: $total, placedAt: $placedAt, createdAt: $createdAt, updatedAt: $updatedAt, deletedAt: $deletedAt)';
}

/// Values for inserting one row into dbo.Orders.
///
/// Identity, computed, rowversion and read-only columns
/// are absent: the server owns them. A non-null column
/// without a default is required; a nullable or defaulted
/// column is optional, and omitting it means SQL DEFAULT.
@immutable
class OrderRowBaseCreate {
  const OrderRowBaseCreate({
    required this.customerId,
    required this.code,
    required this.status,
    required this.total,
    required this.placedAt,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  final int customerId;
  final String code;
  final String status;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final MssqlDecimal total;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final MssqlDateTimeValue placedAt;

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
    values['CustomerId'] = MssqlBoundValue(
      binding.column('CustomerId')!.bind(customerId),
    );
    values['Code'] = MssqlBoundValue(binding.column('Code')!.bind(code));
    values['Status'] = MssqlBoundValue(binding.column('Status')!.bind(status));
    values['Total'] = MssqlBoundValue(binding.column('Total')!.bind(total));
    values['PlacedAt'] = MssqlBoundValue(
      binding.column('PlacedAt')!.bind(placedAt),
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
      other is OrderRowBaseCreate &&
          other.customerId == customerId &&
          other.code == code &&
          other.status == status &&
          other.total == total &&
          other.placedAt == placedAt &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    customerId,
    code,
    status,
    total,
    placedAt,
    createdAt,
    updatedAt,
    deletedAt,
  ]);

  @override
  String toString() =>
      'OrderRowBaseCreate(customerId: $customerId, code: $code, status: $status, total: $total, placedAt: $placedAt, createdAt: $createdAt, updatedAt: $updatedAt, deletedAt: $deletedAt)';
}

/// A partial update of dbo.Orders.
///
/// Each field is a [Field]: [Field.absent] means "don't
/// touch", [Field.value] means "set to this". A nullable
/// column accepts `Field<T?>.value(null)` to clear it;
/// a non-null column's `Field<T>` cannot carry null.
@immutable
class OrderRowBasePatch {
  const OrderRowBasePatch({
    this.customerId = const Field.absent(),
    this.code = const Field.absent(),
    this.status = const Field.absent(),
    this.total = const Field.absent(),
    this.placedAt = const Field.absent(),
    this.createdAt = const Field.absent(),
    this.updatedAt = const Field.absent(),
    this.deletedAt = const Field.absent(),
  });

  final Field<int> customerId;
  final Field<String> code;
  final Field<String> status;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final Field<MssqlDecimal> total;

  /// datetime2(7) resolves to 100ns and DateTime to microseconds, so this stays the driver's own type. Call toDateTime() if the extra digits do not matter.
  final Field<MssqlDateTimeValue> placedAt;

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
    if (customerId.isPresent) {
      values['CustomerId'] = MssqlBoundValue(
        binding.column('CustomerId')!.bind(customerId.value),
      );
    }
    if (code.isPresent) {
      values['Code'] = MssqlBoundValue(
        binding.column('Code')!.bind(code.value),
      );
    }
    if (status.isPresent) {
      values['Status'] = MssqlBoundValue(
        binding.column('Status')!.bind(status.value),
      );
    }
    if (total.isPresent) {
      values['Total'] = MssqlBoundValue(
        binding.column('Total')!.bind(total.value),
      );
    }
    if (placedAt.isPresent) {
      values['PlacedAt'] = MssqlBoundValue(
        binding.column('PlacedAt')!.bind(placedAt.value),
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
      other is OrderRowBasePatch &&
          other.customerId == customerId &&
          other.code == code &&
          other.status == status &&
          other.total == total &&
          other.placedAt == placedAt &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt &&
          other.deletedAt == deletedAt;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    customerId,
    code,
    status,
    total,
    placedAt,
    createdAt,
    updatedAt,
    deletedAt,
  ]);

  @override
  String toString() =>
      'OrderRowBasePatch(customerId: $customerId, code: $code, status: $status, total: $total, placedAt: $placedAt, createdAt: $createdAt, updatedAt: $updatedAt, deletedAt: $deletedAt)';
}

/// Unique keys of dbo.Orders that getOrCreate may use.
///
/// Filtered and disabled indexes are omitted: they do not make a row unique across the table.
abstract final class OrderUnique {
  /// `UQ_Orders_Code` on Code.
  static MssqlUniqueMatch code(String code) => MssqlUniqueMatch(
    indexName: 'UQ_Orders_Code',
    values: <String, Object?>{'Code': code},
  );
}

/// Typed column references for dbo.Orders.
abstract final class Order {
  static const String table = 'dbo.Orders';

  /// Which table these columns belong to.
  ///
  /// The columns below name this rather than writing
  /// `[dbo].[Orders]` into
  /// themselves, so that a query that aliases the table, or
  /// one pointed at another schema, still refers to the
  /// source it actually has.
  static const MssqlSourceRef source = MssqlSourceRef(
    schema: 'dbo',
    table: 'Orders',
  );

  /// `dbo.Orders.Id` — int, NOT NULL, IDENTITY, read-only.
  static final MssqlIntColumn id = column$id(source);

  /// `dbo.Orders.CustomerId` — int, NOT NULL.
  static final MssqlIntColumn customerId = column$customerId(source);

  /// `dbo.Orders.Code` — nvarchar, NOT NULL.
  static final MssqlStringColumn code = column$code(source);

  /// `dbo.Orders.Status` — nvarchar, NOT NULL.
  static final MssqlStringColumn status = column$status(source);

  /// `dbo.Orders.Total` — decimal, NOT NULL.
  static final MssqlDecimalColumn total = column$total(source);

  /// `dbo.Orders.PlacedAt` — datetime2, NOT NULL.
  static final MssqlDateTimeValueColumn placedAt = column$placedAt(source);

  /// `dbo.Orders.CreatedAt` — datetime2, NOT NULL, has a default.
  static final MssqlDateTimeValueColumn createdAt = column$createdAt(source);

  /// `dbo.Orders.UpdatedAt` — datetime2, nullable.
  static final MssqlDateTimeValueColumn updatedAt = column$updatedAt(source);

  /// `dbo.Orders.DeletedAt` — datetime2, nullable.
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

  static MssqlIntColumn column$customerId(MssqlSourceRef source) =>
      MssqlIntColumn.of(
        source: source,
        name: 'CustomerId',
        quotedName: '[CustomerId]',
        columnType: MssqlColumnType(
          type: MssqlType.int32,
          size: 0,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'CustomerId',
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

  static MssqlStringColumn column$status(MssqlSourceRef source) =>
      MssqlStringColumn.of(
        source: source,
        name: 'Status',
        quotedName: '[Status]',
        columnType: MssqlColumnType(
          type: MssqlType.nvarchar,
          size: 10,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'Status',
        ),
      );

  static MssqlDecimalColumn column$total(MssqlSourceRef source) =>
      MssqlDecimalColumn.of(
        source: source,
        name: 'Total',
        quotedName: '[Total]',
        columnType: MssqlColumnType(
          type: MssqlType.decimal,
          size: 0,
          precision: 18,
          scale: 2,
          nullable: false,
          columnName: 'Total',
        ),
      );

  static MssqlDateTimeValueColumn column$placedAt(MssqlSourceRef source) =>
      MssqlDateTimeValueColumn.of(
        source: source,
        name: 'PlacedAt',
        quotedName: '[PlacedAt]',
        columnType: MssqlColumnType(
          type: MssqlType.dateTime2,
          size: 0,
          precision: 0,
          scale: 7,
          nullable: false,
          columnName: 'PlacedAt',
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

/// Relations of dbo.Orders, from its foreign
/// keys. Pass these to `include:` to load them eagerly.
abstract final class OrderRel {
  static MssqlRelation<OrderRow, CustomerRow> get customer =>
      MssqlRelation<OrderRow, CustomerRow>(
        name: 'customer',
        kind: MssqlRelationKind.belongsTo,
        targetBinding: CustomerRepositoryBase.tableBinding,
        localColumns: const <String>['CustomerId'],
        foreignColumns: const <String>['Id'],
      );
  static MssqlRelation<OrderRow, OrderLineRow> get lines =>
      MssqlRelation<OrderRow, OrderLineRow>(
        name: 'lines',
        kind: MssqlRelationKind.hasMany,
        targetBinding: OrderLineRepositoryBase.tableBinding,
        localColumns: const <String>['Id'],
        foreignColumns: const <String>['OrderId'],
      );
}

/// Typed include modifiers for OrderRow.customer.
extension OrderCustomerInclude on MssqlRelation<OrderRow, CustomerRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<OrderRow, CustomerRow> where(
    MssqlCondition Function(CustomerFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const CustomerFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<OrderRow, CustomerRow> orderBy(
    List<MssqlOrder> Function(CustomerFields fields) ordering,
  ) => ordered(ordering(const CustomerFields()));

  /// Nested includes of the target.
  MssqlRelation<OrderRow, CustomerRow> include(
    Iterable<MssqlRelation<CustomerRow, Object?>> Function(
      CustomerFields fields,
    )
    nested,
  ) => withNested(nested(const CustomerFields()));
}

/// Typed include modifiers for OrderRow.lines.
extension OrderLinesInclude on MssqlRelation<OrderRow, OrderLineRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<OrderRow, OrderLineRow> where(
    MssqlCondition Function(OrderLineFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const OrderLineFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<OrderRow, OrderLineRow> orderBy(
    List<MssqlOrder> Function(OrderLineFields fields) ordering,
  ) => ordered(ordering(const OrderLineFields()));

  /// Nested includes of the target.
  MssqlRelation<OrderRow, OrderLineRow> include(
    Iterable<MssqlRelation<OrderLineRow, Object?>> Function(
      OrderLineFields fields,
    )
    nested,
  ) => withNested(nested(const OrderLineFields()));
}

/// Typed SQL columns of dbo.Orders.
///
/// A row this is not: there is no `id` integer here, only
/// the column that becomes `WHERE [Id] = @p`. The query
/// callback takes this type so `o` completes to columns.
class OrderFields {
  /// Columns of the generated table, or — with a
  /// [MssqlSourceRef] — of the same table under another
  /// schema or name, as `at(schema:, table:)` produces.
  const OrderFields([this._source]);

  final MssqlSourceRef? _source;

  /// Which source these columns resolve against.
  MssqlSourceRef get source => _source ?? Order.source;

  /// `dbo.Orders.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// `whereId` ANDs an equality on this column.
  MssqlIntColumn get id {
    final ref = _source;
    return ref == null ? Order.id : Order.column$id(ref);
  }

  /// `dbo.Orders.CustomerId` — int, NOT NULL.
  ///
  /// `whereCustomerId` ANDs an equality on this column.
  MssqlIntColumn get customerId {
    final ref = _source;
    return ref == null ? Order.customerId : Order.column$customerId(ref);
  }

  /// `dbo.Orders.Code` — nvarchar, NOT NULL.
  ///
  /// `whereCode` ANDs an equality on this column.
  MssqlStringColumn get code {
    final ref = _source;
    return ref == null ? Order.code : Order.column$code(ref);
  }

  /// `dbo.Orders.Status` — nvarchar, NOT NULL.
  ///
  /// `whereStatus` ANDs an equality on this column.
  MssqlStringColumn get status {
    final ref = _source;
    return ref == null ? Order.status : Order.column$status(ref);
  }

  /// `dbo.Orders.Total` — decimal, NOT NULL.
  ///
  /// `whereTotal` ANDs an equality on this column.
  MssqlDecimalColumn get total {
    final ref = _source;
    return ref == null ? Order.total : Order.column$total(ref);
  }

  /// `dbo.Orders.PlacedAt` — datetime2, NOT NULL.
  ///
  /// `wherePlacedAt` ANDs an equality on this column.
  MssqlDateTimeValueColumn get placedAt {
    final ref = _source;
    return ref == null ? Order.placedAt : Order.column$placedAt(ref);
  }

  /// `dbo.Orders.CreatedAt` — datetime2, NOT NULL, has a default.
  ///
  /// `whereCreatedAt` ANDs an equality on this column.
  MssqlDateTimeValueColumn get createdAt {
    final ref = _source;
    return ref == null ? Order.createdAt : Order.column$createdAt(ref);
  }

  /// `dbo.Orders.UpdatedAt` — datetime2, nullable.
  ///
  /// `whereUpdatedAt` ANDs an equality on this column.
  MssqlDateTimeValueColumn get updatedAt {
    final ref = _source;
    return ref == null ? Order.updatedAt : Order.column$updatedAt(ref);
  }

  /// `dbo.Orders.DeletedAt` — datetime2, nullable.
  ///
  /// `whereDeletedAt` ANDs an equality on this column.
  MssqlDateTimeValueColumn get deletedAt {
    final ref = _source;
    return ref == null ? Order.deletedAt : Order.column$deletedAt(ref);
  }

  /// Include handle for `customer`.
  ///
  /// `include((o) => [o.customer])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<OrderRow, CustomerRow> get customer => OrderRel.customer;

  /// Include handle for `lines`.
  ///
  /// `include((o) => [o.lines])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<OrderRow, OrderLineRow> get lines => OrderRel.lines;
}

/// Query over dbo.Orders.
///
/// Every entity-preserving call returns [OrderQuery], so a user
/// extension (`extension on OrderQuery`) stays in the chain.
/// `whereX` shortcuts AND an equality; OR stays in
/// `where((o) => … | …)`.
class OrderQuery extends MssqlEntityQuery<OrderRow, OrderFields, OrderQuery> {
  OrderQuery(super.context, [super.state, super.included]);

  @override
  /// Columns bound to whatever source this query has.
  ///
  /// The constant instance for the generated table, and a
  /// rebound one after `at(schema:, table:)`, so a
  /// predicate written after a rebind names the table this
  /// statement actually reads.
  OrderFields get fields => binding.sourceRef == Order.source
      ? const OrderFields()
      : OrderFields(binding.sourceRef);

  @override
  OrderQuery recreate(
    MssqlQueryState state,
    List<MssqlRelation<OrderRow, Object?>> included,
  ) => OrderQuery(context, state, included);

  @override
  OrderQuery recreateAt(
    MssqlQueryContext<OrderRow> context,
    MssqlQueryState state,
    List<MssqlRelation<OrderRow, Object?>> included,
  ) => OrderQuery(context, state, included);

  /// `dbo.Orders.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// ANDs `Id = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderQuery whereId(int value) => rebuild(state.where_(fields.id.eq(value)));

  /// `dbo.Orders.CustomerId` — int, NOT NULL.
  ///
  /// ANDs `CustomerId = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderQuery whereCustomerId(int value) =>
      rebuild(state.where_(fields.customerId.eq(value)));

  /// `dbo.Orders.Code` — nvarchar, NOT NULL.
  ///
  /// ANDs `Code = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderQuery whereCode(String value) =>
      rebuild(state.where_(fields.code.eq(value)));

  /// `dbo.Orders.Status` — nvarchar, NOT NULL.
  ///
  /// ANDs `Status = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderQuery whereStatus(String value) =>
      rebuild(state.where_(fields.status.eq(value)));

  /// `dbo.Orders.Total` — decimal, NOT NULL.
  ///
  /// ANDs `Total = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderQuery whereTotal(MssqlDecimal value) =>
      rebuild(state.where_(fields.total.eq(value)));

  /// `dbo.Orders.PlacedAt` — datetime2, NOT NULL.
  ///
  /// ANDs `PlacedAt = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderQuery wherePlacedAt(MssqlDateTimeValue value) =>
      rebuild(state.where_(fields.placedAt.eq(value)));

  /// `dbo.Orders.CreatedAt` — datetime2, NOT NULL, has a default.
  ///
  /// ANDs `CreatedAt = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderQuery whereCreatedAt(MssqlDateTimeValue value) =>
      rebuild(state.where_(fields.createdAt.eq(value)));

  /// `dbo.Orders.UpdatedAt` — datetime2, nullable.
  ///
  /// ANDs `UpdatedAt = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderQuery whereUpdatedAt(MssqlDateTimeValue value) =>
      rebuild(state.where_(fields.updatedAt.eq(value)));

  /// `dbo.Orders.DeletedAt` — datetime2, nullable.
  ///
  /// ANDs `DeletedAt = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderQuery whereDeletedAt(MssqlDateTimeValue value) =>
      rebuild(state.where_(fields.deletedAt.eq(value)));

  /// UI sort: [column] must be a field of this table.
  ///
  /// A string from a query-string is not passed to SQL. The
  /// allowlist is the generated fields; anything else is an
  /// [ArgumentError] naming the legal keys.
  OrderQuery orderByNamed(String column, {bool descending = false}) {
    switch (column) {
      case 'id':
      case 'Id':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.id.desc() : o.id.asc()],
        );
      case 'customerId':
      case 'CustomerId':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.customerId.desc() : o.customerId.asc(),
          ],
        );
      case 'code':
      case 'Code':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.code.desc() : o.code.asc()],
        );
      case 'status':
      case 'Status':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.status.desc() : o.status.asc()],
        );
      case 'total':
      case 'Total':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.total.desc() : o.total.asc()],
        );
      case 'placedAt':
      case 'PlacedAt':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.placedAt.desc() : o.placedAt.asc(),
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
          'OrderQuery cannot sort by "$column". Allowed: id, customerId, code, status, total, placedAt, createdAt, updatedAt, deletedAt.',
        );
    }
  }

  /// Writes against `customer` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.customer)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<OrderRow, CustomerRow> customerOf(OrderRow parent) =>
      related(parent, (f) => f.customer);

  /// Writes against `lines` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.lines)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<OrderRow, OrderLineRow> linesOf(OrderRow parent) =>
      related(parent, (f) => f.lines);

  /// Insert or return the live row with this unique Code.
  ///
  /// Insert-first; a 2601/2627 on `UQ_Orders_Code` reads the winner. A collision on a different unique key is rethrown.
  Future<OrderRow> getOrCreateByCode(
    String code, {
    required int customerId,
    required String status,
    required MssqlDecimal total,
    required MssqlDateTimeValue placedAt,
    MssqlDateTimeValue? createdAt,
    MssqlDateTimeValue? updatedAt,
    MssqlDateTimeValue? deletedAt,
    bool restoreExisting = false,
    bool includeDeleted = false,
  }) {
    return getOrCreate(
      key: OrderUnique.code(code),
      create: OrderRowBaseCreate(
        customerId: customerId,
        code: code,
        status: status,
        total: total,
        placedAt: placedAt,
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
    OrderRowBasePatch patch, {
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
  Future<OrderRow> create(OrderRowBaseCreate input) =>
      createValues(input.toAssignments(binding.erase()));

  /// Batched insert. Never switches to BCP on its own.
  Future<MssqlCreateManyResult<OrderRow>> createMany(
    List<OrderRowBaseCreate> rows, {
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
    Map<int, OrderRowBasePatch> byKey, {
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
  Future<OrderRow> createGraph(
    OrderRowBaseCreate input, {
    CustomerRowBaseCreate? customer,
    List<OrderLineRowBaseCreate>? lines,
    MssqlCycleWrite cycleWrite = MssqlCycleWrite.refuse,
  }) {
    final customerInput = customer;
    final linesInput = lines;
    return createGraphValues(
      MssqlGraphInsert(
        input.toAssignments(binding.erase()),
        related: <MssqlGraphRelation>[
          if (customerInput != null)
            MssqlGraphRelation(
              fields.customer.asInclude,
              <MssqlGraphInsert<Object?>>[
                MssqlGraphInsert(
                  customerInput.toAssignments(
                    fields.customer.targetBinding.erase(),
                  ),
                ),
              ],
            ),
          if (linesInput != null)
            MssqlGraphRelation(
              fields.lines.asInclude,
              <MssqlGraphInsert<Object?>>[
                for (final item in linesInput)
                  MssqlGraphInsert(
                    item.toAssignments(fields.lines.targetBinding.erase()),
                  ),
              ],
            ),
        ],
      ),
      cycle: cycleWrite,
    );
  }

  /// The row with this primary key, or null.
  Future<OrderRow?> find(int key) => whereId(key).first();

  /// The row with this primary key, or not-found.
  Future<OrderRow> getById(int key) => whereId(key).firstOrFail();
}

/// Reads and writes dbo.Orders.
class OrderRepositoryBase extends MssqlRepository<OrderRow, int> {
  /// [schema] and [table] point this repository at another
  /// table of the same shape — Eloquent's `$table`.
  OrderRepositoryBase(super.session, {super.dialect, super.schema, super.table})
    : super(binding: tableBinding);

  /// Named tableBinding rather than binding: a static cannot
  /// share a name with an inherited instance member.
  static final MssqlTableBinding<OrderRow> tableBinding =
      MssqlTableBinding<OrderRow>(
        schema: 'dbo',
        table: 'Orders',
        primaryKey: const <String>['Id'],
        identityColumn: 'Id',
        insertStrategy: MssqlInsertStrategy.outputInserted,
        decimalMode: MssqlDecimalMode.exact,
        schemaFingerprint:
            'f35f869b6dac9c73712f57a415d6bc1f70c073ad42034675251f211a36b3983a',
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
            name: 'CustomerId',
            type: MssqlType.int32,
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
            name: 'Status',
            type: MssqlType.nvarchar,
            maxLength: 20,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'Total',
            type: MssqlType.decimal,
            maxLength: 0,
            precision: 18,
            scale: 2,
          ),
          MssqlBoundColumn(
            name: 'PlacedAt',
            type: MssqlType.dateTime2,
            maxLength: 0,
            precision: 0,
            scale: 7,
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
        fromRow: OrderRowBase.fromRow,
        toColumns: (row) => row.toColumns(),
        readColumn: (row, name) => row.columnValue(name),
        applyRelations: (row, relations) => row.withRelations(relations),
        isRelationLoaded: (row, name) => row.isLoaded(name),
      );
}

/// List-row DTO for dbo.Orders.
///
/// A projection, not an entity: no writes and no relations.
@immutable
class OrderListItem {
  const OrderListItem({
    required this.id,
    required this.code,
    required this.status,
    required this.total,
  });

  final int id;
  final String code;
  final String status;
  final MssqlDecimal total;

  /// Descriptor: columns, aliases, and the row mapper.
  static final MssqlProjection<OrderListItem> projection =
      MssqlProjection<OrderListItem>(
        name: 'OrderListItem',
        columns: <MssqlProjectionColumn>[
          MssqlProjectionColumn('id', Order.id, required: false),
          MssqlProjectionColumn('code', Order.code, required: false),
          MssqlProjectionColumn('status', Order.status, required: false),
          MssqlProjectionColumn('total', Order.total, required: false),
        ],
        map: (row) => OrderListItem(
          id: MssqlProjection.decode<int>(
            row,
            0,
            projection: 'OrderListItem',
            column: 'id',
            expression: Order.id,
          ),
          code: MssqlProjection.decode<String>(
            row,
            1,
            projection: 'OrderListItem',
            column: 'code',
            expression: Order.code,
          ),
          status: MssqlProjection.decode<String>(
            row,
            2,
            projection: 'OrderListItem',
            column: 'status',
            expression: Order.status,
          ),
          total: MssqlProjection.decode<MssqlDecimal>(
            row,
            3,
            projection: 'OrderListItem',
            column: 'total',
            expression: Order.total,
          ),
        ),
      );
}
