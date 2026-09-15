import 'package:mssql_native/mssql_native.dart';

import '../statement.dart';

/// Whether the ORM may let the driver repeat a statement it compiled.
///
/// The driver's own default is [MssqlRetryPolicy.never], and it is right to
/// be: a statement that returns rows may still have written some. The ORM is
/// in a narrower position — for a statement it built itself out of its own
/// AST, it knows the shape it produced, and a SELECT it wrote is a SELECT.
///
/// That knowledge stops at the first raw fragment. `raw('…')` can hold
/// anything, so a statement carrying one goes back to the driver's default
/// rather than borrowing the builder's confidence about the rest of the SQL.
extension MssqlStatementRetry on MssqlStatement {
  /// The retry policy for running this statement as a read.
  ///
  /// Only call it on a statement the builder compiled from a SELECT; it says
  /// nothing about DML, and the write paths never ask.
  MssqlRetryPolicy get readRetry =>
      containsRawSql ? MssqlRetryPolicy.never : MssqlRetryPolicy.idempotentRead;
}
