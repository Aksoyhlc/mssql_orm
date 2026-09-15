// GENERATED — do not edit. Rewritten on every run.
//
// Source: dbo.Categories
// Generator: mssql_orm_dev 0.1.0
// API contract: 2
// Schema fingerprint: be97dbf61c0fd24d7100c1139af476fb9bdaf7d11058fb72adc8ea1bf524bfca
//
// Foreign keys:
//   ParentId -> dbo.Categories (Id)
//
// Application code belongs in ../models/categories.dart,
// which this generator creates once and never touches again.

import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import '../models/categories.dart';
import '../models/products.dart';

/// One row of dbo.Categories.
///
/// `copyWith` and `==` cover the fields declared here. A
/// field added to CategoryRow is not carried by either, which
/// is inherent to the split; adding behaviour is free.
@immutable
class CategoryRowBase {
  const CategoryRowBase({
    required this.id,
    this.parentId,
    required this.name,
    List<CategoryRow>? children,
    CategoryRow? parent,
    List<ProductRow>? products,
    Set<String> loadedRelations = const <String>{},
    Map<String, int> truncatedRelations = const <String, int>{},
  }) : _children = children,
       _parent = parent,
       _products = products,
       _loadedRelations = loadedRelations,
       _truncatedRelations = truncatedRelations;

  /// IDENTITY.
  final int id;
  final int? parentId;
  final String name;

  final List<CategoryRow>? _children;
  final CategoryRow? _parent;
  final List<ProductRow>? _products;
  final Set<String> _loadedRelations;
  final Map<String, int> _truncatedRelations;

  /// Whether [relation] was loaded for this row.
  ///
  /// True for loaded-null and loaded-empty. Truncated is
  /// still loaded; [isTruncated] is the incomplete flag.
  bool isLoaded(String relation) => _loadedRelations.contains(relation);

  /// Typed form of [isLoaded]: the handle, not a string.
  bool relationLoaded<TChild>(MssqlRelation<CategoryRow, TChild> relation) =>
      isLoaded(relation.name);

  /// Whether [relation] hit maxLoadedRows.
  bool isTruncated(String relation) =>
      _truncatedRelations.containsKey(relation);

  /// Throws when the relation was not loaded. An empty
  /// list means loaded and none.
  List<CategoryRow> get children {
    if (!_loadedRelations.contains('children')) {
      throw MssqlRelationNotLoadedException('dbo.Categories', 'children');
    }
    if (_truncatedRelations.containsKey('children')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.Categories',
        relation: 'children',
        limit: _truncatedRelations['children']!,
      );
    }
    return _children ?? const [];
  }

  /// Throws when the relation was not loaded, so that a
  /// null answer means exactly one thing: there is no
  /// counterpart. Without the guard, forgetting to load
  /// would read as "no counterpart" and quietly give the
  /// wrong answer.
  CategoryRow? get parent {
    if (!_loadedRelations.contains('parent')) {
      throw MssqlRelationNotLoadedException('dbo.Categories', 'parent');
    }
    if (_truncatedRelations.containsKey('parent')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.Categories',
        relation: 'parent',
        limit: _truncatedRelations['parent']!,
      );
    }
    return _parent;
  }

  /// Throws when the relation was not loaded. An empty
  /// list means loaded and none.
  List<ProductRow> get products {
    if (!_loadedRelations.contains('products')) {
      throw MssqlRelationNotLoadedException('dbo.Categories', 'products');
    }
    if (_truncatedRelations.containsKey('products')) {
      throw MssqlRelationTruncatedException(
        table: 'dbo.Categories',
        relation: 'products',
        limit: _truncatedRelations['products']!,
      );
    }
    return _products ?? const [];
  }

  /// Reads a row by ordinal after checking column names.
  ///
  /// Name lookup on every field would rebuild a map the
  /// driver already has. Extra trailing columns are allowed
  /// so a withCount projection can append aggregates.
  static const List<String> columnOrder = <String>['Id', 'ParentId', 'Name'];
  static CategoryRow fromRow(MssqlRow row) {
    row.assertOrdinalNames(columnOrder);
    return CategoryRow(
      id: (row.at(0)! as num).toInt(),
      parentId: (row.at(1) as num?)?.toInt(),
      name: row.at(2)! as String,
    );
  }

  /// One column of this row, by SQL name.
  Object? columnValue(String name) => switch (name) {
    'Id' => id,
    'ParentId' => parentId,
    'Name' => name,
    _ => throw ArgumentError.value(
      name,
      'name',
      'CategoryRow has no column named "$name".',
    ),
  };

  Map<String, Object?> toColumns() => <String, Object?>{
    'Id': id,
    'ParentId': parentId,
    'Name': name,
  };

  CategoryRow copyWith({int? id, int? parentId, String? name}) => CategoryRow(
    id: id ?? this.id,
    parentId: parentId ?? this.parentId,
    name: name ?? this.name,
    children: _children,
    parent: _parent,
    products: _products,
    loadedRelations: _loadedRelations,
    truncatedRelations: _truncatedRelations,
  );

  /// Returns a copy carrying the loaded relations.
  ///
  /// Rows are immutable, so the loader cannot write into
  /// one; it asks for a new row instead.
  CategoryRow withRelations(Map<String, Object?> relations) => CategoryRow(
    id: id,
    parentId: parentId,
    name: name,
    children: relations.containsKey('children')
        ? (relations['children']! as List<Object?>).cast<CategoryRow>()
        : _children,
    parent: relations.containsKey('parent')
        ? relations['parent'] as CategoryRow?
        : _parent,
    products: relations.containsKey('products')
        ? (relations['products']! as List<Object?>).cast<ProductRow>()
        : _products,
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
      other is CategoryRowBase &&
          other.id == id &&
          other.parentId == parentId &&
          other.name == name;

  @override
  int get hashCode => Object.hashAll(<Object?>[id, parentId, name]);

  @override
  String toString() => 'CategoryRow(id: $id, parentId: $parentId, name: $name)';
}

/// Values for inserting one row into dbo.Categories.
///
/// Identity, computed, rowversion and read-only columns
/// are absent: the server owns them. A non-null column
/// without a default is required; a nullable or defaulted
/// column is optional, and omitting it means SQL DEFAULT.
@immutable
class CategoryRowBaseCreate {
  const CategoryRowBaseCreate({this.parentId, required this.name});

  /// Nullable.
  final int? parentId;
  final String name;

  /// Builds the write assignments for [MssqlRepository.insert].
  MssqlWriteAssignments toAssignments(MssqlTableBinding<Object?> binding) {
    final values = <String, MssqlWriteValue>{};
    if (parentId != null || binding.column('ParentId')!.nullable) {
      values['ParentId'] = MssqlBoundValue(
        binding.column('ParentId')!.bind(parentId),
      );
    }
    values['Name'] = MssqlBoundValue(binding.column('Name')!.bind(name));
    return MssqlWriteAssignments(values);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CategoryRowBaseCreate &&
          other.parentId == parentId &&
          other.name == name;

  @override
  int get hashCode => Object.hashAll(<Object?>[parentId, name]);

  @override
  String toString() =>
      'CategoryRowBaseCreate(parentId: $parentId, name: $name)';
}

/// A partial update of dbo.Categories.
///
/// Each field is a [Field]: [Field.absent] means "don't
/// touch", [Field.value] means "set to this". A nullable
/// column accepts `Field<T?>.value(null)` to clear it;
/// a non-null column's `Field<T>` cannot carry null.
@immutable
class CategoryRowBasePatch {
  const CategoryRowBasePatch({
    this.parentId = const Field.absent(),
    this.name = const Field.absent(),
  });

  /// Nullable.
  final Field<int?> parentId;
  final Field<String> name;

  /// Builds the write assignments for [MssqlRepository.update] / [MssqlRepository.updateWhere].
  MssqlWriteAssignments toAssignments(MssqlTableBinding<Object?> binding) {
    final values = <String, MssqlWriteValue>{};
    if (parentId.isPresent) {
      values['ParentId'] = MssqlBoundValue(
        binding.column('ParentId')!.bind(parentId.value),
      );
    }
    if (name.isPresent) {
      values['Name'] = MssqlBoundValue(
        binding.column('Name')!.bind(name.value),
      );
    }
    return MssqlWriteAssignments(values);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CategoryRowBasePatch &&
          other.parentId == parentId &&
          other.name == name;

  @override
  int get hashCode => Object.hashAll(<Object?>[parentId, name]);

  @override
  String toString() => 'CategoryRowBasePatch(parentId: $parentId, name: $name)';
}

/// Typed column references for dbo.Categories.
abstract final class Category {
  static const String table = 'dbo.Categories';

  /// Which table these columns belong to.
  ///
  /// The columns below name this rather than writing
  /// `[dbo].[Categories]` into
  /// themselves, so that a query that aliases the table, or
  /// one pointed at another schema, still refers to the
  /// source it actually has.
  static const MssqlSourceRef source = MssqlSourceRef(
    schema: 'dbo',
    table: 'Categories',
  );

  /// `dbo.Categories.Id` — int, NOT NULL, IDENTITY, read-only.
  static final MssqlIntColumn id = column$id(source);

  /// `dbo.Categories.ParentId` — int, nullable.
  static final MssqlIntColumn parentId = column$parentId(source);

  /// `dbo.Categories.Name` — nvarchar, NOT NULL.
  static final MssqlStringColumn name = column$name(source);

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

  static MssqlIntColumn column$parentId(MssqlSourceRef source) =>
      MssqlIntColumn.of(
        source: source,
        name: 'ParentId',
        quotedName: '[ParentId]',
        columnType: MssqlColumnType(
          type: MssqlType.int32,
          size: 0,
          precision: 0,
          scale: 0,
          nullable: true,
          columnName: 'ParentId',
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
}

/// Relations of dbo.Categories, from its foreign
/// keys. Pass these to `include:` to load them eagerly.
abstract final class CategoryRel {
  static MssqlRelation<CategoryRow, CategoryRow> get children =>
      MssqlRelation<CategoryRow, CategoryRow>(
        name: 'children',
        kind: MssqlRelationKind.hasMany,
        targetBinding: CategoryRepositoryBase.tableBinding,
        localColumns: const <String>['Id'],
        foreignColumns: const <String>['ParentId'],
      );
  static MssqlRelation<CategoryRow, CategoryRow> get parent =>
      MssqlRelation<CategoryRow, CategoryRow>(
        name: 'parent',
        kind: MssqlRelationKind.belongsTo,
        targetBinding: CategoryRepositoryBase.tableBinding,
        localColumns: const <String>['ParentId'],
        foreignColumns: const <String>['Id'],
      );
  static MssqlRelation<CategoryRow, ProductRow> get products =>
      MssqlRelation<CategoryRow, ProductRow>(
        name: 'products',
        kind: MssqlRelationKind.hasMany,
        targetBinding: ProductRepositoryBase.tableBinding,
        localColumns: const <String>['Id'],
        foreignColumns: const <String>['CategoryId'],
      );
}

/// Typed include modifiers for CategoryRow.children.
extension CategoryChildrenInclude on MssqlRelation<CategoryRow, CategoryRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<CategoryRow, CategoryRow> where(
    MssqlCondition Function(CategoryFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const CategoryFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<CategoryRow, CategoryRow> orderBy(
    List<MssqlOrder> Function(CategoryFields fields) ordering,
  ) => ordered(ordering(const CategoryFields()));

  /// Nested includes of the target.
  MssqlRelation<CategoryRow, CategoryRow> include(
    Iterable<MssqlRelation<CategoryRow, Object?>> Function(
      CategoryFields fields,
    )
    nested,
  ) => withNested(nested(const CategoryFields()));
}

/// Typed include modifiers for CategoryRow.parent.
extension CategoryParentInclude on MssqlRelation<CategoryRow, CategoryRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<CategoryRow, CategoryRow> where(
    MssqlCondition Function(CategoryFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const CategoryFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<CategoryRow, CategoryRow> orderBy(
    List<MssqlOrder> Function(CategoryFields fields) ordering,
  ) => ordered(ordering(const CategoryFields()));

  /// Nested includes of the target.
  MssqlRelation<CategoryRow, CategoryRow> include(
    Iterable<MssqlRelation<CategoryRow, Object?>> Function(
      CategoryFields fields,
    )
    nested,
  ) => withNested(nested(const CategoryFields()));
}

/// Typed include modifiers for CategoryRow.products.
extension CategoryProductsInclude on MssqlRelation<CategoryRow, ProductRow> {
  /// ANDs a predicate on the target row.
  MssqlRelation<CategoryRow, ProductRow> where(
    MssqlCondition Function(ProductFields fields) predicate,
  ) => filtered(<MssqlCondition>[predicate(const ProductFields())]);

  /// Orders loaded children from target fields.
  MssqlRelation<CategoryRow, ProductRow> orderBy(
    List<MssqlOrder> Function(ProductFields fields) ordering,
  ) => ordered(ordering(const ProductFields()));

  /// Nested includes of the target.
  MssqlRelation<CategoryRow, ProductRow> include(
    Iterable<MssqlRelation<ProductRow, Object?>> Function(ProductFields fields)
    nested,
  ) => withNested(nested(const ProductFields()));
}

/// Typed SQL columns of dbo.Categories.
///
/// A row this is not: there is no `id` integer here, only
/// the column that becomes `WHERE [Id] = @p`. The query
/// callback takes this type so `o` completes to columns.
class CategoryFields {
  /// Columns of the generated table, or — with a
  /// [MssqlSourceRef] — of the same table under another
  /// schema or name, as `at(schema:, table:)` produces.
  const CategoryFields([this._source]);

  final MssqlSourceRef? _source;

  /// Which source these columns resolve against.
  MssqlSourceRef get source => _source ?? Category.source;

  /// `dbo.Categories.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// `whereId` ANDs an equality on this column.
  MssqlIntColumn get id {
    final ref = _source;
    return ref == null ? Category.id : Category.column$id(ref);
  }

  /// `dbo.Categories.ParentId` — int, nullable.
  ///
  /// `whereParentId` ANDs an equality on this column.
  MssqlIntColumn get parentId {
    final ref = _source;
    return ref == null ? Category.parentId : Category.column$parentId(ref);
  }

  /// `dbo.Categories.Name` — nvarchar, NOT NULL.
  ///
  /// `whereName` ANDs an equality on this column.
  MssqlStringColumn get name {
    final ref = _source;
    return ref == null ? Category.name : Category.column$name(ref);
  }

  /// Include handle for `children`.
  ///
  /// `include((o) => [o.children])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<CategoryRow, CategoryRow> get children => CategoryRel.children;

  /// Include handle for `parent`.
  ///
  /// `include((o) => [o.parent])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<CategoryRow, CategoryRow> get parent => CategoryRel.parent;

  /// Include handle for `products`.
  ///
  /// `include((o) => [o.products])` loads this path. Typed `where`/`orderBy`/`include` hang off the generated extension on this relation type.
  MssqlRelation<CategoryRow, ProductRow> get products => CategoryRel.products;
}

/// Query over dbo.Categories.
///
/// Every entity-preserving call returns [CategoryQuery], so a user
/// extension (`extension on CategoryQuery`) stays in the chain.
/// `whereX` shortcuts AND an equality; OR stays in
/// `where((o) => … | …)`.
class CategoryQuery
    extends MssqlEntityQuery<CategoryRow, CategoryFields, CategoryQuery> {
  CategoryQuery(super.context, [super.state, super.included]);

  @override
  /// Columns bound to whatever source this query has.
  ///
  /// The constant instance for the generated table, and a
  /// rebound one after `at(schema:, table:)`, so a
  /// predicate written after a rebind names the table this
  /// statement actually reads.
  CategoryFields get fields => binding.sourceRef == Category.source
      ? const CategoryFields()
      : CategoryFields(binding.sourceRef);

  @override
  CategoryQuery recreate(
    MssqlQueryState state,
    List<MssqlRelation<CategoryRow, Object?>> included,
  ) => CategoryQuery(context, state, included);

  @override
  CategoryQuery recreateAt(
    MssqlQueryContext<CategoryRow> context,
    MssqlQueryState state,
    List<MssqlRelation<CategoryRow, Object?>> included,
  ) => CategoryQuery(context, state, included);

  /// `dbo.Categories.Id` — int, NOT NULL, IDENTITY, read-only.
  ///
  /// ANDs `Id = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CategoryQuery whereId(int value) =>
      rebuild(state.where_(fields.id.eq(value)));

  /// `dbo.Categories.ParentId` — int, nullable.
  ///
  /// ANDs `ParentId = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CategoryQuery whereParentId(int value) =>
      rebuild(state.where_(fields.parentId.eq(value)));

  /// `dbo.Categories.Name` — nvarchar, NOT NULL.
  ///
  /// ANDs `Name = @value`. The parameter is non-null
  /// even when the column is nullable: `= NULL` never matches, so
  /// NULL uses `isNull` / `isNotNull` on the callback.
  CategoryQuery whereName(String value) =>
      rebuild(state.where_(fields.name.eq(value)));

  /// UI sort: [column] must be a field of this table.
  ///
  /// A string from a query-string is not passed to SQL. The
  /// allowlist is the generated fields; anything else is an
  /// [ArgumentError] naming the legal keys.
  CategoryQuery orderByNamed(String column, {bool descending = false}) {
    switch (column) {
      case 'id':
      case 'Id':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.id.desc() : o.id.asc()],
        );
      case 'parentId':
      case 'ParentId':
        return orderBy(
          (o) => <MssqlOrder>[
            descending ? o.parentId.desc() : o.parentId.asc(),
          ],
        );
      case 'name':
      case 'Name':
        return orderBy(
          (o) => <MssqlOrder>[descending ? o.name.desc() : o.name.asc()],
        );
      default:
        throw ArgumentError.value(
          column,
          'column',
          'CategoryQuery cannot sort by "$column". Allowed: id, parentId, name.',
        );
    }
  }

  /// The recursive walk of dbo.Categories
  /// down ParentId, as a reusable expression.
  static MssqlHierarchy<int> get hierarchy => MssqlHierarchy<int>(
    tableParts: CategoryRepositoryBase.tableBinding.nameParts,
    key: const CategoryFields().id,
    parentKey: const CategoryFields().parentId,
    name: 'categories_descendants',
  );

  /// Rows under [root], following ParentId.
  ///
  /// [maxDepth] counts generations below the root, which is
  /// depth 0, and is applied inside the recursion so the
  /// server stops expanding rather than expanding and then
  /// filtering. [maxRecursion] is a different limit: it is
  /// SQL Server's `OPTION (MAXRECURSION n)` guard, which
  /// fails the query instead of returning rows.
  ///
  /// [cycles] defaults to
  /// [MssqlCycleHandling.error]: a row that is its own
  /// ancestor is a data bug, and quietly walking past it
  /// would hide it. Pass
  /// [MssqlCycleHandling.skipVisited] to walk anyway.
  ///
  /// The result is an ordinary [CategoryQuery]: this query's
  /// scopes, ordering, includes and paging still apply, and
  /// the walk itself is unscoped — a soft-deleted parent
  /// still links its children, and the page's own
  /// soft-delete filter is what hides rows.
  CategoryQuery descendantsOf(
    int root, {
    int? maxDepth,
    bool includeRoot = true,
    MssqlCycleHandling cycles = MssqlCycleHandling.error,
    int? maxRecursion,
  }) {
    final walk = hierarchy.descendantsCte(
      root,
      maxDepth: maxDepth,
      cycles: cycles,
      maxRecursion: maxRecursion,
    );
    var keys = MssqlQuery.from(
      walk.name,
      ref: walk.ref,
    ).select(<MssqlExpression>[walk.column(MssqlHierarchy.keyField)]);
    if (!includeRoot) {
      keys = keys.where(walk.column(MssqlHierarchy.depthField).gt(0));
    }
    return withTypedCte(
      walk,
    ).where((f) => MssqlInSubquery(f.id, keys, negated: false));
  }

  /// Writes against `children` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.children)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<CategoryRow, CategoryRow> childrenOf(
    CategoryRow parent,
  ) => related(parent, (f) => f.children);

  /// Writes against `parent` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.parent)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<CategoryRow, CategoryRow> parentOf(
    CategoryRow parent,
  ) => related(parent, (f) => f.parent);

  /// Writes against `products` of [parent].
  ///
  /// Same object as `related(parent, (f) => f.products)`.
  /// create/associate/attach never cascade-delete the other side.
  MssqlRelationMutation<CategoryRow, ProductRow> productsOf(
    CategoryRow parent,
  ) => related(parent, (f) => f.products);

  /// Partial update of matching rows.
  ///
  /// Absent patch fields are not named. [expectedVersion] is the rowversion token; a table without one refuses it.
  Future<int> update(
    CategoryRowBasePatch patch, {
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
  Future<CategoryRow> create(CategoryRowBaseCreate input) =>
      createValues(input.toAssignments(binding.erase()));

  /// Batched insert. Never switches to BCP on its own.
  Future<MssqlCreateManyResult<CategoryRow>> createMany(
    List<CategoryRowBaseCreate> rows, {
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
    Map<int, CategoryRowBasePatch> byKey, {
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
  Future<CategoryRow> createGraph(
    CategoryRowBaseCreate input, {
    List<CategoryRowBaseCreate>? children,
    CategoryRowBaseCreate? parent,
    List<ProductRowBaseCreate>? products,
    MssqlCycleWrite cycleWrite = MssqlCycleWrite.refuse,
  }) {
    final childrenInput = children;
    final parentInput = parent;
    final productsInput = products;
    return createGraphValues(
      MssqlGraphInsert(
        input.toAssignments(binding.erase()),
        related: <MssqlGraphRelation>[
          if (childrenInput != null)
            MssqlGraphRelation(
              fields.children.asInclude,
              <MssqlGraphInsert<Object?>>[
                for (final item in childrenInput)
                  MssqlGraphInsert(
                    item.toAssignments(fields.children.targetBinding.erase()),
                  ),
              ],
            ),
          if (parentInput != null)
            MssqlGraphRelation(fields.parent.asInclude, <
              MssqlGraphInsert<Object?>
            >[
              MssqlGraphInsert(
                parentInput.toAssignments(fields.parent.targetBinding.erase()),
              ),
            ]),
          if (productsInput != null)
            MssqlGraphRelation(
              fields.products.asInclude,
              <MssqlGraphInsert<Object?>>[
                for (final item in productsInput)
                  MssqlGraphInsert(
                    item.toAssignments(fields.products.targetBinding.erase()),
                  ),
              ],
            ),
        ],
      ),
      cycle: cycleWrite,
    );
  }

  /// The row with this primary key, or null.
  Future<CategoryRow?> find(int key) => whereId(key).first();

  /// The row with this primary key, or not-found.
  Future<CategoryRow> getById(int key) => whereId(key).firstOrFail();
}

/// Reads and writes dbo.Categories.
class CategoryRepositoryBase extends MssqlRepository<CategoryRow, int> {
  /// [schema] and [table] point this repository at another
  /// table of the same shape — Eloquent's `$table`.
  CategoryRepositoryBase(
    super.session, {
    super.dialect,
    super.schema,
    super.table,
  }) : super(binding: tableBinding);

  /// Named tableBinding rather than binding: a static cannot
  /// share a name with an inherited instance member.
  static final MssqlTableBinding<CategoryRow> tableBinding =
      MssqlTableBinding<CategoryRow>(
        schema: 'dbo',
        table: 'Categories',
        primaryKey: const <String>['Id'],
        identityColumn: 'Id',
        insertStrategy: MssqlInsertStrategy.outputInserted,
        decimalMode: MssqlDecimalMode.exact,
        schemaFingerprint:
            'be97dbf61c0fd24d7100c1139af476fb9bdaf7d11058fb72adc8ea1bf524bfca',
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
            name: 'ParentId',
            type: MssqlType.int32,
            nullable: true,
            maxLength: 0,
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
        ],
        fromRow: CategoryRowBase.fromRow,
        toColumns: (row) => row.toColumns(),
        readColumn: (row, name) => row.columnValue(name),
        applyRelations: (row, relations) => row.withRelations(relations),
        isRelationLoaded: (row, name) => row.isLoaded(name),
      );
}
