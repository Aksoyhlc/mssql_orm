// Created once by mssql_orm_dev and never rewritten.
// This file is yours: put application queries and behaviour here.
//
// The generated half lives in ../generated/categories.g.dart
// and is replaced on every run.

import '../generated/categories.g.dart';

export '../generated/categories.g.dart';

class CategoryRow extends CategoryRowBase {
  const CategoryRow({
    required super.id,
    super.parentId,
    required super.name,
    super.children,
    super.parent,
    super.products,
    super.loadedRelations,
    super.truncatedRelations,
  });
}

class CategoryRepository extends CategoryRepositoryBase {
  CategoryRepository(super.session, {super.dialect, super.schema, super.table});

  // To read a different table of the same shape
  //
  //   CategoryRepository(super.session) : super(table: 'Categories_Archive');

  // Application queries go here, for example:
  //
  //   Future<List<CategoryRow>> search(String term) =>
  //       findWhere(Category.id.like(term));
}
