// Created once by mssql_orm_dev and never rewritten.
// This file is yours: put application queries and behaviour here.
//
// The generated half lives in ../generated/products.g.dart
// and is replaced on every run.

import '../generated/products.g.dart';

export '../generated/products.g.dart';

class ProductRow extends ProductRowBase {
  const ProductRow({
    required super.id,
    required super.categoryId,
    required super.sku,
    required super.name,
    required super.price,
    required super.stock,
    super.category,
    super.orderLines,
    super.loadedRelations,
    super.truncatedRelations,
  });
}

class ProductRepository extends ProductRepositoryBase {
  ProductRepository(super.session, {super.dialect, super.schema, super.table});

  // To read a different table of the same shape
  //
  //   ProductRepository(super.session) : super(table: 'Products_Archive');

  // Application queries go here, for example:
  //
  //   Future<List<ProductRow>> search(String term) =>
  //       findWhere(Product.id.like(term));
}
