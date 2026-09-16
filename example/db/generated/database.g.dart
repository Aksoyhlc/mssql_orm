// GENERATED — do not edit. Rewritten on every run.
//
// Generator: mssql_orm_dev 0.1.1
// API contract: 2

import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'categories.g.dart';
import 'customers.g.dart';
import 'order_lines.g.dart';
import 'orders.g.dart';
import 'products.g.dart';
import 'queries.g.dart';

/// The entry point for ORM access to the database.
///
/// Wrap a connection with [borrow], a pool with
/// [withPool], or open one with [open]. Each getter
/// returns an immutable table query
/// bound to this database's session; inside [transaction],
/// the same getter on the callback's database uses the
/// transaction's session.
class AppDatabase extends MssqlAppDatabase<AppDatabase> {
  AppDatabase(
    super.session, {
    super.clock,
    super.owned,
    super.pool,
    super.changes,
    super.capabilities,
    super.observer,
    super.observerOptions,
  });

  /// A connection the caller opened and closes.
  ///
  /// Narrower than the [MssqlSession] the base class takes,
  /// on purpose: this is the connection-backed constructor,
  /// and a super parameter would widen it back to any
  /// session — including one that cannot open a transaction.
  // ignore: use_super_parameters
  AppDatabase.borrow(MssqlConnection connection) : super(connection);

  /// A pool the caller created and closes.
  ///
  /// Each statement takes a lease and gives it back;
  /// [transaction] holds one lease for the whole callback.
  AppDatabase.withPool(MssqlConnectionPool pool)
    : super(pool.session, pool: pool);

  /// Opens and owns a connection. [close] closes it.
  static Future<AppDatabase> open(MssqlConnectionConfig config) async {
    final connection = await MssqlConnection.open(config);
    return AppDatabase(connection, owned: true);
  }

  /// Opens and owns a pool. [close] closes it.
  static AppDatabase openPool(
    MssqlConnectionConfig config, {
    MssqlPoolConfig pool = const MssqlPoolConfig(),
  }) {
    final created = MssqlConnectionPool(config, poolConfig: pool);
    return AppDatabase(created.session, pool: created, owned: true);
  }

  @override
  AppDatabase fork(MssqlSession session) => AppDatabase(
    session,
    clock: clock,
    changes: changes,
    capabilities: capabilities,
    observer: observer,
    observerOptions: observerOptions,
  );

  /// Reads and writes dbo.Categories.
  CategoryQuery get categories =>
      CategoryQuery(contextFor(CategoryRepositoryBase.tableBinding));

  /// Reads and writes dbo.Customers.
  CustomerQuery get customers =>
      CustomerQuery(contextFor(CustomerRepositoryBase.tableBinding));

  /// Reads and writes dbo.OrderLines.
  OrderLineQuery get orderLines =>
      OrderLineQuery(contextFor(OrderLineRepositoryBase.tableBinding));

  /// Reads and writes dbo.Orders.
  OrderQuery get orders =>
      OrderQuery(contextFor(OrderRepositoryBase.tableBinding));

  /// Reads and writes dbo.Products.
  ProductQuery get products =>
      ProductQuery(contextFor(ProductRepositoryBase.tableBinding));

  /// Typed methods generated from `.sql` files.
  AppDatabaseReports get reports => AppDatabaseReports(this);
}
