/// The conclusions the ORM reaches, as distinct from what the server said.
///
/// Deliberately none of these is an `MssqlException`. That type carries what
/// the server or the connection reported; "the row you asked for is not there"
/// or "you changed more rows than you said you would" is a conclusion this
/// layer reached from a perfectly successful statement. Conflating the two
/// would change what `catch (MssqlException)` means for code that already
/// writes it.
library;

/// The shared supertype, so an application can catch every ORM-reached
/// conclusion in one place without also catching server errors.
abstract class MssqlOrmException implements Exception {
  const MssqlOrmException();

  /// A sentence naming what happened and, where there is one, what to do.
  String get message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Raised when a row a caller said must exist does not.
///
/// `getById`, `firstOrFail` and `single` all promise a row; this is what that
/// promise costs when it cannot be kept.
class MssqlRowNotFoundException extends MssqlOrmException {
  const MssqlRowNotFoundException(this.table, this.key);

  final String table;

  /// The key or predicate description that found nothing. Null when the query
  /// was a filter rather than a key lookup.
  final Object? key;

  @override
  String get message => key == null
      ? 'no row in $table matched the query.'
      : 'no row in $table with key $key.';
}

/// Raised when `single` or `singleOrNull` saw more than one row.
///
/// Separate from [MssqlRowNotFoundException] because the two mean opposite
/// things about the caller's filter, and an application that recovers from one
/// rarely wants to recover from the other.
class MssqlCardinalityException extends MssqlOrmException {
  const MssqlCardinalityException(this.table, this.method, this.seen);

  final String table;

  /// The terminal that made the promise: `single`, `singleOrNull`, …
  final String method;

  /// How many rows were seen before giving up. The reader stops early, so this
  /// is a lower bound, not the full count.
  final int seen;

  @override
  String get message =>
      '$method on $table expected at most one row but saw at least $seen. '
      'Use first() to take the first row of an ordered query.';
}

/// Raised when a write changed a different number of rows than the caller
/// declared with `expectAffected`.
///
/// The write itself succeeded. Whether it is still in the database depends on
/// the transaction the guard ran in — see `doc/API_CONTRACT.md` §4.
class MssqlAffectedRowsException extends MssqlOrmException {
  const MssqlAffectedRowsException({
    required this.table,
    required this.operation,
    required this.expected,
    required this.actual,
    this.rolledBack = false,
  });

  final String table;

  /// `update`, `delete`, `decrement`, …
  final String operation;
  final int expected;
  final int actual;

  /// Whether this layer rolled the write back. False when the caller's own
  /// transaction owns that decision.
  final bool rolledBack;

  @override
  String get message =>
      '$operation on $table affected $actual rows, expected $expected. '
      '${rolledBack ? 'The write was rolled back.' : 'The write is still part '
                'of the surrounding transaction; roll it back to undo it.'}';
}

/// Raised when a version-guarded update or delete matched no rows.
///
/// Zero rows under a rowversion guard means another writer changed the row
/// first, not that it is gone. Resolving the conflict is the application's job.
class MssqlConcurrencyException extends MssqlOrmException {
  const MssqlConcurrencyException({
    required this.table,
    required this.operation,
    this.key,
  });

  final String table;
  final String operation;
  final Object? key;

  @override
  String get message =>
      '$operation on $table${key == null ? '' : ' (key $key)'} matched no row '
      'with the expected version. The row was changed or deleted by someone '
      'else; re-read it and decide what to keep.';
}

/// Raised when a query asks for something the target server cannot do.
///
/// Naming the required version matters: emitting non-equivalent SQL for an
/// older server is worse than stopping.
class MssqlCapabilityException extends MssqlOrmException {
  const MssqlCapabilityException({
    required this.feature,
    required this.requires,
    this.found,
  });

  /// The function or query shape that is not available.
  final String feature;

  /// What it needs, in words a user can act on: 'SQL Server 2012 or newer'.
  final String requires;

  /// What was detected instead, when it is known.
  final String? found;

  @override
  String get message =>
      '$feature requires $requires'
      '${found == null ? '' : ', but the target reports $found'}.';
}

/// Raised when a relation getter is read on a row that never loaded it.
///
/// The alternative would be a silent lazy query per row, which this package
/// does not do.
class MssqlRelationNotLoadedException extends MssqlOrmException {
  const MssqlRelationNotLoadedException(this.table, this.relation);

  final String table;
  final String relation;

  @override
  String get message =>
      "relation '$relation' on $table was not loaded. Add it to include(), or "
      'call loadMissing() before reading it.';
}

/// Raised when two include() calls name the same path with different options.
///
/// Merging `lines.takePerParent(5)` with `lines.takePerParent(10)` would
/// silently pick one ceiling. The same for a filter, an order, a strategy or
/// a trash scope: the call site has to agree, or say so as two names.
class MssqlIncludeConflictException extends MssqlOrmException {
  const MssqlIncludeConflictException({
    required this.path,
    required this.reason,
  });

  /// Dot-separated relation names, starting at the root include.
  final String path;

  final String reason;

  @override
  String get message =>
      'include("$path") was specified more than once with $reason. Use one '
      'include for that path, or give the two sides the same filter, order, '
      'limit and strategy so they can be merged.';
}

/// Raised when a relation loaded fewer rows than exist.
///
/// A truncated relation must never be readable as an ordinary short list: that
/// turns a limit into silent data loss.
class MssqlRelationTruncatedException extends MssqlOrmException {
  const MssqlRelationTruncatedException({
    required this.table,
    required this.relation,
    required this.limit,
  });

  final String table;
  final String relation;
  final int limit;

  @override
  String get message =>
      "relation '$relation' on $table hit the $limit row load limit, so the "
      'loaded rows are not the whole set. Raise maxLoadedRows, or narrow the '
      'relation with where()/takePerParent().';
}

/// Raised when a write cannot report the row it stored.
///
/// A table with an `INSTEAD OF` trigger is the case: the statement the caller
/// wrote is never the one that runs, so `OUTPUT` describes rows the trigger may
/// have discarded or rewritten, and `SCOPE_IDENTITY()` belongs to whatever the
/// trigger inserted. Returning a plausible row would be wrong.
class MssqlReadbackUnavailableException extends MssqlOrmException {
  const MssqlReadbackUnavailableException({
    required this.table,
    required this.operation,
    required this.reason,
  });

  final String table;
  final String operation;

  /// Why no readback is possible, as a sentence fragment.
  final String reason;

  @override
  String get message =>
      '$operation on $table cannot report the stored row: $reason. Declare a '
      'readback strategy on the write to say which answer you want, or read '
      'the row back yourself with a query whose predicate you own.';
}

/// Raised when an update or delete would touch every row without the caller
/// having said so.
///
/// A configured scope does not count as a user predicate: scopes exist to
/// narrow reads, and treating one as intent to write the whole table is how a
/// tenant filter turns into a table-wide UPDATE.
class MssqlUnsafeWriteException extends MssqlOrmException {
  const MssqlUnsafeWriteException(this.table, this.operation);

  final String table;
  final String operation;

  @override
  String get message =>
      '$operation on $table has no predicate. Add a where(), or call '
      'allRows() to say you meant every row.';
}

/// Raised when generated code and the connection disagree about something the
/// generated code was compiled for.
///
/// Covers both the schema fingerprint and the API contract version.
class MssqlBindingMismatchException extends MssqlOrmException {
  const MssqlBindingMismatchException(this.message);

  @override
  final String message;
}

/// Raised when a cursor is applied to a different query than issued it.
///
/// Wrong ordering, a different tenant scope, or a token from another
/// package version would otherwise walk a keyset against the wrong rows.
class MssqlCursorMismatchException extends MssqlOrmException {
  const MssqlCursorMismatchException(this.reason);

  final String reason;

  @override
  String get message => 'cursor mismatch: $reason';
}

/// Raised when getOrCreate finds a soft-deleted row, or a unique collision
/// that is not the key it asked about.
///
/// The default is to stop: restoring a deleted row because the same key was
/// typed is a data decision, not an insert convenience. Pass `restoreExisting`
/// or `includeDeleted` to choose.
class MssqlUniqueConflictException extends MssqlOrmException {
  const MssqlUniqueConflictException({
    required this.table,
    required this.indexName,
    required this.reason,
  });

  final String table;
  final String indexName;
  final String reason;

  @override
  String get message => 'getOrCreate on $table unique "$indexName": $reason';
}

/// Raised when a generated mapper required a value and the row held SQL NULL.
///
/// `-- notnull` and a non-null column from describe both make this promise.
/// The crash names the `.sql` file and the column, because a generic
/// `Null check operator used on a null value` does not.
class MssqlUnexpectedNullException extends MssqlOrmException {
  const MssqlUnexpectedNullException({
    required this.source,
    required this.column,
  });

  /// The `.sql` file or table that declared the column non-null.
  final String source;

  final String column;

  @override
  String get message =>
      '$source column "$column" was declared non-null but the row held '
      'SQL NULL. Remove the -- notnull override if the column can be null, '
      'or fix the query.';
}

/// Unwraps [value] or throws [MssqlUnexpectedNullException].
///
/// Generated query mappers use this instead of `!` so the failure names
/// the file and column.
Object mssqlRequireNonNull(
  Object? value, {
  required String source,
  required String column,
}) {
  if (value == null) {
    throw MssqlUnexpectedNullException(source: source, column: column);
  }
  return value;
}

/// Raised when a mapped enum column held a SQL value the enum does not name.
class MssqlUnknownEnumValueException extends MssqlOrmException {
  const MssqlUnknownEnumValueException({
    required this.type,
    required this.value,
    required this.source,
  });

  final String type;
  final Object? value;
  final String source;

  @override
  String get message =>
      '$source: "$value" is not a member of $type. Add it to the enum, or '
      'set enum_columns unknown: member with unknown_member:.';
}

/// Raised when a procedure did not return an OUTPUT parameter the file named.
class MssqlMissingOutputException extends MssqlOrmException {
  const MssqlMissingOutputException({
    required this.procedure,
    required this.parameter,
  });

  final String procedure;
  final String parameter;

  @override
  String get message =>
      '$procedure did not return OUTPUT parameter "$parameter". '
      'Check the procedure still declares it.';
}

/// Raised when a procedure returned a different number of result sets
/// than the generated wrapper declared.
class MssqlUnexpectedResultSetException extends MssqlOrmException {
  const MssqlUnexpectedResultSetException({
    required this.procedure,
    required this.expected,
    required this.actual,
  });

  final String procedure;
  final int expected;
  final int actual;

  @override
  String get message =>
      '$procedure returned $actual result set(s); the generated wrapper '
      'declares $expected. Add `-- resultset:` columns for extra sets, or '
      '`-- extra_sets: ignore` if leftover sets are expected.';
}
