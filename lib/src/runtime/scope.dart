import 'package:meta/meta.dart';

import '../expression.dart';
import '../operators.dart';

/// Whether a soft-deleting repository sees deleted rows.
enum MssqlTrashed {
  /// The default: deleted rows are hidden.
  without,

  /// Deleted rows alongside the rest.
  with_,

  /// Only the deleted ones.
  only,
}

/// A predicate applied to every read of a table, unless it is switched off.
///
/// Eloquent calls this a global scope. Soft deletes are the case that makes it
/// worth having: hiding deleted rows must happen on every query, and leaving
/// it to each call site means one query will forget it.
@immutable
class MssqlScope {
  const MssqlScope(this.name, this.build);

  /// How the scope is switched off: `without(name)`.
  final String name;

  /// The predicate. Null means "add nothing" — useful for a scope whose
  /// condition depends on state that may be absent.
  final MssqlCondition? Function() build;
}

/// How a table records a soft delete.
///
/// A soft delete is not a SQL Server feature; it is a convention about a
/// column, so it takes declaring.
@immutable
class MssqlSoftDelete {
  const MssqlSoftDelete({
    required this.column,
    this.aliveValue,
    this.deletedValue,
  });

  /// The column that is null while the row is live.
  final String column;

  /// What identifies a live row.
  ///
  /// Null uses the usual nullable timestamp convention. A flag column can use
  /// `aliveValue: false, deletedValue: true` instead.
  final Object? aliveValue;

  /// What to write when deleting.
  ///
  /// Null means "the server's own timestamp", which is what a `datetime2`
  /// column wants and what keeps the clock on one machine. A `bit` column
  /// would pass `true` instead.
  final Object? deletedValue;

  /// Rows still alive.
  MssqlCondition get alive =>
      aliveValue == null ? Col(column).isNull() : Col(column).eq(aliveValue);

  /// Rows deleted.
  MssqlCondition get deleted {
    if (aliveValue == null) return Col(column).isNotNull();
    final value = deletedValue;
    return value == null ? Col(column).ne(aliveValue) : Col(column).eq(value);
  }

  MssqlCondition? conditionFor(MssqlTrashed trashed) => switch (trashed) {
    MssqlTrashed.without => alive,
    MssqlTrashed.only => deleted,
    MssqlTrashed.with_ => null,
  };
}

/// Which columns carry the created and updated stamps.
///
/// Eloquent maintains `created_at` and `updated_at` for every model; the
/// column names differ from project to project, so they are named here rather
/// than assumed.
@immutable
class MssqlTimestamps {
  const MssqlTimestamps({this.createdColumn, this.updatedColumn});

  final String? createdColumn;
  final String? updatedColumn;

  bool get isEmpty => createdColumn == null && updatedColumn == null;
}

/// Immutable snapshot of which scopes a query carries.
///
/// The soft-delete filter and the named global scopes follow the query through
/// every terminal — `get`, `page`, `count`, `exists`, `write` — because they
/// all read this selection rather than a mutable field on the repository.
///
/// [withoutScope] and [withoutGlobalScopes] remove named scopes but never touch
/// the soft-delete switch: "show me everything" and "show me deleted rows too"
/// are different intentions.
@immutable
class MssqlScopeSelection {
  MssqlScopeSelection({
    this.trashed = MssqlTrashed.without,
    Set<String> withoutScopes = const <String>{},
  }) : withoutScopes = Set<String>.unmodifiable(withoutScopes);

  const MssqlScopeSelection.empty()
    : trashed = MssqlTrashed.without,
      withoutScopes = const <String>{};

  /// Which soft-deleted rows this selection sees.
  final MssqlTrashed trashed;

  /// Names of global scopes switched off.
  final Set<String> withoutScopes;

  /// Whether [name] is switched off.
  bool isOff(String name) =>
      withoutScopes.any((n) => n.toLowerCase() == name.toLowerCase());

  /// Include soft-deleted rows.
  MssqlScopeSelection withTrashed() => MssqlScopeSelection(
    trashed: MssqlTrashed.with_,
    withoutScopes: withoutScopes,
  );

  /// Only soft-deleted rows.
  MssqlScopeSelection onlyTrashed() => MssqlScopeSelection(
    trashed: MssqlTrashed.only,
    withoutScopes: withoutScopes,
  );

  /// Back to the default: deleted rows hidden.
  MssqlScopeSelection withoutTrashed() => MssqlScopeSelection(
    trashed: MssqlTrashed.without,
    withoutScopes: withoutScopes,
  );

  /// Switches one named global scope off.
  MssqlScopeSelection withoutScope(String name) {
    if (isOff(name)) return this;
    return MssqlScopeSelection(
      trashed: trashed,
      withoutScopes: Set<String>.unmodifiable(<String>{...withoutScopes, name}),
    );
  }

  /// Switches every named global scope off.
  ///
  /// Soft deletes have their own switch and are not affected.
  MssqlScopeSelection withoutGlobalScopes(List<MssqlScope> all) {
    var out = this;
    for (final scope in all) {
      out = out.withoutScope(scope.name);
    }
    return out;
  }

  /// Whether this selection still applies the soft-delete filter.
  bool get hidesTrashed => trashed == MssqlTrashed.without;

  /// Whether this selection sees only soft-deleted rows.
  bool get onlyTrashedRows => trashed == MssqlTrashed.only;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MssqlScopeSelection &&
          trashed == other.trashed &&
          _sameScopes(withoutScopes, other.withoutScopes);

  @override
  int get hashCode => Object.hash(trashed, Object.hashAll(withoutScopes));

  static bool _sameScopes(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    final lowers = <String>{};
    for (final name in b) {
      lowers.add(name.toLowerCase());
    }
    for (final name in a) {
      if (!lowers.contains(name.toLowerCase())) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'MssqlScopeSelection(trashed: ${trashed.name}, off: ${withoutScopes.join(', ')})';
}
