// Created once by mssql_orm_dev and never rewritten.
// This file is yours: put application queries and behaviour here.
//
// The generated half lives in ../generated/order_lines.g.dart
// and is replaced on every run.

import '../generated/order_lines.g.dart';

export '../generated/order_lines.g.dart';

class OrderLineRow extends OrderLineRowBase {
  const OrderLineRow({
    required super.id,
    required super.orderId,
    required super.productId,
    required super.quantity,
    required super.unitPrice,
    required super.lineTotal,
    super.order,
    super.product,
    super.loadedRelations,
    super.truncatedRelations,
  });
}

class OrderLineRepository extends OrderLineRepositoryBase {
  OrderLineRepository(super.session, {super.dialect, super.schema, super.table});

  // To read a different table of the same shape
  //
  //   OrderLineRepository(super.session) : super(table: 'OrderLines_Archive');

  // Application queries go here, for example:
  //
  //   Future<List<OrderLineRow>> search(String term) =>
  //       findWhere(OrderLine.id.like(term));
}
