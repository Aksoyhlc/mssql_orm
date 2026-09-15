// Created once by mssql_orm_dev and never rewritten.
// Named scopes live here so regeneration cannot delete them.
//
// Import this file from application code when you want the
// extension in scope. Generated barrels do not export it,
// because an empty extension is yours to grow.

import '../generated/orders.g.dart';

extension OrderScopes on OrderQuery {
  /// Open orders: `Status = 'open'`.
  OrderQuery open() => whereStatus('open');
}
