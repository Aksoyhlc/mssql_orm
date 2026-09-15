import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../cte.dart';
import '../expression.dart';
import '../operators.dart';
import 'scope.dart';

/// Immutable snapshot of every selection a query carries: scope state, user
/// predicates, ordering, and native execution options.
///
/// Every method that narrows a query — `where`, `orderBy`, `withTrashed`,
/// `withoutScope`, `.options(...)` — returns a new [MssqlQueryState] rather
/// than mutating this one. Two chains derived from the same base cannot
/// drift into each other, because neither holds a reference to mutable state
/// the other can change.
///
/// The scope part ([scope]) is an [MssqlScopeSelection] of its own so it can
/// be queried and copied independently — a relation loader, for instance,
/// applies the parent's scope selection to a child query without carrying the
/// parent's `where` or `orderBy` along.
@immutable
class MssqlQueryState {
  MssqlQueryState({
    this.scope = const MssqlScopeSelection.empty(),
    List<MssqlCondition> where = const <MssqlCondition>[],
    List<MssqlOrder> orderBy = const <MssqlOrder>[],
    this.options = const MssqlQueryOptions(),
    List<MssqlTypedCte> ctes = const <MssqlTypedCte>[],
  }) : where = List<MssqlCondition>.unmodifiable(where),
       orderBy = List<MssqlOrder>.unmodifiable(orderBy),
       ctes = List<MssqlTypedCte>.unmodifiable(ctes);

  const MssqlQueryState.empty()
    : scope = const MssqlScopeSelection.empty(),
      where = const <MssqlCondition>[],
      orderBy = const <MssqlOrder>[],
      options = const MssqlQueryOptions(),
      ctes = const <MssqlTypedCte>[];

  /// Which scopes this query carries.
  final MssqlScopeSelection scope;

  /// User-supplied predicates, ANDed together.
  final List<MssqlCondition> where;

  /// User-supplied ordering.
  final List<MssqlOrder> orderBy;

  /// Native execution options, or defaults.
  final MssqlQueryOptions options;

  /// Common table expressions this query's statement has to declare.
  ///
  /// SQL Server allows `WITH` only at the start of a statement, so a
  /// recursive walk cannot be nested inside `IN (…)`. Carrying the
  /// expression on the state instead lets a generated `descendantsOf`
  /// filter by the walk's keys and still be an ordinary query — with its
  /// scopes, ordering, includes and paging all applied by the same code as
  /// every other query — because the terminal that builds the statement is
  /// the one that puts the `WITH` in front of it.
  ///
  /// Each expression carries its own `MAXRECURSION` ceiling.
  final List<MssqlTypedCte> ctes;

  /// A copy with [scope] replaced.
  MssqlQueryState withScope(MssqlScopeSelection scope) => MssqlQueryState(
    scope: scope,
    where: where,
    orderBy: orderBy,
    options: options,
    ctes: ctes,
  );

  /// A copy with [condition] appended to [where].
  MssqlQueryState where_(MssqlCondition condition) => MssqlQueryState(
    scope: scope,
    where: <MssqlCondition>[...where, condition],
    orderBy: orderBy,
    options: options,
    ctes: ctes,
  );

  /// A copy with [extra] appended to [orderBy].
  MssqlQueryState thenBy(List<MssqlOrder> extra) =>
      withOrderBy(<MssqlOrder>[...orderBy, ...extra]);

  /// A copy with [ordering] replacing [orderBy].
  MssqlQueryState withOrderBy(List<MssqlOrder> ordering) => MssqlQueryState(
    scope: scope,
    where: where,
    orderBy: List<MssqlOrder>.unmodifiable(ordering),
    options: options,
    ctes: ctes,
  );

  /// A copy with [options] replaced.
  MssqlQueryState withOptions(MssqlQueryOptions options) => MssqlQueryState(
    scope: scope,
    where: where,
    orderBy: orderBy,
    options: options,
    ctes: ctes,
  );

  /// A copy with [cte] appended to [ctes].
  ///
  /// Two expressions with the same name are refused where the statement is
  /// built, not here: the same walk added twice by two chained scopes is a
  /// mistake worth naming, and the compiler is where the name is in scope.
  MssqlQueryState withCte(MssqlTypedCte cte) => MssqlQueryState(
    scope: scope,
    where: where,
    orderBy: orderBy,
    options: options,
    ctes: <MssqlTypedCte>[...ctes, cte],
  );

  // Scope shortcuts

  MssqlQueryState withTrashed() => withScope(scope.withTrashed());
  MssqlQueryState onlyTrashed() => withScope(scope.onlyTrashed());
  MssqlQueryState withoutTrashed() => withScope(scope.withoutTrashed());
  MssqlQueryState withoutScope(String name) =>
      withScope(scope.withoutScope(name));

  MssqlQueryState withoutGlobalScopes(List<MssqlScope> all) =>
      withScope(scope.withoutGlobalScopes(all));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MssqlQueryState &&
          scope == other.scope &&
          _sameList(where, other.where) &&
          _sameList(orderBy, other.orderBy) &&
          options == other.options &&
          _sameList(ctes, other.ctes);

  @override
  int get hashCode => Object.hash(
    scope,
    Object.hashAll(where),
    Object.hashAll(orderBy),
    options,
    Object.hashAll(ctes),
  );

  static bool _sameList<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'MssqlQueryState(scope: $scope, where: ${where.length}, orderBy: ${orderBy.length})';
}
