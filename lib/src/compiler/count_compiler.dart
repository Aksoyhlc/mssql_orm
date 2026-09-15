part of '../query.dart';

/// How a count or an aggregate is written over a query that already has a
/// shape of its own.
///
/// The mistake this replaces was to treat a count as the same query with the
/// projection swapped. That works for exactly one shape — a flat
/// `SELECT … FROM … WHERE …` — and silently answers a different question for
/// every other:
///
/// - `SELECT DISTINCT` counted in place counts *source* rows, because
///   `COUNT_BIG(*)` is one row and one row is trivially distinct;
/// - `GROUP BY` counted in place returns one count per group, and a caller
///   reading the first row gets the size of the first group;
/// - `HAVING` without `GROUP BY` is one group over the whole set, so the same
///   thing happens with a set of one;
/// - a page or a `TOP` counted in place ignores the limit entirely.
///
/// So a query whose shape collapses rows is counted through a derived table
/// that keeps that shape, and the `WITH` clause stays outside it, where SQL
/// Server requires it to be.
extension _MssqlCountCompiler on MssqlQuery {
  /// Whether this query's shape collapses rows, so that reprojecting it in
  /// place would count something else.
  bool get _collapsesRows =>
      distinct ||
      grouping.isNotEmpty ||
      having != null ||
      offset != null ||
      topRows != null;

  /// The clause responsible, for an error that names it.
  String get _collapsingClause {
    if (distinct) return 'DISTINCT';
    if (grouping.isNotEmpty) return 'GROUP BY';
    if (having != null) return 'HAVING';
    if (offset != null) return 'paged()';
    return 'top()';
  }

  MssqlQuery _aggregateOverResult(MssqlExpression aggregate, String operation) {
    if (!_collapsesRows) {
      return MssqlQuery._(
        source: source,
        joins: joins,
        projection: <MssqlExpression>[aggregate],
        conditions: conditions,
        grouping: const <MssqlExpression>[],
        having: null,
        // An aggregate over the whole set is one row; ordering it is both
        // meaningless and, without a GROUP BY, rejected by the server.
        ordering: const <MssqlOrder>[],
        distinct: false,
        offset: null,
        rows: null,
        topRows: null,
        lockHint: lockHint,
        // An aggregate over a query built on a WITH clause still needs it.
        ctes: ctes,
        maxRecursion: maxRecursion,
      );
    }
    final shape = _MssqlResultShape.of(this);
    if (shape.duplicate != null) {
      throw StateError(
        '$operation reads this query as a derived table, because its '
        '$_collapsingClause decides which rows the result has. SQL Server '
        'rejects a derived table with two columns called '
        '"${shape.duplicate}"; give one of them a different name with as().',
      );
    }
    return _wrapping(
      projection: projection,
      distinctInner: distinct,
      outer: <MssqlExpression>[aggregate],
    );
  }

  MssqlQuery _countDistinct(Iterable<MssqlExpression> expressions) {
    final keys = List<MssqlExpression>.unmodifiable(expressions);
    if (keys.isEmpty) {
      throw ArgumentError.value(
        expressions,
        'expressions',
        'countDistinct() needs at least one expression. To count the rows '
            'this query returns, call countRows().',
      );
    }
    if (_collapsesRows) {
      throw StateError(
        'countDistinct() counts distinct values among the rows this query '
        'matches, and this query already collapses rows with '
        '$_collapsingClause. "How many distinct customers appear in one page '
        'of distinct orders" is two questions, and picking one of them here '
        'would be a guess. Ask this on the query before the '
        '$_collapsingClause, or call countRows() to count the rows this '
        'query returns.',
      );
    }
    if (keys.length == 1) {
      return MssqlQuery._(
        source: source,
        joins: joins,
        projection: <MssqlExpression>[MssqlDistinctCount(keys.single)],
        conditions: conditions,
        grouping: const <MssqlExpression>[],
        having: null,
        ordering: const <MssqlOrder>[],
        distinct: false,
        offset: null,
        rows: null,
        topRows: null,
        lockHint: lockHint,
        ctes: ctes,
        maxRecursion: maxRecursion,
      );
    }
    // SQL Server's COUNT(DISTINCT …) takes exactly one argument, so a
    // composite key is counted by distinguishing the keys first and counting
    // what is left. The columns are aliased because the key expressions need
    // not be columns, and a derived table has to be able to name each of its
    // own.
    return _wrapping(
      projection: <MssqlExpression>[
        for (var index = 0; index < keys.length; index++)
          MssqlAliased(keys[index], 'mssql_orm_key_$index'),
      ],
      distinctInner: true,
      outer: <MssqlExpression>[countAll(big: true)],
    );
  }

  /// This query as a derived table, with [outer] selected over it.
  MssqlQuery _wrapping({
    required List<MssqlExpression> projection,
    required bool distinctInner,
    required List<MssqlExpression> outer,
  }) {
    // A page and a TOP are defined by their ordering, so that stays inside.
    // Anywhere else an ORDER BY in a derived table is both pointless and, on
    // its own, rejected.
    final keepsOrdering = offset != null || topRows != null;
    final inner = MssqlQuery._(
      source: source,
      joins: joins,
      projection: projection,
      conditions: conditions,
      grouping: grouping,
      having: having,
      ordering: keepsOrdering ? ordering : const <MssqlOrder>[],
      distinct: distinctInner,
      offset: offset,
      rows: rows,
      topRows: topRows,
      lockHint: lockHint,
      ctes: const <MssqlCte>[],
      maxRecursion: null,
    );
    return MssqlQuery._(
      source: MssqlSource.subquery(inner, as: 'mssql_orm_result'),
      joins: const <MssqlJoin>[],
      projection: outer,
      conditions: const <MssqlCondition>[],
      grouping: const <MssqlExpression>[],
      having: null,
      ordering: const <MssqlOrder>[],
      distinct: false,
      offset: null,
      rows: null,
      topRows: null,
      lockHint: null,
      // The WITH clause is a property of the statement: SQL Server rejects one
      // inside a derived table, so it is lifted to the query that wraps it.
      ctes: ctes,
      maxRecursion: maxRecursion,
    );
  }
}
