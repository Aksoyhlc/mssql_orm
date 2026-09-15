// Created once by mssql_orm_dev and never rewritten.
// This file is yours: put application queries and behaviour here.
//
// The generated half lives in ../generated/customers.g.dart
// and is replaced on every run.

import '../generated/customers.g.dart';

export '../generated/customers.g.dart';

class CustomerRow extends CustomerRowBase {
  const CustomerRow({
    required super.id,
    required super.code,
    required super.name,
    super.city,
    required super.isActive,
    required super.createdAt,
    super.updatedAt,
    super.deletedAt,
    super.orders,
    super.loadedRelations,
    super.truncatedRelations,
  });
}

class CustomerRepository extends CustomerRepositoryBase {
  CustomerRepository(super.session, {super.dialect, super.schema, super.table});

  // To read a different table of the same shape
  //
  //   CustomerRepository(super.session) : super(table: 'Customers_Archive');

  // Application queries go here, for example:
  //
  //   Future<List<CustomerRow>> search(String term) =>
  //       findWhere(Customer.id.like(term));
}
