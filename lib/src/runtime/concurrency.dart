import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'observer.dart';

/// A unique-key lookup the schema actually guarantees.
///
/// Filtered and disabled indexes never become one of these: they do not
/// make a row unique across the table, so getOrCreate would race or
/// return the wrong row. Generated `CustomerUnique.code('ACME')` is the
/// call site; constructing this by hand is for keys the generator has
/// not emitted yet.
@immutable
class MssqlUniqueMatch {
  MssqlUniqueMatch({
    required this.indexName,
    required Map<String, Object?> values,
  }) : values = Map<String, Object?>.unmodifiable(values) {
    if (indexName.trim().isEmpty) {
      throw ArgumentError.value(
        indexName,
        'indexName',
        'A unique match needs the index or constraint name SQL Server '
            'reports on 2601/2627, so a collision on a *different* unique '
            'key is not treated as a hit.',
      );
    }
    if (this.values.isEmpty) {
      throw ArgumentError.value(
        values,
        'values',
        'A unique match needs at least one column.',
      );
    }
    for (final entry in this.values.entries) {
      if (entry.value == null) {
        throw ArgumentError.value(
          entry.key,
          'values',
          'Unique match "$indexName" has a null for "${entry.key}". SQL '
              'Server UNIQUE allows many NULLs, so getOrCreate cannot tell '
              'which row would win.',
        );
      }
    }
  }

  /// sys.indexes / constraint name, compared without regard to case.
  final String indexName;

  /// Key columns to values, schema spelling.
  final Map<String, Object?> values;
}

/// Parses the index or constraint name out of a 2601/2627 message.
///
/// 2601: `with unique index 'IX_Customers_Code'`
/// 2627: `Violation of UNIQUE KEY constraint 'UQ_…'` or
/// `PRIMARY KEY constraint 'PK_…'`
///
/// Returning null means the message did not name a key, so the caller
/// must not treat the failure as the expected unique key already existing.
String? duplicateKeyName(String message) {
  final match = RegExp(
    r"unique index '([^']+)'"
    r"|UNIQUE KEY constraint '([^']+)'"
    r"|PRIMARY KEY constraint '([^']+)'",
    caseSensitive: false,
  ).firstMatch(message);
  if (match == null) return null;
  return match.group(1) ?? match.group(2) ?? match.group(3);
}

/// Whether [error] names [expected] as the colliding key.
///
/// A 2627 on a *different* unique index is not a getOrCreate hit: the
/// insert failed because some other column collided, and returning an
/// existing row for the requested key would hide that.
bool duplicateKeyIs(MssqlException error, String expected) {
  if (!_isDuplicateKey(error)) return false;
  final named = duplicateKeyName(error.message);
  if (named == null) return false;
  return named.toLowerCase() == expected.toLowerCase();
}

bool _isDuplicateKey(MssqlException error) {
  if (error is MssqlConstraintException) return error.isDuplicateKey;
  return error.code == 2601 || error.code == 2627;
}

/// Whether [session] can still run a statement.
///
/// A doomed transaction throws on the next command; reading the winner
/// after a unique collision would replace a useful 2627 with that
/// StateError.
bool sessionIsDoomed(MssqlSession session) {
  var current = session;
  while (current is MssqlObservedSession) {
    current = current.inner;
  }
  return current is MssqlTransaction && current.isDoomed;
}
