part of '../query.dart';

/// A page for a target with no `OFFSET … FETCH`: SQL Server 2008, or any
/// server whose database sits at compatibility level 100.
///
/// Three levels, because a page is three separate things in an order one
/// `SELECT` cannot express:
///
/// 1. **the result** — the query as written, `DISTINCT` and `GROUP BY`
///    included, producing the rows the caller asked for and nothing else;
/// 2. **the numbering** — `ROW_NUMBER()` over that result, ordered by its
///    output columns;
/// 3. **the page** — the slice of numbered rows, with the number dropped
///    again.
///
/// Collapsing these into one `SELECT` breaks twice: `ROW_NUMBER()` beside
/// `DISTINCT` gives every row a different number, so nothing is duplicate any
/// more; and a window function is evaluated before the projection aliases of
/// its own `SELECT` exist, so ordering a page by an alias that `SELECT`
/// introduces is rejected by the server.
class _MssqlRowNumberPaging {
  _MssqlRowNumberPaging(this.query, this.dialect, {required this.nested});

  final MssqlQuery query;
  final MssqlDialect dialect;

  /// Whether the page is itself being written inside another statement.
  ///
  /// It decides one thing: whether the last level may keep its `ORDER BY`. On
  /// 2012 a nested page carries `OFFSET … FETCH`, which is what makes an
  /// `ORDER BY` legal inside a derived table. The three-level form has no such
  /// clause at its outermost level — the slice is chosen by a `WHERE` on the
  /// row number — so an `ORDER BY` there is one SQL Server rejects. Dropping
  /// it costs nothing that SQL promises anyway: no query may rely on the row
  /// order of a derived table, only on its own.
  final bool nested;

  /// The derived tables' own aliases. Table aliases are scoped to the
  /// statement level that introduces them, so unlike the added columns these
  /// cannot collide with anything the caller wrote.
  static final String _resultAlias = MssqlSql.quoteIdentifier(
    'mssql_orm_result',
  );
  static final String _numberedAlias = MssqlSql.quoteIdentifier(
    'mssql_orm_page',
  );

  String compile(MssqlParameterAllocator parameters) {
    final shape = _MssqlResultShape.of(query);
    if (!shape.isNameable) {
      throw MssqlCapabilityException(
        feature: 'paged() on this query',
        requires:
            'SQL Server 2012 or newer, or a database at compatibility level '
            '110 or higher, where OFFSET … FETCH pages the query as written. '
            'Older targets need a ROW_NUMBER() column written out and then '
            'dropped again, which requires every result column to have a '
            'distinct name, and here ${shape.problem}',
        found: dialect.description,
      );
    }
    final names = shape.names!;
    final folded = names.map((name) => name.toLowerCase()).toSet();

    // Ordering terms the result already carries are referred to by name;
    // anything else is added to the result as a column of its own and dropped
    // at the last level.
    final helpers = <String, MssqlExpression>{};
    final terms = <String>[];
    for (final order in query.ordering) {
      final name = _MssqlResultShape.nameOf(order.expression);
      if (name != null && folded.contains(name.toLowerCase())) {
        terms.add(
          _orderByFragment(
            '$_resultAlias.${MssqlSql.quoteIdentifier(name)}',
            order,
          ),
        );
        continue;
      }
      if (query.distinct || query.grouping.isNotEmpty) {
        throw MssqlCapabilityException(
          feature:
              'paged() ordered by an expression this query does not select',
          requires:
              'SQL Server 2012 or newer, or a database at compatibility level '
              '110 or higher. Older targets number the rows of the collapsed '
              'result, and a DISTINCT or GROUP BY query has no row left to '
              'read that expression from — adding it to the result would '
              'change which rows the result has. Select the expression with '
              'as() and order by that name instead',
          found: dialect.description,
        );
      }
      final alias = shape.alias('mssql_orm_order_${helpers.length}');
      helpers[alias] = order.expression;
      terms.add(
        _orderByFragment(
          '$_resultAlias.${MssqlSql.quoteIdentifier(alias)}',
          order,
        ),
      );
    }

    final rowAlias = MssqlSql.quoteIdentifier(shape.alias('mssql_orm_row'));
    final result = MssqlQuery._(
      source: query.source,
      joins: query.joins,
      projection: <MssqlExpression>[
        ...query.projection,
        for (final helper in helpers.entries)
          MssqlAliased(helper.value, helper.key),
      ],
      conditions: query.conditions,
      grouping: query.grouping,
      having: query.having,
      // The ordering has moved out to the window, and the page below picks
      // the slice, so this level carries neither.
      ordering: const <MssqlOrder>[],
      distinct: query.distinct,
      offset: null,
      rows: null,
      topRows: null,
      lockHint: query.lockHint,
      // The WITH clause and MAXRECURSION belong to the statement, which is
      // written by the caller of this compiler.
      ctes: const <MssqlCte>[],
      maxRecursion: null,
    );

    final columns = names.map(MssqlSql.quoteIdentifier).toList(growable: false);
    final numbered =
        'SELECT ${columns.map((c) => '$_resultAlias.$c').join(', ')}, '
        'ROW_NUMBER() OVER (ORDER BY ${terms.join(', ')}) AS $rowAlias '
        'FROM '
        '(${_MssqlSelectCompiler(result, dialect, nested: true).compile(parameters)})'
        ' AS $_resultAlias';

    final first = parameters.bind(query.offset! + 1);
    final last = parameters.bind(query.offset! + query.rows!);
    final page =
        'SELECT ${columns.map((c) => '$_numberedAlias.$c').join(', ')} '
        'FROM ($numbered) AS $_numberedAlias '
        'WHERE $_numberedAlias.$rowAlias BETWEEN $first AND $last';
    return nested ? page : '$page ORDER BY $_numberedAlias.$rowAlias';
  }
}
