import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../expression.dart';
import '../operators.dart';
import '../query.dart';
import '../statement.dart';
import 'binding.dart';
import 'exception.dart';
import 'query_context.dart';
import 'query_state.dart';

/// A keyset bookmark for [MssqlEntityQuery.cursorPage].
///
/// Carries a format version, signatures of the ordering and of the filter
/// (scopes and predicates, with bound values), and the typed key values of
/// the last seen row. Those values are bound as parameters on the next
/// page; they are never spliced into SQL.
///
/// A keyset is not a snapshot. Ordering by a nullable or a mutable column
/// can skip or repeat rows when another session changes those values.
/// Put a unique, immutable key — the primary key — last in `orderBy`.
@immutable
class MssqlCursor {
  /// Format this package writes today. A newer package refuses an older
  /// token rather than guessing how to decode it.
  static const int formatVersion = 1;

  const MssqlCursor({
    required this.version,
    required this.orderSignature,
    required this.filterSignature,
    required this.keys,
  });

  final int version;
  final String orderSignature;
  final String filterSignature;

  /// Order-column values from the row this cursor sits on, in order-term
  /// order. Bound as parameters; never concatenated into SQL.
  final List<Object?> keys;
}

/// One keyset page, with cursors for the neighbouring pages.
@immutable
class MssqlCursorPage<TRow> {
  MssqlCursorPage({
    required List<TRow> rows,
    required this.hasMore,
    this.next,
    this.previous,
  }) : rows = List<TRow>.unmodifiable(rows);

  final List<TRow> rows;

  /// Pass to `cursorPage(after: next)` for the following page in user order.
  final MssqlCursor? next;

  /// Pass to `cursorPage(before: previous)` for the preceding page.
  final MssqlCursor? previous;

  /// More rows exist in the direction this call walked.
  final bool hasMore;

  bool get isEmpty => rows.isEmpty;
  bool get isNotEmpty => rows.isNotEmpty;
}

/// Keyset predicates, signatures and row decoding.
class MssqlKeyset {
  MssqlKeyset._();

  /// Column name of an order term, or null when it is not a column.
  static String? columnName(MssqlExpression expression) {
    var current = expression;
    if (current is MssqlAliased) current = current.expression;
    if (current is MssqlColumnBase) return current.name;
    return null;
  }

  /// Keyset needs named columns so the next page can read values from a row
  /// and bind them. An expression has no column in the result to look up.
  static void requireNamedColumns(List<MssqlOrder> orders, String feature) {
    if (orders.isEmpty) {
      throw StateError(
        '$feature needs orderBy() on named columns so the next page is a '
        'keyset, not OFFSET.',
      );
    }
    for (final order in orders) {
      if (columnName(order.expression) == null) {
        throw StateError(
          '$feature can only keyset on named columns, not on '
          '${order.expression}. Select the expression with as() and order '
          'by that name, or order by a table column.',
        );
      }
    }
  }

  /// Distinct/grouped projections must order by selected columns, never by
  /// a root PK that is not in the result.
  static void requireProjectedColumns(
    List<MssqlOrder> orders,
    Iterable<String> aliases,
    String projection,
  ) {
    requireNamedColumns(orders, 'page()');
    final folded = <String>{for (final alias in aliases) alias.toLowerCase()};
    for (final order in orders) {
      final name = columnName(order.expression)!;
      if (!folded.contains(name.toLowerCase())) {
        throw StateError(
          'Projection "$projection" cannot paginate by "$name": that '
          'column is not selected. Distinct and grouped results do not '
          'gain the root primary key; order by a projected column that '
          'uniquely identifies a result row.',
        );
      }
    }
  }

  static String orderSignature(List<MssqlOrder> orders, MssqlDialect dialect) {
    final alloc = MssqlParameterAllocator();
    return orders
        .map((order) {
          final sql = order.expression.compile(alloc, dialect);
          final dir = order.descending ? 'D' : 'A';
          final nulls = order.nulls?.name ?? '-';
          return '$sql:$dir:$nulls';
        })
        .join('|');
  }

  static String filterSignature({
    required MssqlTableBinding<Object?> binding,
    required MssqlQueryState state,
    required MssqlDialect dialect,
  }) {
    final alloc = MssqlParameterAllocator();
    final compiler = MssqlScopeCompiler(binding, state.scope);
    final parts = <String>[
      for (final condition in compiler.readConditions)
        condition.compile(alloc, dialect),
      for (final condition in state.where) condition.compile(alloc, dialect),
    ];
    return '${parts.join(' AND ')}#${_bound(alloc)}';
  }

  static String queryFilterSignature(MssqlQuery query, MssqlDialect dialect) {
    final alloc = MssqlParameterAllocator();
    final sql = query.conditions
        .map((c) => c.compile(alloc, dialect))
        .join(' AND ');
    return '$sql#${_bound(alloc)}';
  }

  static String _bound(MssqlParameterAllocator alloc) {
    return alloc.values.entries
        .map((e) => '${e.key}=${_canonical(e.value)}')
        .join(',');
  }

  static String _canonical(Object? value) {
    if (value == null) return 'null';
    if (value is DateTime) return value.toUtc().toIso8601String();
    return value.toString();
  }

  static void check(
    MssqlCursor cursor, {
    required String orderSignature,
    required String filterSignature,
    required int keyCount,
  }) {
    if (cursor.version != MssqlCursor.formatVersion) {
      throw MssqlCursorMismatchException(
        'this cursor is format ${cursor.version}; this package reads '
        'format ${MssqlCursor.formatVersion}.',
      );
    }
    if (cursor.orderSignature != orderSignature) {
      throw MssqlCursorMismatchException(
        'this cursor belongs to a different ordering. Rebuild the page '
        'from the first row, or pass the same orderBy as when the cursor '
        'was issued.',
      );
    }
    if (cursor.filterSignature != filterSignature) {
      throw MssqlCursorMismatchException(
        'this cursor belongs to a different filter, scope or tenant. It '
        'cannot be applied to this query.',
      );
    }
    if (cursor.keys.length != keyCount) {
      throw MssqlCursorMismatchException(
        'this cursor has ${cursor.keys.length} key(s); the ordering has '
        '$keyCount term(s).',
      );
    }
  }

  static MssqlCursor encode({
    required String orderSignature,
    required String filterSignature,
    required List<Object?> keys,
  }) => MssqlCursor(
    version: MssqlCursor.formatVersion,
    orderSignature: orderSignature,
    filterSignature: filterSignature,
    keys: List<Object?>.unmodifiable(keys),
  );

  static List<Object?> keysFromRow(MssqlRow row, List<MssqlOrder> orders) {
    requireNamedColumns(orders, 'cursor');
    return <Object?>[
      for (final order in orders) row[columnName(order.expression)!],
    ];
  }

  static List<Object?> keysFromColumns(
    Map<String, Object?> columns,
    List<MssqlOrder> orders,
  ) {
    requireNamedColumns(orders, 'cursor');
    return <Object?>[
      for (final order in orders)
        _lookup(columns, columnName(order.expression)!),
    ];
  }

  static List<MssqlOrder> reverseOrders(List<MssqlOrder> orders) =>
      <MssqlOrder>[
        for (final order in orders)
          MssqlOrder(
            order.expression,
            descending: !order.descending,
            nulls: switch (order.nulls) {
              null => null,
              MssqlNulls.first => MssqlNulls.last,
              MssqlNulls.last => MssqlNulls.first,
            },
          ),
      ];

  /// Lexicographic "strictly after [keys]" under [orders].
  ///
  /// SQL Server has no tuple inequality, so this is nested AND/OR:
  /// `(a > @a) OR (a = @a AND b > @b) OR …`. NULL uses `IS NULL` /
  /// `IS NOT NULL`; `col > NULL` would match nothing.
  static MssqlCondition after(List<MssqlOrder> orders, List<Object?> keys) {
    if (orders.length != keys.length) {
      throw ArgumentError.value(
        keys,
        'keys',
        'Need ${orders.length} value(s) for this ordering, got ${keys.length}.',
      );
    }
    final branches = <MssqlCondition>[];
    final prefix = <MssqlCondition>[];
    for (var i = 0; i < orders.length; i++) {
      final step = _strictlyAfter(orders[i], keys[i]);
      if (step != null) {
        branches.add(
          prefix.isEmpty ? step : and(<MssqlCondition>[...prefix, step]),
        );
      }
      prefix.add(_equal(orders[i].expression, keys[i]));
    }
    if (branches.isEmpty) {
      return MssqlComparison(const MssqlLiteral(1), '=', const MssqlLiteral(0));
    }
    if (branches.length == 1) return branches.single;
    return or(branches);
  }

  static MssqlCondition _equal(MssqlExpression expression, Object? value) =>
      value == null ? expression.isNull() : expression.eq(value);

  /// Null means no later row exists on this column alone (it is the last
  /// value in this direction).
  static MssqlCondition? _strictlyAfter(MssqlOrder order, Object? value) {
    final expression = order.expression;
    final nulls =
        order.nulls ?? (order.descending ? MssqlNulls.last : MssqlNulls.first);
    if (order.descending) {
      if (nulls == MssqlNulls.last) {
        if (value == null) return null;
        return expression.lt(value) | expression.isNull();
      }
      if (value == null) return expression.isNotNull();
      return expression.lt(value);
    }
    if (nulls == MssqlNulls.first) {
      if (value == null) return expression.isNotNull();
      return expression.gt(value);
    }
    if (value == null) return null;
    return expression.gt(value) | expression.isNull();
  }

  static Object? _lookup(Map<String, Object?> columns, String name) {
    if (columns.containsKey(name)) return columns[name];
    final lower = name.toLowerCase();
    for (final entry in columns.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }
}
