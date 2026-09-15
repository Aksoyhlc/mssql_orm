// Created once by mssql_orm_dev and never rewritten.
// This file is yours: put application queries and behaviour here.
//
// The generated half lives in ../generated/orders.g.dart
// and is replaced on every run.

import '../generated/orders.g.dart';

export '../generated/orders.g.dart';

class OrderRow extends OrderRowBase {
  const OrderRow({
    required super.id,
    required super.customerId,
    required super.code,
    required super.status,
    required super.total,
    required super.placedAt,
    required super.createdAt,
    super.updatedAt,
    super.deletedAt,
    super.customer,
    super.lines,
    super.loadedRelations,
    super.truncatedRelations,
  });
}

class OrderRepository extends OrderRepositoryBase {
  OrderRepository(super.session, {super.dialect, super.schema, super.table});

  // To read a different table of the same shape
  //
  //   OrderRepository(super.session) : super(table: 'Orders_Archive');

  // Application queries go here, for example:
  //
  //   Future<List<OrderRow>> search(String term) =>
  //       findWhere(Order.id.like(term));
}
