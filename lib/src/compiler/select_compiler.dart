part of '../query.dart';

/// The names one query's own result columns are known by.
///
/// Any compiler that reads a query through another one has to write its
/// columns out by name. `SELECT *` around a `ROW_NUMBER()` hands the caller
/// the row number as though it were data, and a derived table cannot have two
/// columns called the same thing. So the shape is resolved once, before any
/// SQL is written, and a projection whose shape cannot be determined is
/// refused rather than compiled into SQL that answers a different question.
class _MssqlResultShape {
  factory _MssqlResultShape.of(MssqlQuery query) {
    if (query.projection.isEmpty) {
      return const _MssqlResultShape._(names: null, wildcard: true);
    }
    final names = <String>[];
    final seen = <String, String>{};
    String? duplicate;
    for (final expression in query.projection) {
      final name = nameOf(expression);
      if (name == null) {
        return _MssqlResultShape._(
          names: null,
          wildcard: false,
          unnamed: expression,
        );
      }
      final folded = name.toLowerCase();
      duplicate ??= seen[folded];
      seen[folded] = name;
      names.add(name);
    }
    return _MssqlResultShape._(
      names: List<String>.unmodifiable(names),
      wildcard: false,
      duplicate: duplicate,
    );
  }

  const _MssqlResultShape._({
    required this.names,
    required this.wildcard,
    this.unnamed,
    this.duplicate,
  });

  /// Every result column's name, in projection order, or null when at least
  /// one of them has none.
  final List<String>? names;

  /// Whether the projection is `*`, which names nothing at all.
  final bool wildcard;

  /// The first projected expression with no name, when there is one.
  final MssqlExpression? unnamed;

  /// The first name that appears twice, ignoring case.
  ///
  /// Case-insensitively, because SQL Server's usual collations are, so
  /// `Total` and `total` are one name to the server and two to a Dart list.
  final String? duplicate;

  /// Whether a wrapping query can write these columns out by name.
  bool get isNameable => names != null && duplicate == null;

  /// Why it cannot, as a sentence fragment naming what to change.
  String get problem {
    if (wildcard) {
      return 'the projection is *, so the compiler cannot tell one result '
          'column from another — call select() and name them';
    }
    final unnamedExpression = unnamed;
    if (unnamedExpression != null) {
      return 'the projected expression $unnamedExpression has no result name, '
          'so nothing can refer to it — give it one with as()';
    }
    return 'two result columns are both called "$duplicate" — give one of '
        'them a different name with as()';
  }

  /// An alias no result column of this query is already called.
  ///
  /// The wrapping compilers add columns of their own — a row number, an
  /// ordering term the projection does not carry — and then drop them again
  /// before the caller sees the result. Colliding with a real column would
  /// make the query ambiguous rather than merely ugly, so [base] is extended
  /// until it is free.
  String alias(String base) {
    final taken = (names ?? const <String>[])
        .map((name) => name.toLowerCase())
        .toSet();
    if (!taken.contains(base.toLowerCase())) return base;
    for (var suffix = 2; ; suffix++) {
      final candidate = '${base}_$suffix';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  /// The result name of one projected expression, or null when it has none.
  ///
  /// A column carries its own name and an aliased expression its alias.
  /// Everything else — a function, an arithmetic node, a bound literal, a raw
  /// fragment — is unnamed: SQL Server calls that column `(No column name)`,
  /// which is not something another query can refer to.
  static String? nameOf(MssqlExpression expression) => switch (expression) {
    MssqlAliased(:final alias) => alias,
    MssqlColumnBase(:final name) => name,
    _ => null,
  };
}

/// Compiles one `SELECT`, and owns every rule about how its clauses interact.
///
/// The rules live in one pass rather than beside the clause each of them
/// concerns. `top()` with `paged()`, an `ORDER BY` inside a derived table, a
/// `WITH` clause on a subquery and `OPTION (MAXRECURSION …)` anywhere but the
/// end of a statement are all the same kind of mistake — a clause written at
/// the wrong SQL level — and checking them together is what stops a later
/// paging shape from quietly satisfying one rule while breaking another.
class _MssqlSelectCompiler {
  _MssqlSelectCompiler(this.query, this.dialect, {required this.nested});

  final MssqlQuery query;
  final MssqlDialect dialect;

  /// Whether this `SELECT` is being written inside another statement: a
  /// derived table, a scalar subquery, a `WITH` member or a union member.
  final bool nested;

  String compile(MssqlParameterAllocator parameters) {
    _validate();

    // The WITH clause is compiled first because it is written first, and the
    // allocator numbers parameters in the order it is asked.
    final prefix = query.ctes.isEmpty
        ? ''
        : 'WITH '
              '${query.ctes.map((c) => c.compile(parameters, dialect)).join(', ')} ';

    final body = _usesRowNumberPaging
        ? _MssqlRowNumberPaging(
            query,
            dialect,
            nested: nested,
          ).compile(parameters)
        : _direct(parameters);

    // MAXRECURSION is a hint on the whole statement, so it goes last — after
    // the ORDER BY and after any paging.
    final suffix = query.maxRecursion == null
        ? ''
        : ' OPTION (MAXRECURSION ${query.maxRecursion})';
    return '$prefix$body$suffix';
  }

  /// Whether the page has to be built from a `ROW_NUMBER()` column.
  ///
  /// Asked of the capability descriptor rather than of a version name: SQL
  /// Server gates `OFFSET … FETCH` on the database's compatibility level too,
  /// so a modern server hosting a database left at level 100 needs the same
  /// three-level form a 2008 server does.
  bool get _usesRowNumberPaging =>
      query.offset != null && !dialect.supportsOffsetFetch;

  void _validate() {
    final source = query.source.quoted;
    if (query.topRows != null && query.offset != null) {
      throw StateError(
        'top() and paged() both limit the same query. Use paged() for a page '
        'and top() for a first slice, not both. Source: $source.',
      );
    }
    if (query.offset != null && query.ordering.isEmpty) {
      throw StateError(
        'paged() needs orderBy(): SQL Server rejects OFFSET without ORDER BY, '
        'and an unordered page is not repeatable. Source: $source.',
      );
    }
    if (!nested) return;
    if (query.ordering.isNotEmpty &&
        query.topRows == null &&
        query.offset == null) {
      throw StateError(
        'A nested query may only order rows when it also uses top() or '
        'paged(). Source: $source.',
      );
    }
    if (query.ctes.isNotEmpty) {
      throw StateError(
        'A WITH clause belongs to the statement, not to a subquery: SQL Server '
        'rejects one inside a derived table. Move withCte() to the outermost '
        'query, where it is still visible to every subquery inside it. '
        'Source: $source.',
      );
    }
    if (query.maxRecursion != null) {
      throw StateError(
        'OPTION (MAXRECURSION n) is a hint on the whole statement and SQL '
        'Server accepts it only at the very end of one, so a subquery or a '
        'union member cannot carry its own. Pass maxRecursion where the '
        'outermost query names its expression. Source: $source.',
      );
    }
  }

  String _direct(MssqlParameterAllocator parameters) {
    final out = StringBuffer('SELECT ');
    if (query.distinct) out.write('DISTINCT ');
    if (query.topRows != null) {
      out.write('TOP (${parameters.bind(query.topRows)}) ');
    }
    out.write(_projection(parameters));
    out.write(' ${_from(parameters)}');
    out.write(_tail(parameters));
    if (query.ordering.isNotEmpty) {
      out.write(' ORDER BY ${orderTerms(parameters)}');
    }
    if (query.offset != null) {
      out.write(
        ' OFFSET ${parameters.bind(query.offset)} ROWS '
        'FETCH NEXT ${parameters.bind(query.rows)} ROWS ONLY',
      );
    }
    return out.toString();
  }

  String _projection(MssqlParameterAllocator parameters) {
    if (query.projection.isEmpty) return '*';
    return query.projection
        .map((e) => e.compile(parameters, dialect))
        .join(', ');
  }

  String _from(MssqlParameterAllocator parameters) {
    final out = StringBuffer(
      'FROM ${query.source.compile(parameters, dialect)}',
    );
    if (query.lockHint != null) {
      parameters.markRaw();
      out.write(' WITH (${query.lockHint})');
    }
    for (final join in query.joins) {
      out.write(
        ' ${join.kind.sql} ${join.source.compile(parameters, dialect)}',
      );
      final on = join.on;
      if (on != null) out.write(' ON ${on.compile(parameters, dialect)}');
    }
    return out.toString();
  }

  String _tail(MssqlParameterAllocator parameters) {
    final out = StringBuffer();
    if (query.conditions.isNotEmpty) {
      out.write(' WHERE ${and(query.conditions).compile(parameters, dialect)}');
    }
    if (query.grouping.isNotEmpty) {
      final terms = query.grouping.map((e) => e.compile(parameters, dialect));
      out.write(' GROUP BY ${terms.join(', ')}');
    }
    final having = query.having;
    if (having != null) {
      out.write(' HAVING ${having.compile(parameters, dialect)}');
    }
    return out.toString();
  }

  /// The `ORDER BY` terms of this query, compiled in place.
  ///
  /// Shared with [MssqlSetQuery], whose outer ordering is written the same
  /// way; the three-level paging form does *not* use it, because its ordering
  /// has to refer to the inner query's output names instead.
  static String orderList(
    Iterable<MssqlOrder> ordering,
    MssqlParameterAllocator parameters,
    MssqlDialect dialect,
  ) => ordering
      .map(
        (o) => _orderByFragment(o.expression.compile(parameters, dialect), o),
      )
      .join(', ');

  String orderTerms(MssqlParameterAllocator parameters) =>
      orderList(query.ordering, parameters, dialect);
}

/// One `ORDER BY` item. [expressionSql] is compiled once so a parameter is
/// not bound twice when NULLS FIRST/LAST wraps the same term in `CASE`.
String _orderByFragment(String expressionSql, MssqlOrder order) {
  final direction = order.descending ? ' DESC' : ' ASC';
  final nulls = order.nulls;
  if (nulls == null) return '$expressionSql$direction';
  final nullRank = nulls == MssqlNulls.first ? '0' : '1';
  final valueRank = nulls == MssqlNulls.first ? '1' : '0';
  return 'CASE WHEN $expressionSql IS NULL THEN $nullRank ELSE $valueRank '
      'END ASC, $expressionSql$direction';
}
