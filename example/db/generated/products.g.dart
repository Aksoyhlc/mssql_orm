// GENERATED — do not edit. Rewritten on every run.
//
// Source: dbo.Products
// Generator: mssql_orm_dev 0.1.0
// API contract: 2
// Schema fingerprint: 105153bdbfabcfd2e0f045821c8c56ad35dc6d1ef5d54592bd14cf66cfc8f357
//
// Foreign keys:
//   CategoryId -> dbo.Categories (Id)
//
// Application code belongs in ../models/products.dart,
// which this generator creates once and never touches again.

import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import '../models/categories.dart';
import '../models/order_lines.dart';
import '../models/products.dart';

/// One row of dbo.Products.
///
/// `copyWith` and `==` cover the fields declared here. A
/// field added to ProductRow is not carried by either, which
/// is inherent to the split; adding behaviour is free.
@immutable
class ProductRowBase {
  const ProductRowBase({
    required this.id,
    required this.categoryId,
    required this.sku,
    required this.name,
    required this.price,
    required this.stock,
    CategoryRow? category,
    List<OrderLineRow>? orderLines,
    Set<String> loadedRelations = const <String>{},
    Map<String, int> truncatedRelations = const <String, int>{},
  }) : _category = category,
       _orderLines = orderLines,
       _loadedRelations = loadedRelations,
       _truncatedRelations = truncatedRelations;

  /// IDENTITY.
  final int id;
  final int categoryId;
  final String sku;
  final String name;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final MssqlDecimal price;
  final int stock;

  final CategoryRow? _category;
  final List<OrderLineRow>? _orderLines;
  final Set<String> _loadedRelations;
  final Map<String, int> _truncatedRelations;

  /// Whether [relation] was loaded for this row.
  ///
  /// True for loaded-null and loaded-empty. Truncated is
  /// still loaded; [isTruncated] is the incomplete flag.
  bool isLoaded(String relation) => _loadedRelations.contains(relation);

  /// Typed form of [isLoaded]: the handle, not a string.
  bool relationLoaded<TChild>(MssqlRelation<ProductRow, TChild> relation) =>
      isLoaded(relation.name);

  /// Whether [relation] hit maxLoadedRows.
  bool isTruncated(String relation) =>
      _truncatedRelations.containsKey(relation);

  /// Throws when the relation was not loaded, so that a
  /// null answer means exactly one thing: there is no
  /// counterpart. Without the guard, forgetting to load
  /// would read as "no counterpart" and quietly give the
  /// wrong answer.
  CategoryRow? get category {
    if (!_loadedRelations.contains('category')) {
      throw MssqlRelationNotLoadedException('dbo.Products', 'category');
    }
    if (_truncatedRelations.containsKey('category')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.Products',
        relation: 'category',
        limit: _truncatedRelations['category']!,
      );
    }
    return _category;
  }

  /// Throws when the relation was not loaded. An empty
  /// list means loaded and none.
  List<OrderLineRow> get orderLines {
    if (!_loadedRelations.contains('orderLines')) {
      throw MssqlRelationNotLoadedException('dbo.Products', 'orderLines');
    }
    if (_truncatedRelations.containsKey('orderLines')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.Products',
        relation: 'orderLines',
        limit: _truncatedRelations['orderLines']!,
      );
    }
    return _orderLines ?? const [];
  }

  /// Reads a row by ordinal after checking column names.
  ///
  /// Name lookup on every field would rebuild a map the
  /// driver already has. Extra trailing columns are allowed
  /// so a withCount projection can append aggregates.
  static const List<String> columnOrder = <String>[
    'Id',
    'CategoryId',
    'Sku',
    'Name',
    'Price',
    'Stock',
  ];
  static ProductRow fromRow(MssqlRow row) {
    row.assertOrdinalNames(columnOrder);
    return ProductRow(
      id: (row.at(0)! as num).toInt(),
      categoryId: (row.at(1)! as num).toInt(),
      sku: row.at(2)! as String,
      name: row.at(3)! as String,
      price: row.at(4)! as MssqlDecimal,
      stock: (row.at(5)! as num).toInt(),
    );
  }

  /// One column of this row, by SQL name.
  Object? columnValue(String name) => switch (name) {
    'Id' => id,
    'CategoryId' => categoryId,
    'Sku' => sku,
    'Name' => name,
    'Price' => price,
    'Stock' => stock,
    _ => throw ArgumentError.value(
      name,
      'name',
      'ProductRow has no column named "$name".',
    ),
  };

  Map<String, Object?> toColumns() => <String, Object?>{
    'Id': id,
    'CategoryId': categoryId,
    'Sku': sku,
    'Name': name,
    'Price': price,
    'Stock': stock,
  };

  ProductRow copyWith({
    int? id,
    int? categoryId,
    String? sku,
    String? name,
    MssqlDecimal? price,
    int? stock,
  }) => ProductRow(
    id: id ?? this.id,
    categoryId: categoryId ?? this.categoryId,
    sku: sku ?? this.sku,
    name: name ?? this.name,
    price: price ?? this.price,
    stock: stock ?? this.stock,
    category: _category,
    orderLines: _orderLines,
    loadedRelations: _loadedRelations,
    truncatedRelations: _truncatedRelations,
  );

  /// Returns a copy carrying the loaded relations.
  ///
  /// Rows are immutable, so the loader cannot write into
  /// one; it asks for a new row instead.
  ProductRow withRelations(Map<String, Object?> relations) => ProductRow(
    id: id,
    categoryId: categoryId,
    sku: sku,
    name: name,
    price: price,
    stock: stock,
    category: relations.containsKey('category')
        ? relations['category'] as CategoryRow?
        : _category,
    orderLines: relations.containsKey('orderLines')
        ? (relations['orderLines']! as List<Object?>).cast<OrderLineRow>()
        : _orderLines,
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
      other is ProductRowBase &&
          other.id == id &&
          other.categoryId == categoryId &&
          other.sku == sku &&
          other.name == name &&
          other.price == price &&
          other.stock == stock;

  @override
  int get hashCode =>
      Object.hashAll(<Object?>[id, categoryId, sku, name, price, stock]);

  @override
  String toString() =>
      'ProductRow(id: $id, categoryId: $categoryId, sku: $sku, name: $name, price: $price, stock: $stock)';
}

/// Values for inserting one row into dbo.Products.
///
/// Identity, computed, rowversion and read-only columns
/// are absent: the server owns them. A non-null column
/// without a default is required; a nullable or defaulted
/// column is optional, and omitting it means SQL DEFAULT.
@immutable
class ProductRowBaseCreate {
  const ProductRowBaseCreate({
    required this.categoryId,
    required this.sku,
    required this.name,
    required this.price,
    required this.stock,
  });

  final int categoryId;
  final String sku;
  final String name;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final MssqlDecimal price;
  final int stock;

  /// Builds the write assignments for [MssqlRepository.insert].
  MssqlWriteAssignments toAssignments(MssqlTableBinding<Object?> binding) {
    final values = <String, MssqlWriteValue>{};
    values['CategoryId'] = MssqlBoundValue(
      binding.column('CategoryId')!.bind(categoryId),
    );
    values['Sku'] = MssqlBoundValue(binding.column('Sku')!.bind(sku));
    values['Name'] = MssqlBoundValue(binding.column('Name')!.bind(name));
    values['Price'] = MssqlBoundValue(binding.column('Price')!.bind(price));
    values['Stock'] = MssqlBoundValue(binding.column('Stock')!.bind(stock));
    return MssqlWriteAssignments(values);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProductRowBaseCreate &&
          other.categoryId == categoryId &&
          other.sku == sku &&
          other.name == name &&
          other.price == price &&
          other.stock == stock;

  @override
  int get hashCode =>
      Object.hashAll(<Object?>[categoryId, sku, name, price, stock]);

  @override
  String toString() =>
      'ProductRowBaseCreate(categoryId: $categoryId, sku: $sku, name: $name, price: $price, stock: $stock)';
}

/// A partial update of dbo.Products.
///
/// Each field is a [Field]: [Field.absent] means "don't
/// touch", [Field.value] means "set to this". A nullable
/// column accepts `Field<T?>.value(null)` to clear it;
/// a non-null column's `Field<T>` cannot carry null.
@immutable
class ProductRowBasePatch {
  const ProductRowBasePatch({
    this.categoryId = const Field.absent(),
    this.sku = const Field.absent(),
    this.name = const Field.absent(),
    this.price = const Field.absent(),
    this.stock = const Field.absent(),
  });

  final Field<int> categoryId;
  final Field<String> sku;
  final Field<String> name;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final Field<MssqlDecimal> price;
  final Field<int> stock;

  /// Builds the write assignments for [MssqlRepository.update] / [MssqlRepository.updateWhere].
  MssqlWriteAssignments toAssignments(MssqlTableBinding<Object?> binding) {
    final values = <String, MssqlWriteValue>{};
    if (categoryId.isPresent) {
      values['CategoryId'] = MssqlBoundValue(
        binding.column('CategoryId')!.bind(categoryId.value),
      );
    }
    if (sku.isPresent) {
      values['Sku'] = MssqlBoundValue(binding.column('Sku')!.bind(sku.value));
    }
    if (name.isPresent) {
      values['Name'] = MssqlBoundValue(
        binding.column('Name')!.bind(name.value),
      );
    }
    if (price.isPresent) {
      values['Price'] = MssqlBoundValue(
        binding.column('Price')!.bind(price.value),
      );
    }
    if (stock.isPresent) {
      values['Stock'] = MssqlBoundValue(
        binding.column('Stock')!.bind(stock.value),
      );
    }
    return MssqlWriteAssignments(values);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProductRowBasePatch &&
          other.categoryId == categoryId &&
          other.sku == sku &&
          other.name == name &&
          other.price == price &&
          other.stock == stock;

  @override
  int get hashCode =>
      Object.hashAll(<Object?>[categoryId, sku, name, price, stock]);

  @override
  String toString() =>
      'ProductRowBasePatch(categoryId: $categoryId, sku: $sku, name: $name, price: $price, stock: $stock)';
}

/// Unique keys of dbo.Products that getOrCreate may use.
///
/// Filtered and disabled indexes are omitted: they do not make a row unique across the table.
abstract final class ProductUnique {
  /// `UQ_Products_Sku` on Sku.
  static MssqlUniqueMatch sku(String sku) => MssqlUniqueMatch(
    indexName: 'UQ_Products_Sku',
    values: <String, Object?>{'Sku': sku},
  );
}

/// Typed column references for dbo.Products.
abstract final class Product {
  static const String table = 'dbo.Products';

  /// Which table these columns belong to.
  ///
  /// The columns below name this rather than writing
  /// `[dbo].[Products]` into
  /// themselves, so that a query that aliases the table, or
  /// one pointed at another schema, still refers to the
  /// source it actually has.
  static const MssqlSourceRef source = MssqlSourceRef(
    schema: 'dbo',
    table: 'Products',
  );

  /// `dbo.Products.Id` — int, NOT NULL, IDENTITY, read-only.
  static final MssqlIntColumn id = column$id(source);

  /// `dbo.Products.CategoryId` — int, NOT NULL.
  static final MssqlIntColumn categoryId = column$categoryId(source);

  /// `dbo.Products.Sku` — nvarchar, NOT NULL.
  static final MssqlStringColumn sku = column$sku(source);

  /// `dbo.Products.Name` — nvarchar, NOT NULL.
  static final MssqlStringColumn name = column$name(source);

  /// `dbo.Products.Price` — decimal, NOT NULL.
  static final MssqlDecimalColumn price = column$price(source);

  /// `dbo.Products.Stock` — int, NOT NULL.
  static final MssqlIntColumn stock = column$stock(source);

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

  static MssqlIntColumn column$categoryId(MssqlSourceRef source) =>
      MssqlIntColumn.of(
        source: source,
        name: 'CategoryId',
        quotedName: '[CategoryId]',
        columnType: MssqlColumnType(
          type: MssqlType.int32,
          size: 0,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'CategoryId',
        ),
      );

  static MssqlStringColumn column$sku(MssqlSourceRef source) =>
      MssqlStringColumn.of(
        source: source,
        name: 'Sku',
        quotedName: '[Sku]',
        columnType: MssqlColumnType(
          type: MssqlType.nvarchar,
          size: 20,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'Sku',
        ),
      );

  static MssqlStringColumn column$name(MssqlSourceRef source) =>
      MssqlStringColumn.of(
        source: source,
        name: 'Name',
        quotedName: '[Name]',
        columnType: MssqlColumnType(
          type: MssqlType.nvarchar,
          size: 200,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'Name',
        ),
      );

  static MssqlDecimalColumn column$price(MssqlSourceRef source) =>
      MssqlDecimalColumn.of(
        source: source,
        name: 'Price',
        quotedName: '[Price]',
        columnType: MssqlColumnType(
          type: MssqlType.decimal,
          size: 0,
          precision: 18,
          scale: 2,
          nullable: false,
          columnName: 'Price',
        ),
      );

  static MssqlIntColumn column$stock(MssqlSourceRef source) =>
      MssqlIntColumn.of(
        source: source,
        name: 'Stock',
        quotedName: '[Stock]',
        columnType: MssqlColumnType(
          type: MssqlType.int32,
          size: 0,
          precision: 0,
          scale: 0,
          nullable: false,
          columnName: 'Stock',
        ),
      );
}

/// Relations of dbo.Products, from its foreign
/// keys. Pass these to `include:` to load them eagerly.
abstract final class ProductRel {
  static MssqlRelation<ProductRow, CategoryRow> get category =>
      MssqlRelation<ProductRow, CategoryRow>(
        name: 'category',
        kind: MssqlRelationKind.belongsTo,
        targetBinding: CategoryRepositoryBase.tableBinding,
        localColumns: const <String>['CategoryId'],
        foreignColumns: const <String>['Id'],
      );
  static MssqlRelation<ProductRow, OrderLineRow> get orderLines =>
      MssqlRelation<ProductRow, OrderLineRow>(
        name: 'orderLines',
        kind: MssqlRelationKind.hasMany,
        targetBinding: OrderLineRepositoryBase.tableBinding,
        localColumns: const <String>['Id'],
        foreignColumns: const <String>['ProductId'],
      );
}

/// Typed include modifiers for ProductRow.category.
extension ProductCategoryInclude on MssqlRelation<ProductRow, CategoryRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<ProductRow, CategoryRow> where(
    MssqlCondition Function(CategoryFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const CategoryFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<ProductRow, CategoryRow> orderBy(
    List<MssqlOrder> Function(CategoryFields fields) ordering,
  ) => ordered(ordering(const CategoryFields()));

  /// Nested includes of the target.
  MssqlRelation<ProductRow, CategoryRow> include(
    Iterable<MssqlRelation<CategoryRow, Object?>> Function(
      CategoryFields fields,
    )
    nested,
  ) => withNested(nested(const CategoryFields()));
}

/// Typed include modifiers for ProductRow.orderLines.
extension ProductOrderLinesInclude on MssqlRelation<ProductRow, OrderLineRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<ProductRow, OrderLineRow> where(
    MssqlCondition Function(OrderLineFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const OrderLineFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<ProductRow, OrderLineRow> orderBy(
    List<MssqlOrder> Function(OrderLineFields fields) ordering,
  ) => ordered(ordering(const OrderLineFields()));

  /// Nested includes of the target.
  MssqlRelation<ProductRow, OrderLineRow> include(
    Iterable<MssqlRelation<OrderLineRow, Object?>> Function(
      OrderLineFields fields,
    )
    nested,
  ) => withNested(nested(const OrderLineFields()));
}

/// Typed SQL columns of dbo.Products.
///
/// A row this is not: there is no `id` integer here, only
/// the column that becomes `WHERE [Id] = @p`. The query
/// callback takes this type so `o` completes to columns.
class ProductFields {
  /// Columns of the generated table, or — with a
  /// [MssqlSourceRef] — of the same table under another
  /// schema or name, as `at(schema:, table:)` produces.
  const ProductFields([this._source]);

  final MssqlSourceRef? _source;

  /// Which source these columns resolve against.
  MssqlSourceRef get source => _source ?? Product.source;

  /// `dbo.Products.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// `whereId` ANDs an equality on this column.
  MssqlIntColumn get id {
    final ref = _source;
    return ref == null ? Product.id : Product.column$id(ref);
  }

  /// `dbo.Products.CategoryId` — int, NOT NULL.
  ///
  /// `whereCategoryId` ANDs an equality on this column.
  MssqlIntColumn get categoryId {
    final ref = _source;
    return ref == null ? Product.categoryId : Product.column$categoryId(ref);
  }

  /// `dbo.Products.Sku` — nvarchar, NOT NULL.
  ///
  /// `whereSku` ANDs an equality on this column.
  MssqlStringColumn get sku {
    final ref = _source;
    return ref == null ? Product.sku : Product.column$sku(ref);
  }

  /// `dbo.Products.Name` — nvarchar, NOT NULL.
  ///
  /// `whereName` ANDs an equality on this column.
  MssqlStringColumn get name {
    final ref = _source;
    return ref == null ? Product.name : Product.column$name(ref);
  }

  /// `dbo.Products.Price` — decimal, NOT NULL.
  ///
  /// `wherePrice` ANDs an equality on this column.
  MssqlDecimalColumn get price {
    final ref = _source;
    return ref == null ? Product.price : Product.column$price(ref);
  }

  /// `dbo.Products.Stock` — int, NOT NULL.
  ///
  /// `whereStock` ANDs an equality on this column.
  MssqlIntColumn get stock {
    final ref = _source;
    return ref == null ? Product.stock : Product.column$stock(ref);
  }

  /// Include handle for `category`.
  ///
  /// `include((o) => [o.category])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<ProductRow, CategoryRow> get category => ProductRel.category;

  /// Include handle for `orderLines`.
  ///
  /// `include((o) => [o.orderLines])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<ProductRow, OrderLineRow> get orderLines =>
      ProductRel.orderLines;
}

/// Query over dbo.Products.
///
/// Every entity-preserving call returns [ProductQuery], so a user
/// extension (`extension on ProductQuery`) stays in the chain.
/// `whereX` shortcuts AND an equality; OR stays in
/// `where((o) => … | …)`.
class ProductQuery
    extends MssqlEntityQuery<ProductRow, ProductFields, ProductQuery> {
  ProductQuery(super.context, [super.state, super.included]);

  @override
  /// Columns bound to whatever source this query has.
  ///
  /// The constant instance for the generated table, and a
  /// rebound one after `at(schema:, table:)`, so a
  /// predicate written after a rebind names the table this
  /// statement actually reads.
  ProductFields get fields => binding.sourceRef == Product.source
      ? const ProductFields()
      : ProductFields(binding.sourceRef);

  @override
  ProductQuery recreate(
    MssqlQueryState state,
    List<MssqlRelation<ProductRow, Object?>> included,
  ) => ProductQuery(context, state, included);

  @override
  ProductQuery recreateAt(
    MssqlQueryContext<ProductRow> context,
    MssqlQueryState state,
    List<MssqlRelation<ProductRow, Object?>> included,
  ) => ProductQuery(context, state, included);

  /// `dbo.Products.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// ANDs `Id = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  ProductQuery whereId(int value) => rebuild(state.where_(fields.id.eq(value)));

  /// `dbo.Products.CategoryId` — int, NOT NULL.
  ///
  /// ANDs `CategoryId = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  ProductQuery whereCategoryId(int value) =>
      rebuild(state.where_(fields.categoryId.eq(value)));

  /// `dbo.Products.Sku` — nvarchar, NOT NULL.
  ///
  /// ANDs `Sku = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  ProductQuery whereSku(String value) =>
      rebuild(state.where_(fields.sku.eq(value)));

  /// `dbo.Products.Name` — nvarchar, NOT NULL.
  ///
  /// ANDs `Name = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  ProductQuery whereName(String value) =>
      rebuild(state.where_(fields.name.eq(value)));

  /// `dbo.Products.Price` — decimal, NOT NULL.
  ///
  /// ANDs `Price = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  ProductQuery wherePrice(MssqlDecimal value) =>
      rebuild(state.where_(fields.price.eq(value)));

  /// `dbo.Products.Stock` — int, NOT NULL.
  ///
  /// ANDs `Stock = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  ProductQuery whereStock(int value) =>
      rebuild(state.where_(fields.stock.eq(value)));

  /// UI sort: [column] must be a field of this table.
  ///
  /// A string from a query-string is not passed to SQL. The
  /// allowlist is the generated fields; anything else is an
  /// [ArgumentError] naming the legal keys.
  ProductQuery orderByNamed(String column, {bool descending = false}) {
    switch (column) {
      case 'id':
      case 'Id':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.id.desc() : o.id.asc()],
        );
      case 'categoryId':
      case 'CategoryId':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.categoryId.desc() : o.categoryId.asc(),
          ],
        );
      case 'sku':
      case 'Sku':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.sku.desc() : o.sku.asc()],
        );
      case 'name':
      case 'Name':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.name.desc() : o.name.asc()],
        );
      case 'price':
      case 'Price':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.price.desc() : o.price.asc()],
        );
      case 'stock':
      case 'Stock':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.stock.desc() : o.stock.asc()],
        );
      default:
        throw ArgumentError.value(
          column,
          'column',
          'ProductQuery cannot sort by "$column". Allowed: id, categoryId, sku, name, price, stock.',
        );
    }
  }

  /// Writes against `category` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.category)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<ProductRow, CategoryRow> categoryOf(
    ProductRow parent,
  ) => related(parent, (f) => f.category);

  /// Writes against `orderLines` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.orderLines)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<ProductRow, OrderLineRow> orderLinesOf(
    ProductRow parent,
  ) => related(parent, (f) => f.orderLines);

  /// Insert or return the live row with this unique Sku.
  ///
  /// Insert-first; a 2601/2627 on `UQ_Products_Sku` reads the winner. A collision on a different unique key is rethrown.
  Future<ProductRow> getOrCreateBySku(
    String sku, {
    required int categoryId,
    required String name,
    required MssqlDecimal price,
    required int stock,
    bool restoreExisting = false,
    bool includeDeleted = false,
  }) {
    return getOrCreate(
      key: ProductUnique.sku(sku),
      create: ProductRowBaseCreate(
        categoryId: categoryId,
        sku: sku,
        name: name,
        price: price,
        stock: stock,
      ).toAssignments(binding.erase()),
      restoreExisting: restoreExisting,
      includeDeleted: includeDeleted,
    );
  }

  /// Partial update of matching rows.
  ///
  /// Absent patch fields are not named. [expectedVersion] is the rowversion token; a table without one refuses it.
  Future<int> update(
    ProductRowBasePatch patch, {
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
  Future<ProductRow> create(ProductRowBaseCreate input) =>
      createValues(input.toAssignments(binding.erase()));

  /// Batched insert. Never switches to BCP on its own.
  Future<MssqlCreateManyResult<ProductRow>> createMany(
    List<ProductRowBaseCreate> rows, {
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
    Map<int, ProductRowBasePatch> byKey, {
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
  Future<ProductRow> createGraph(
    ProductRowBaseCreate input, {
    CategoryRowBaseCreate? category,
    List<OrderLineRowBaseCreate>? orderLines,
    MssqlCycleWrite cycleWrite = MssqlCycleWrite.refuse,
  }) {
    final categoryInput = category;
    final orderLinesInput = orderLines;
    return createGraphValues(
      MssqlGraphInsert(
        input.toAssignments(binding.erase()),
        related: <MssqlGraphRelation>[
          if (categoryInput != null)
            MssqlGraphRelation(
              fields.category.asInclude,
              <MssqlGraphInsert<Object?>>[
                MssqlGraphInsert(
                  categoryInput.toAssignments(
                    fields.category.targetBinding.erase(),
                  ),
                ),
              ],
            ),
          if (orderLinesInput != null)
            MssqlGraphRelation(
              fields.orderLines.asInclude,
              <MssqlGraphInsert<Object?>>[
                for (final item in orderLinesInput)
                  MssqlGraphInsert(
                    item.toAssignments(fields.orderLines.targetBinding.erase()),
                  ),
              ],
            ),
        ],
      ),
      cycle: cycleWrite,
    );
  }

  /// The row with this primary key, or null.
  Future<ProductRow?> find(int key) => whereId(key).first();

  /// The row with this primary key, or not-found.
  Future<ProductRow> getById(int key) => whereId(key).firstOrFail();
}

/// Reads and writes dbo.Products.
class ProductRepositoryBase extends MssqlRepository<ProductRow, int> {
  /// [schema] and [table] point this repository at another
  /// table of the same shape — Eloquent's `$table`.
  ProductRepositoryBase(
    super.session, {
    super.dialect,
    super.schema,
    super.table,
  }) : super(binding: tableBinding);

  /// Named tableBinding rather than binding: a static cannot
  /// share a name with an inherited instance member.
  static final MssqlTableBinding<ProductRow> tableBinding =
      MssqlTableBinding<ProductRow>(
        schema: 'dbo',
        table: 'Products',
        primaryKey: const <String>['Id'],
        identityColumn: 'Id',
        insertStrategy: MssqlInsertStrategy.outputInserted,
        decimalMode: MssqlDecimalMode.exact,
        schemaFingerprint:
            '105153bdbfabcfd2e0f045821c8c56ad35dc6d1ef5d54592bd14cf66cfc8f357',
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
            name: 'CategoryId',
            type: MssqlType.int32,
            maxLength: 0,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'Sku',
            type: MssqlType.nvarchar,
            maxLength: 40,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'Name',
            type: MssqlType.nvarchar,
            maxLength: 400,
            precision: 0,
            scale: 0,
          ),
          MssqlBoundColumn(
            name: 'Price',
            type: MssqlType.decimal,
            maxLength: 0,
            precision: 18,
            scale: 2,
          ),
          MssqlBoundColumn(
            name: 'Stock',
            type: MssqlType.int32,
            maxLength: 0,
            precision: 0,
            scale: 0,
          ),
        ],
        fromRow: ProductRowBase.fromRow,
        toColumns: (row) => row.toColumns(),
        readColumn: (row, name) => row.columnValue(name),
        applyRelations: (row, relations) => row.withRelations(relations),
        isRelationLoaded: (row, name) => row.isLoaded(name),
      );
}
