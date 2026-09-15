/// The version of the public API contract that generated code is written
/// against.
///
/// Generated files record this number in their header and in the binding they
/// declare; the runtime refuses a file written against a different contract,
/// because a mismatch means generated code calling methods with names or
/// meanings this runtime no longer has.
///
/// It is folded into the schema fingerprint, so a contract change invalidates
/// every generated file even when no table moved.
///
/// See `doc/API_CONTRACT.md`.
abstract final class MssqlApiVersion {
  /// The contract this runtime implements.
  static const int current = 2;

  /// The lowest contract version this runtime can still read.
  ///
  /// Equal to [current] while there are no released consumers to stay
  /// compatible with.
  static const int minimumSupported = current;

  /// Whether generated code stamped with [version] can run here.
  static bool supports(int version) =>
      version >= minimumSupported && version <= current;

  /// The message a mismatch reports, naming both sides and the fix.
  static String mismatchMessage(int version, String origin) =>
      'Generated code in $origin was written against ORM API contract version '
      '$version, but this runtime implements version $current '
      '(oldest readable: $minimumSupported). Regenerate with a matching '
      'mssql_orm_dev: dart run mssql_orm_dev:generate';
}
