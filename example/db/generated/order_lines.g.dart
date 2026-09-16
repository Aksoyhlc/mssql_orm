// GENERATED — do not edit. Rewritten on every run.
//
// Source: dbo.OrderLines
// Generator: mssql_orm_dev 0.1.1
// API contract: 2
// Schema fingerprint: 59978c0771388bb6642ab43ccb54416f437d9b7675a5d98aac53be499dcbebd5
//
// Foreign keys:
//   OrderId -> dbo.Orders (Id)
//   ProductId -> dbo.Products (Id)
//
// Application code belongs in ../models/order_lines.dart,
// which this generator creates once and never touches again.

import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import '../models/order_lines.dart';
import '../models/orders.dart';
import '../models/products.dart';

/// One row of dbo.OrderLines.
///
/// `copyWith` and `==` cover the fields declared here. A
/// field added to OrderLineRow is not carried by either, which
/// is inherent to the split; adding behaviour is free.
@immutable
class OrderLineRowBase {
  const OrderLineRowBase({
    required this.id,
    required this.orderId,
    required this.productId,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    OrderRow? order,
    ProductRow? product,
    Set<String> loadedRelations = const <String>{},
    Map<String, int> truncatedRelations = const <String, int>{},
  }) : _order = order,
       _product = product,
       _loadedRelations = loadedRelations,
       _truncatedRelations = truncatedRelations;

  /// IDENTITY.
  final int id;
  final int orderId;
  final int productId;
  final int quantity;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final MssqlDecimal unitPrice;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final MssqlDecimal lineTotal;

  final OrderRow? _order;
  final ProductRow? _product;
  final Set<String> _loadedRelations;
  final Map<String, int> _truncatedRelations;

  /// Whether [relation] was loaded for this row.
  ///
  /// True for loaded-null and loaded-empty. Truncated is
  /// still loaded; [isTruncated] is the incomplete flag.
  bool isLoaded(String relation) => _loadedRelations.contains(relation);

  /// Typed form of [isLoaded]: the handle, not a string.
  bool relationLoaded<TChild>(MssqlRelation<OrderLineRow, TChild> relation) =>
      isLoaded(relation.name);

  /// Whether [relation] hit maxLoadedRows.
  bool isTruncated(String relation) =>
      _truncatedRelations.containsKey(relation);

  /// Throws when the relation was not loaded, so that a
  /// null answer means exactly one thing: there is no
  /// counterpart. Without the guard, forgetting to load
  /// would read as "no counterpart" and quietly give the
  /// wrong answer.
  OrderRow? get order {
    if (!_loadedRelations.contains('order')) {
      throw MssqlRelationNotLoadedException('dbo.OrderLines', 'order');
    }
    if (_truncatedRelations.containsKey('order')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.OrderLines',
        relation: 'order',
        limit: _truncatedRelations['order']!,
      );
    }
    return _order;
  }

  /// Throws when the relation was not loaded, so that a
  /// null answer means exactly one thing: there is no
  /// counterpart. Without the guard, forgetting to load
  /// would read as "no counterpart" and quietly give the
  /// wrong answer.
  ProductRow? get product {
    if (!_loadedRelations.contains('product')) {
      throw MssqlRelationNotLoadedException('dbo.OrderLines', 'product');
    }
    if (_truncatedRelations.containsKey('product')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.OrderLines',
        relation: 'product',
        limit: _truncatedRelations['product']!,
      );
    }
    return _product;
  }

  /// Reads a row by ordinal after checking column names.
  ///
  /// Name lookup on every field would rebuild a map the
  /// driver already has. Extra trailing columns are allowed
  /// so a withCount projection can append aggregates.
  static const List<String> columnOrder = <String>[
    'Id',
    'OrderId',
    'ProductId',
    'Quantity',
    'UnitPrice',
    'LineTotal',
  ];
  static OrderLineRow fromRow(MssqlRow row) {
    row.assertOrdinalNames(columnOrder);
    return OrderLineRow(
      id: (row.at(0)! as num).toInt(),
      orderId: (row.at(1)! as num).toInt(),
      productId: (row.at(2)! as num).toInt(),
      quantity: (row.at(3)! as num).toInt(),
      unitPrice: row.at(4)! as MssqlDecimal,
      lineTotal: row.at(5)! as MssqlDecimal,
    );
  }

  /// One column of this row, by SQL name.
  Object? columnValue(String name) => switch (name) {
    'Id' => id,
    'OrderId' => orderId,
    'ProductId' => productId,
    'Quantity' => quantity,
    'UnitPrice' => unitPrice,
    'LineTotal' => lineTotal,
    _ => throw ArgumentError.value(
      name,
      'name',
      'OrderLineRow has no column named "$name".',
    ),
  };

  Map<String, Object?> toColumns() => <String, Object?>{
    'Id': id,
    'OrderId': orderId,
    'ProductId': productId,
    'Quantity': quantity,
    'UnitPrice': unitPrice,
    'LineTotal': lineTotal,
  };

  OrderLineRow copyWith({
    int? id,
    int? orderId,
    int? productId,
    int? quantity,
    MssqlDecimal? unitPrice,
    MssqlDecimal? lineTotal,
  }) => OrderLineRow(
    id: id ?? this.id,
    orderId: orderId ?? this.orderId,
    productId: productId ?? this.productId,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice ?? this.unitPrice,
    lineTotal: lineTotal ?? this.lineTotal,
    order: _order,
    product: _product,
    loadedRelations: _loadedRelations,
    truncatedRelations: _truncatedRelations,
  );

  /// Returns a copy carrying the loaded relations.
  ///
  /// Rows are immutable, so the loader cannot write into
  /// one; it asks for a new row instead.
  OrderLineRow withRelations(Map<String, Object?> relations) => OrderLineRow(
    id: id,
    orderId: orderId,
    productId: productId,
    quantity: quantity,
    unitPrice: unitPrice,
    lineTotal: lineTotal,
    order: relations.containsKey('order')
        ? relations['order'] as OrderRow?
        : _order,
    product: relations.containsKey('product')
        ? relations['product'] as ProductRow?
        : _product,
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
      other is OrderLineRowBase &&
          other.id == id &&
          other.orderId == orderId &&
          other.productId == productId &&
          other.quantity == quantity &&
          other.unitPrice == unitPrice &&
          other.lineTotal == lineTotal;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    id,
    orderId,
    productId,
    quantity,
    unitPrice,
    lineTotal,
  ]);

  @override
  String toString() =>
      'OrderLineRow(id: $id, orderId: $orderId, productId: $productId, quantity: $quantity, unitPrice: $unitPrice, lineTotal: $lineTotal)';
}

/// Values for inserting one row into dbo.OrderLines.
///
/// Identity, computed, rowversion and read-only columns
/// are absent: the server owns them. A non-null column
/// without a default is required; a nullable or defaulted
/// column is optional, and omitting it means SQL DEFAULT.
@immutable
class OrderLineRowBaseCreate {
  const OrderLineRowBaseCreate({
    required this.orderId,
    required this.productId,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
  });

  final int orderId;
  final int productId;
  final int quantity;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final MssqlDecimal unitPrice;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final MssqlDecimal lineTotal;

  /// Builds the write assignments for [MssqlRepository.insert].
  MssqlWriteAssignments toAssignments(MssqlTableBinding<Object?> binding) {
    final values = <String, MssqlWriteValue>{};
    values['OrderId'] = MssqlBoundValue(
      binding.column('OrderId')!.bind(orderId),
    );
    values['ProductId'] = MssqlBoundValue(
      binding.column('ProductId')!.bind(productId),
    );
    values['Quantity'] = MssqlBoundValue(
      binding.column('Quantity')!.bind(quantity),
    );
    values['UnitPrice'] = MssqlBoundValue(
      binding.column('UnitPrice')!.bind(unitPrice),
    );
    values['LineTotal'] = MssqlBoundValue(
      binding.column('LineTotal')!.bind(lineTotal),
    );
    return MssqlWriteAssignments(values);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OrderLineRowBaseCreate &&
          other.orderId == orderId &&
          other.productId == productId &&
          other.quantity == quantity &&
          other.unitPrice == unitPrice &&
          other.lineTotal == lineTotal;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    orderId,
    productId,
    quantity,
    unitPrice,
    lineTotal,
  ]);

  @override
  String toString() =>
      'OrderLineRowBaseCreate(orderId: $orderId, productId: $productId, quantity: $quantity, unitPrice: $unitPrice, lineTotal: $lineTotal)';
}

/// A partial update of dbo.OrderLines.
///
/// Each field is a [Field]: [Field.absent] means "don't
/// touch", [Field.value] means "set to this". A nullable
/// column accepts `Field<T?>.value(null)` to clear it;
/// a non-null column's `Field<T>` cannot carry null.
@immutable
class OrderLineRowBasePatch {
  const OrderLineRowBasePatch({
    this.orderId = const Field.absent(),
    this.productId = const Field.absent(),
    this.quantity = const Field.absent(),
    this.unitPrice = const Field.absent(),
    this.lineTotal = const Field.absent(),
  });

  final Field<int> orderId;
  final Field<int> productId;
  final Field<int> quantity;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final Field<MssqlDecimal> unitPrice;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final Field<MssqlDecimal> lineTotal;

  /// Builds the write assignments for [MssqlRepository.update] / [MssqlRepository.updateWhere].
  MssqlWriteAssignments toAssignments(MssqlTableBinding<Object?> binding) {
    final values = <String, MssqlWriteValue>{};
    if (orderId.isPresent) {
      values['OrderId'] = MssqlBoundValue(
        binding.column('OrderId')!.bind(orderId.value),
      );
    }
    if (productId.isPresent) {
      values['ProductId'] = MssqlBoundValue(
        binding.column('ProductId')!.bind(productId.value),
      );
    }
    if (quantity.isPresent) {
      values['Quantity'] = MssqlBoundValue(
        binding.column('Quantity')!.bind(quantity.value),
      );
    }
    if (unitPrice.isPresent) {
      values['UnitPrice'] = MssqlBoundValue(
        binding.column('UnitPrice')!.bind(unitPrice.value),
      );
    }
    if (lineTotal.isPresent) {
      values['LineTotal'] = MssqlBoundValue(
        binding.column('LineTotal')!.bind(lineTotal.value),
      );
    }
    return MssqlWriteAssignments(values);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OrderLineRowBasePatch &&
          other.orderId == orderId &&
          other.productId == productId &&
          other.quantity == quantity &&
          other.unitPrice == unitPrice &&
          other.lineTotal == lineTotal;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    orderId,
    productId,
    quantity,
    unitPrice,
    lineTotal,
  ]);

  @override
  String toString() =>
      'OrderLineRowBasePatch(orderId: $orderId, productId: $productId, quantity: $quantity, unitPrice: $unitPrice, lineTotal: $lineTotal)';
}

/// Typed column references for dbo.OrderLines.
abstract final class OrderLine {
  static const String table = 'dbo.OrderLines';

  /// Which table these columns belong to.
  ///
  /// The columns below name this rather than writing
  /// `[dbo].[OrderLines]` into
  /// themselves, so that a query that aliases the table, or
  /// one pointed at another schema, still refers to the
  /// source it actually has.
  static const MssqlSourceRef source = MssqlSourceRef(
    schema: 'dbo',
    table: 'OrderLines',
  );

  /// `dbo.OrderLines.Id` — int, NOT NULL, IDENTITY, read-only.
  static final MssqlIntColumn id = column$id(source);

  /// `dbo.OrderLines.OrderId` — int, NOT NULL.
  static final MssqlIntColumn orderId = column$orderId(source);

  /// `dbo.OrderLines.ProductId` — int, NOT NULL.
  static final MssqlIntColumn productId = column$productId(source);

  /// `dbo.OrderLines.Quantity` — int, NOT NULL.
  static final MssqlIntColumn quantity = column$quantity(source);

  /// `dbo.OrderLines.UnitPrice` — decimal, NOT NULL.
  static final MssqlDecimalColumn unitPrice = column$unitPrice(source);

  /// `dbo.OrderLines.LineTotal` — decimal, NOT NULL.
  static final MssqlDecimalColumn lineTotal = column$lineTotal(source);

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

  static MssqlIntColumn column$orderId(MssqlSourceRef source) =>
      MssqlIntColumn.of(
        source: source,
        name: 'OrderId',
        quotedName: '[OrderId]',
        columnType: MssqlColumnType(
          type: MssqlType.int32,
          size: 0,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'OrderId',
        ),
      );

  static MssqlIntColumn column$productId(MssqlSourceRef source) =>
      MssqlIntColumn.of(
        source: source,
        name: 'ProductId',
        quotedName: '[ProductId]',
        columnType: MssqlColumnType(
          type: MssqlType.int32,
          size: 0,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'ProductId',
        ),
      );

  static MssqlIntColumn column$quantity(MssqlSourceRef source) =>
      MssqlIntColumn.of(
        source: source,
        name: 'Quantity',
        quotedName: '[Quantity]',
        columnType: MssqlColumnType(
          type: MssqlType.int32,
          size: 0,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'Quantity',
        ),
      );

  static MssqlDecimalColumn column$unitPrice(MssqlSourceRef source) =>
      MssqlDecimalColumn.of(
        source: source,
        name: 'UnitPrice',
        quotedName: '[UnitPrice]',
        columnType: MssqlColumnType(
          type: MssqlType.decimal,
          size: 0,
          precision: 18,
          scale: 2,
          nullable: false,
          columnName: 'UnitPrice',
        ),
      );

  static MssqlDecimalColumn column$lineTotal(MssqlSourceRef source) =>
      MssqlDecimalColumn.of(
        source: source,
        name: 'LineTotal',
        quotedName: '[LineTotal]',
        columnType: MssqlColumnType(
          type: MssqlType.decimal,
          size: 0,
          precision: 18,
          scale: 2,
          nullable: false,
          columnName: 'LineTotal',
        ),
      );
}

/// Relations of dbo.OrderLines, from its foreign
/// keys. Pass these to `include:` to load them eagerly.
abstract final class OrderLineRel {
  static MssqlRelation<OrderLineRow, OrderRow> get order =>
      MssqlRelation<OrderLineRow, OrderRow>(
        name: 'order',
        kind: MssqlRelationKind.belongsTo,
        targetBinding: OrderRepositoryBase.tableBinding,
        localColumns: const <String>['OrderId'],
        foreignColumns: const <String>['Id'],
      );
  static MssqlRelation<OrderLineRow, ProductRow> get product =>
      MssqlRelation<OrderLineRow, ProductRow>(
        name: 'product',
        kind: MssqlRelationKind.belongsTo,
        targetBinding: ProductRepositoryBase.tableBinding,
        localColumns: const <String>['ProductId'],
        foreignColumns: const <String>['Id'],
      );
}

/// Typed include modifiers for OrderLineRow.order.
extension OrderLineOrderInclude on MssqlRelation<OrderLineRow, OrderRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<OrderLineRow, OrderRow> where(
    MssqlCondition Function(OrderFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const OrderFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<OrderLineRow, OrderRow> orderBy(
    List<MssqlOrder> Function(OrderFields fields) ordering,
  ) => ordered(ordering(const OrderFields()));

  /// Nested includes of the target.
  MssqlRelation<OrderLineRow, OrderRow> include(
    Iterable<MssqlRelation<OrderRow, Object?>> Function(OrderFields fields)
    nested,
  ) => withNested(nested(const OrderFields()));
}

/// Typed include modifiers for OrderLineRow.product.
extension OrderLineProductInclude on MssqlRelation<OrderLineRow, ProductRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<OrderLineRow, ProductRow> where(
    MssqlCondition Function(ProductFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const ProductFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<OrderLineRow, ProductRow> orderBy(
    List<MssqlOrder> Function(ProductFields fields) ordering,
  ) => ordered(ordering(const ProductFields()));

  /// Nested includes of the target.
  MssqlRelation<OrderLineRow, ProductRow> include(
    Iterable<MssqlRelation<ProductRow, Object?>> Function(ProductFields fields)
    nested,
  ) => withNested(nested(const ProductFields()));
}

/// Typed SQL columns of dbo.OrderLines.
///
/// A row this is not: there is no `id` integer here, only
/// the column that becomes `WHERE [Id] = @p`. The query
/// callback takes this type so `o` completes to columns.
class OrderLineFields {
  /// Columns of the generated table, or — with a
  /// [MssqlSourceRef] — of the same table under another
  /// schema or name, as `at(schema:, table:)` produces.
  const OrderLineFields([this._source]);

  final MssqlSourceRef? _source;

  /// Which source these columns resolve against.
  MssqlSourceRef get source => _source ?? OrderLine.source;

  /// `dbo.OrderLines.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// `whereId` ANDs an equality on this column.
  MssqlIntColumn get id {
    final ref = _source;
    return ref == null ? OrderLine.id : OrderLine.column$id(ref);
  }

  /// `dbo.OrderLines.OrderId` — int, NOT NULL.
  ///
  /// `whereOrderId` ANDs an equality on this column.
  MssqlIntColumn get orderId {
    final ref = _source;
    return ref == null ? OrderLine.orderId : OrderLine.column$orderId(ref);
  }

  /// `dbo.OrderLines.ProductId` — int, NOT NULL.
  ///
  /// `whereProductId` ANDs an equality on this column.
  MssqlIntColumn get productId {
    final ref = _source;
    return ref == null ? OrderLine.productId : OrderLine.column$productId(ref);
  }

  /// `dbo.OrderLines.Quantity` — int, NOT NULL.
  ///
  /// `whereQuantity` ANDs an equality on this column.
  MssqlIntColumn get quantity {
    final ref = _source;
    return ref == null ? OrderLine.quantity : OrderLine.column$quantity(ref);
  }

  /// `dbo.OrderLines.UnitPrice` — decimal, NOT NULL.
  ///
  /// `whereUnitPrice` ANDs an equality on this column.
  MssqlDecimalColumn get unitPrice {
    final ref = _source;
    return ref == null ? OrderLine.unitPrice : OrderLine.column$unitPrice(ref);
  }

  /// `dbo.OrderLines.LineTotal` — decimal, NOT NULL.
  ///
  /// `whereLineTotal` ANDs an equality on this column.
  MssqlDecimalColumn get lineTotal {
    final ref = _source;
    return ref == null ? OrderLine.lineTotal : OrderLine.column$lineTotal(ref);
  }

  /// Include handle for `order`.
  ///
  /// `include((o) => [o.order])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<OrderLineRow, OrderRow> get order => OrderLineRel.order;

  /// Include handle for `product`.
  ///
  /// `include((o) => [o.product])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<OrderLineRow, ProductRow> get product => OrderLineRel.product;
}

/// Query over dbo.OrderLines.
///
/// Every entity-preserving call returns [OrderLineQuery], so a user
/// extension (`extension on OrderLineQuery`) stays in the chain.
/// `whereX` shortcuts AND an equality; OR stays in
/// `where((o) => … | …)`.
class OrderLineQuery
    extends MssqlEntityQuery<OrderLineRow, OrderLineFields, OrderLineQuery> {
  OrderLineQuery(super.context, [super.state, super.included]);

  @override
  /// Columns bound to whatever source this query has.
  ///
  /// The constant instance for the generated table, and a
  /// rebound one after `at(schema:, table:)`, so a
  /// predicate written after a rebind names the table this
  /// statement actually reads.
  OrderLineFields get fields => binding.sourceRef == OrderLine.source
      ? const OrderLineFields()
      : OrderLineFields(binding.sourceRef);

  @override
  OrderLineQuery recreate(
    MssqlQueryState state,
    List<MssqlRelation<OrderLineRow, Object?>> included,
  ) => OrderLineQuery(context, state, included);

  @override
  OrderLineQuery recreateAt(
    MssqlQueryContext<OrderLineRow> context,
    MssqlQueryState state,
    List<MssqlRelation<OrderLineRow, Object?>> included,
  ) => OrderLineQuery(context, state, included);

  /// `dbo.OrderLines.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// ANDs `Id = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderLineQuery whereId(int value) =>
      rebuild(state.where_(fields.id.eq(value)));

  /// `dbo.OrderLines.OrderId` — int, NOT NULL.
  ///
  /// ANDs `OrderId = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderLineQuery whereOrderId(int value) =>
      rebuild(state.where_(fields.orderId.eq(value)));

  /// `dbo.OrderLines.ProductId` — int, NOT NULL.
  ///
  /// ANDs `ProductId = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderLineQuery whereProductId(int value) =>
      rebuild(state.where_(fields.productId.eq(value)));

  /// `dbo.OrderLines.Quantity` — int, NOT NULL.
  ///
  /// ANDs `Quantity = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderLineQuery whereQuantity(int value) =>
      rebuild(state.where_(fields.quantity.eq(value)));

  /// `dbo.OrderLines.UnitPrice` — decimal, NOT NULL.
  ///
  /// ANDs `UnitPrice = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderLineQuery whereUnitPrice(MssqlDecimal value) =>
      rebuild(state.where_(fields.unitPrice.eq(value)));

  /// `dbo.OrderLines.LineTotal` — decimal, NOT NULL.
  ///
  /// ANDs `LineTotal = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  OrderLineQuery whereLineTotal(MssqlDecimal value) =>
      rebuild(state.where_(fields.lineTotal.eq(value)));

  /// UI sort: [column] must be a field of this table.
  ///
  /// A string from a query-string is not passed to SQL. The
  /// allowlist is the generated fields; anything else is an
  /// [ArgumentError] naming the legal keys.
  OrderLineQuery orderByNamed(String column, {bool descending = false}) {
    switch (column) {
      case 'id':
      case 'Id':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.id.desc() : o.id.asc()],
        );
      case 'orderId':
      case 'OrderId':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.orderId.desc() : o.orderId.asc()],
        );
      case 'productId':
      case 'ProductId':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.productId.desc() : o.productId.asc(),
          ],
        );
      case 'quantity':
      case 'Quantity':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.quantity.desc() : o.quantity.asc(),
          ],
        );
      case 'unitPrice':
      case 'UnitPrice':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.unitPrice.desc() : o.unitPrice.asc(),
          ],
        );
      case 'lineTotal':
      case 'LineTotal':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.lineTotal.desc() : o.lineTotal.asc(),
          ],
        );
      default:
        throw ArgumentError.value(
          column,
          'column',
          'OrderLineQuery cannot sort by "$column". Allowed: id, orderId, productId, quantity, unitPrice, lineTotal.',
        );
    }
  }

  /// Writes against `order` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.order)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<OrderLineRow, OrderRow> orderOf(OrderLineRow parent) =>
      related(parent, (f) => f.order);

  /// Writes against `product` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.product)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<OrderLineRow, ProductRow> productOf(
    OrderLineRow parent,
  ) => related(parent, (f) => f.product);

  /// Partial update of matching rows.
  ///
  /// Absent patch fields are not named. [expectedVersion] is the rowversion token; a table without one refuses it.
  Future<int> update(
    OrderLineRowBasePatch patch, {
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
  Future<OrderLineRow> create(OrderLineRowBaseCreate input) =>
      createValues(input.toAssignments(binding.erase()));

  /// Batched insert. Never switches to BCP on its own.
  Future<MssqlCreateManyResult<OrderLineRow>> createMany(
    List<OrderLineRowBaseCreate> rows, {
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
    Map<int, OrderLineRowBasePatch> byKey, {
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
  Future<OrderLineRow> createGraph(
    OrderLineRowBaseCreate input, {
    OrderRowBaseCreate? order,
    ProductRowBaseCreate? product,
    MssqlCycleWrite cycleWrite = MssqlCycleWrite.refuse,
  }) {
    final orderInput = order;
    final productInput = product;
    return createGraphValues(
      MssqlGraphInsert(
        input.toAssignments(binding.erase()),
        related: <MssqlGraphRelation>[
          if (orderInput != null)
            MssqlGraphRelation(
              fields.order.asInclude,
              <MssqlGraphInsert<Object?>>[
                MssqlGraphInsert(
                  orderInput.toAssignments(fields.order.targetBinding.erase()),
                ),
              ],
            ),
          if (productInput != null)
            MssqlGraphRelation(
              fields.product.asInclude,
              <MssqlGraphInsert<Object?>>[
                MssqlGraphInsert(
                  productInput.toAssignments(
                    fields.product.targetBinding.erase(),
                  ),
                ),
              ],
            ),
        ],
      ),
      cycle: cycleWrite,
    );
  }

  /// The row with this primary key, or null.
  Future<OrderLineRow?> find(int key) => whereId(key).first();

  /// The row with this primary key, or not-found.
  Future<OrderLineRow> getById(int key) => whereId(key).firstOrFail();
}

/// Reads and writes dbo.OrderLines.
class OrderLineRepositoryBase extends MssqlRepository<OrderLineRow, int> {
  /// [schema] and [table] point this repository at another
  /// table of the same shape — Eloquent's `$table`.
  OrderLineRepositoryBase(
    super.session, {
    super.dialect,
    super.schema,
    super.table,
  }) : super(binding: tableBinding);

  /// Named tableBinding rather than binding: a static cannot
  /// share a name with an inherited instance member.
  static final MssqlTableBinding<OrderLineRow> tableBinding =
      MssqlTableBinding<OrderLineRow>(
        schema: 'dbo',
        table: 'OrderLines',
        primaryKey: const <String>['Id'],
        identityColumn: 'Id',
        insertStrategy: MssqlInsertStrategy.outputInserted,
        decimalMode: MssqlDecimalMode.exact,
        schemaFingerprint:
            '59978c0771388bb6642ab43ccb54416f437d9b7675a5d98aac53be499dcbebd5',
        apiVersion: 2,
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
            name: 'OrderId',
            type: MssqlType.int32,
            maxLength: 0,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'ProductId',
            type: MssqlType.int32,
            maxLength: 0,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'Quantity',
            type: MssqlType.int32,
            maxLength: 0,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'UnitPrice',
            type: MssqlType.decimal,
            maxLength: 0,
            precision: 18,
            scale: 2,
          ),
          MssqlBoundColumn(
            name: 'LineTotal',
            type: MssqlType.decimal,
            maxLength: 0,
            precision: 18,
            scale: 2,
          ),
        ],
        fromRow: OrderLineRowBase.fromRow,
        toColumns: (row) => row.toColumns(),
        readColumn: (row, name) => row.columnValue(name),
        applyRelations: (row, relations) => row.withRelations(relations),
        isRelationLoaded: (row, name) => row.isLoaded(name),
      );
}
