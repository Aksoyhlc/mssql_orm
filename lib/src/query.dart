import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'dialect.dart';
import 'expression.dart';
import 'operators.dart';
import 'runtime/exception.dart';
import 'source_ref.dart';
import 'statement.dart';

part 'compiler/count_compiler.dart';
part 'compiler/paging_compiler.dart';
part 'compiler/select_compiler.dart';

/// The join kinds SQL Server supports.
enum MssqlJoinKind {
  inner('INNER JOIN'),
  left('LEFT JOIN'),
  right('RIGHT JOIN'),
  full('FULL JOIN'),
  cross('CROSS JOIN');

  const MssqlJoinKind(this.sql);
  final String sql;
}

@immutable
class MssqlJoin {
  const MssqlJoin(this.kind, this.source, this.on);

  final MssqlJoinKind kind;
  final MssqlSource source;
  final MssqlCondition? on;
}

/// A table or view, optionally aliased.
@immutable
class MssqlSource {
  MssqlSource(String identifier, {this.alias, this.ref})
    : quoted = MssqlMultipartIdentifier.parse(
        identifier,
        maximumParts: 4,
      ).quoted,
      query = null {
    if (alias != null) MssqlSql.quoteIdentifier(alias!);
  }

  /// A source whose parts are already separated.
  ///
  /// [MssqlSource.new] parses a dotted string, which cannot represent a table
  /// whose own name carries a dot or a space: `dbo.Order Lines` is not a legal
  /// unquoted identifier, so re-parsing it would reject a table that exists.
  /// Anything already holding the parts — a binding above all — comes through
  /// here instead.
  MssqlSource.parts(List<String> parts, {this.alias, this.ref})
    : quoted = MssqlSql.quoteMultipartIdentifier(parts),
      query = null {
    if (alias != null) MssqlSql.quoteIdentifier(alias!);
  }

  factory MssqlSource.subquery(MssqlSelectQuery query, {required String as}) =>
      MssqlSource._subquery(query, as: as);

  MssqlSource._subquery(this.query, {required String as})
    : alias = as,
      quoted = MssqlSql.quoteIdentifier(as),
      ref = MssqlSourceRef.named(as);

  final String quoted;
  final String? alias;
  final MssqlSelectQuery? query;

  /// Which source this is, for the columns that belong to it.
  ///
  /// Generated columns name a [MssqlSourceRef] rather than a qualifier, and
  /// this is the other half: as the query writes its `FROM` and its joins, it
  /// tells the statement what each source ended up being called. A source with
  /// no ref — a hand-written `MssqlSource('dbo.Orders')` — binds nothing, and
  /// untyped columns go on writing their own qualifiers.
  final MssqlSourceRef? ref;

  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    _register(parameters);
    final nested = query;
    if (nested != null) {
      return '(${nested.compileInto(parameters, dialect, nested: true)}) '
          'AS ${MssqlSql.quoteIdentifier(alias!)}';
    }
    return alias == null
        ? quoted
        : '$quoted AS ${MssqlSql.quoteIdentifier(alias!)}';
  }

  /// Records what this source is called in the statement being compiled.
  ///
  /// Called before the source's own SQL is written, so that a subquery's
  /// columns resolve while the subquery compiles.
  void _register(MssqlParameterAllocator parameters) {
    final identity = ref;
    if (identity == null) return;
    parameters.sources.bind(
      identity,
      alias == null ? quoted : MssqlSql.quoteIdentifier(alias!),
    );
  }
}

/// A `SELECT`-shaped statement that can be nested while sharing parameters.
abstract interface class MssqlSelectQuery {
  /// Known number of selected expressions, or null when it cannot be proven.
  int? get projectionCount;

  MssqlStatement compile({MssqlDialect dialect = MssqlDialect.sql2012});

  String compileInto(
    MssqlParameterAllocator parameters,
    MssqlDialect dialect, {
    bool nested = false,
  });

  MssqlSetQuery union(MssqlSelectQuery other);

  MssqlSetQuery unionAll(MssqlSelectQuery other);
}

/// One named query in a `WITH` clause.
///
/// A common table expression is how SQL Server writes a query that refers to
/// itself, which is the only way to walk a hierarchy — a category tree, an
/// organisation chart, a bill of materials — in one statement.
@immutable
class MssqlCte {
  MssqlCte(this.name, this.query, {List<String> columns = const <String>[]})
    : columns = List<String>.unmodifiable(columns) {
    MssqlSql.quoteIdentifier(name);
    for (final column in columns) {
      MssqlSql.quoteIdentifier(column);
    }
  }

  /// A recursive expression: the anchor member, then the member that refers
  /// back to [name].
  ///
  /// T-SQL has no `RECURSIVE` keyword — SQL Server infers it from the
  /// self-reference — so this is `UNION ALL` between the two members, and it
  /// exists as its own constructor because the column list is not optional
  /// here: the recursive member's names cannot be derived.
  factory MssqlCte.recursive(
    String name, {
    required MssqlSelectQuery anchor,
    required MssqlSelectQuery recursive,
    required List<String> columns,
  }) {
    if (columns.isEmpty) {
      throw ArgumentError.value(
        columns,
        'columns',
        'A recursive expression must name its columns: SQL Server cannot '
            'derive them from a query that refers to itself.',
      );
    }
    return MssqlCte(name, anchor.unionAll(recursive), columns: columns);
  }

  final String name;
  final MssqlSelectQuery query;

  /// The names the expression exposes, which override whatever the query
  /// projects. Required for [MssqlCte.recursive] and optional otherwise.
  final List<String> columns;

  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final buffer = StringBuffer(MssqlSql.quoteIdentifier(name));
    if (columns.isNotEmpty) {
      buffer.write(' (${columns.map(MssqlSql.quoteIdentifier).join(', ')})');
    }
    // nested: true — a member cannot carry its own ordering, and the compiler
    // says so rather than letting the server reject it.
    buffer.write(
      ' AS (${query.compileInto(parameters, dialect, nested: true)})',
    );
    return buffer.toString();
  }
}

/// An immutable `SELECT`. Every method returns a new instance, so a base query
/// can be shared between the page and its count without the two drifting.
@immutable
class MssqlQuery implements MssqlSelectQuery {
  const MssqlQuery._({
    required this.source,
    required this.joins,
    required this.projection,
    required this.conditions,
    required this.grouping,
    required this.having,
    required this.ordering,
    required this.distinct,
    required this.offset,
    required this.rows,
    required this.topRows,
    required this.lockHint,
    required this.ctes,
    required this.maxRecursion,
  });

  /// Starts a query against a source whose parts are already separated; see
  /// [MssqlSource.parts].
  factory MssqlQuery.fromParts(
    List<String> parts, {
    String? as,
    MssqlSourceRef? ref,
  }) => MssqlQuery.fromSource(MssqlSource.parts(parts, alias: as, ref: ref));

  /// Starts a query against [identifier], such as `dbo.Orders`.
  factory MssqlQuery.from(
    String identifier, {
    String? as,
    MssqlSourceRef? ref,
  }) => MssqlQuery.fromSource(MssqlSource(identifier, alias: as, ref: ref));

  /// Starts a query against an already-built source.
  factory MssqlQuery.fromSource(MssqlSource source) => MssqlQuery._(
    source: source,
    joins: const <MssqlJoin>[],
    projection: const <MssqlExpression>[],
    conditions: const <MssqlCondition>[],
    grouping: const <MssqlExpression>[],
    having: null,
    ordering: const <MssqlOrder>[],
    distinct: false,
    offset: null,
    rows: null,
    topRows: null,
    lockHint: null,
    ctes: const <MssqlCte>[],
    maxRecursion: null,
  );

  /// Starts a query from a derived table. SQL Server requires its alias.
  factory MssqlQuery.fromSub(MssqlSelectQuery query, {required String as}) =>
      MssqlQuery._(
        source: MssqlSource.subquery(query, as: as),
        joins: const <MssqlJoin>[],
        projection: const <MssqlExpression>[],
        conditions: const <MssqlCondition>[],
        grouping: const <MssqlExpression>[],
        having: null,
        ordering: const <MssqlOrder>[],
        distinct: false,
        offset: null,
        rows: null,
        topRows: null,
        lockHint: null,
        ctes: const <MssqlCte>[],
        maxRecursion: null,
      );

  final MssqlSource source;
  final List<MssqlJoin> joins;
  final List<MssqlExpression> projection;

  @override
  int? get projectionCount => projection.isEmpty ? null : projection.length;
  final List<MssqlCondition> conditions;
  final List<MssqlExpression> grouping;
  final MssqlCondition? having;
  final List<MssqlOrder> ordering;
  final bool distinct;
  final int? offset;
  final int? rows;

  /// `SELECT TOP (n)`, which is not paging: no offset and no ordering needed.
  final int? topRows;

  /// A table hint on the source, such as `WITH (UPDLOCK, ROWLOCK)`.
  final String? lockHint;

  /// The `WITH` clause, in the order it is written.
  final List<MssqlCte> ctes;

  /// `OPTION (MAXRECURSION n)`. Null leaves SQL Server's default of 100, which
  /// stops a runaway recursion with an error rather than a hang.
  final int? maxRecursion;

  MssqlQuery _with({
    List<MssqlJoin>? joins,
    List<MssqlExpression>? projection,
    List<MssqlCondition>? conditions,
    List<MssqlExpression>? grouping,
    MssqlCondition? having,
    List<MssqlOrder>? ordering,
    bool? distinct,
    int? offset,
    int? rows,
    int? topRows,
    String? lockHint,
    List<MssqlCte>? ctes,
    int? maxRecursion,
  }) => MssqlQuery._(
    source: source,
    joins: joins ?? this.joins,
    projection: projection ?? this.projection,
    conditions: conditions ?? this.conditions,
    grouping: grouping ?? this.grouping,
    having: having ?? this.having,
    ordering: ordering ?? this.ordering,
    distinct: distinct ?? this.distinct,
    offset: offset ?? this.offset,
    rows: rows ?? this.rows,
    topRows: topRows ?? this.topRows,
    lockHint: lockHint ?? this.lockHint,
    ctes: ctes ?? this.ctes,
    maxRecursion: maxRecursion ?? this.maxRecursion,
  );

  MssqlQuery join(
    MssqlJoinKind kind,
    String identifier, {
    String? as,
    MssqlCondition? on,
  }) {
    if (kind == MssqlJoinKind.cross) {
      if (on != null) {
        throw ArgumentError.value(on, 'on', 'A CROSS JOIN takes no ON clause.');
      }
    } else if (on == null) {
      throw ArgumentError.notNull('on');
    }
    return _with(
      joins: <MssqlJoin>[
        ...joins,
        MssqlJoin(kind, MssqlSource(identifier, alias: as), on),
      ],
    );
  }

  MssqlQuery joinSub(
    MssqlJoinKind kind,
    MssqlSelectQuery query, {
    required String as,
    MssqlCondition? on,
  }) {
    if (kind == MssqlJoinKind.cross) {
      if (on != null) {
        throw ArgumentError.value(on, 'on', 'A CROSS JOIN takes no ON clause.');
      }
    } else if (on == null) {
      throw ArgumentError.notNull('on');
    }
    return _with(
      joins: <MssqlJoin>[
        ...joins,
        MssqlJoin(kind, MssqlSource.subquery(query, as: as), on),
      ],
    );
  }

  MssqlQuery innerJoin(
    String identifier, {
    String? as,
    required MssqlCondition on,
  }) => join(MssqlJoinKind.inner, identifier, as: as, on: on);
  MssqlQuery leftJoin(
    String identifier, {
    String? as,
    required MssqlCondition on,
  }) => join(MssqlJoinKind.left, identifier, as: as, on: on);
  MssqlQuery rightJoin(
    String identifier, {
    String? as,
    required MssqlCondition on,
  }) => join(MssqlJoinKind.right, identifier, as: as, on: on);
  MssqlQuery fullJoin(
    String identifier, {
    String? as,
    required MssqlCondition on,
  }) => join(MssqlJoinKind.full, identifier, as: as, on: on);
  MssqlQuery crossJoin(String identifier, {String? as}) =>
      join(MssqlJoinKind.cross, identifier, as: as);

  MssqlQuery select(Iterable<MssqlExpression> expressions) =>
      _with(projection: List<MssqlExpression>.unmodifiable(expressions));

  MssqlQuery selectDistinct(Iterable<MssqlExpression> expressions) => _with(
    projection: List<MssqlExpression>.unmodifiable(expressions),
    distinct: true,
  );

  /// Prefixes the query with a common table expression.
  ///
  /// The name is then an ordinary source: `MssqlQuery.from('tree')`, or a join
  /// target. Repeated calls add further expressions, each able to refer to the
  /// ones named before it.
  ///
  /// Not called `with`, which is a reserved word in Dart.
  MssqlQuery withCte(
    String name,
    MssqlSelectQuery query, {
    List<String> columns = const <String>[],
  }) => withExpression(MssqlCte(name, query, columns: columns));

  /// Prefixes the query with a recursive expression.
  ///
  /// [anchor] is the starting row set and [recursive] the member that selects
  /// from [name] itself. [maxRecursion] becomes `OPTION (MAXRECURSION n)`;
  /// SQL Server's default is 100, and 0 removes the ceiling — which turns a
  /// cycle in the data from an error into a query that never returns, so pass
  /// it only where the data is known to be acyclic.
  MssqlQuery withRecursiveCte(
    String name, {
    required MssqlSelectQuery anchor,
    required MssqlSelectQuery recursive,
    required List<String> columns,
    int? maxRecursion,
  }) => withExpression(
    MssqlCte.recursive(
      name,
      anchor: anchor,
      recursive: recursive,
      columns: columns,
    ),
    maxRecursion: maxRecursion,
  );

  /// Prefixes the query with an expression already built.
  MssqlQuery withExpression(MssqlCte cte, {int? maxRecursion}) {
    if (maxRecursion != null && (maxRecursion < 0 || maxRecursion > 32767)) {
      throw ArgumentError.value(
        maxRecursion,
        'maxRecursion',
        'SQL Server accepts 0 to 32767, where 0 means no ceiling.',
      );
    }
    for (final existing in ctes) {
      if (existing.name.toLowerCase() == cte.name.toLowerCase()) {
        throw ArgumentError.value(
          cte.name,
          'cte',
          'The WITH clause already names an expression "${existing.name}". '
              'Two expressions of one name cannot both be referred to.',
        );
      }
    }
    return _with(ctes: <MssqlCte>[...ctes, cte], maxRecursion: maxRecursion);
  }

  /// Adds a condition. Repeated calls are combined with `AND`.
  MssqlQuery where(MssqlCondition condition) =>
      _with(conditions: <MssqlCondition>[...conditions, condition]);

  MssqlQuery groupBy(Iterable<MssqlExpression> expressions) =>
      _with(grouping: List<MssqlExpression>.unmodifiable(expressions));

  MssqlQuery havingCondition(MssqlCondition condition) =>
      _with(having: condition);

  MssqlQuery orderBy(Iterable<MssqlOrder> terms) =>
      _with(ordering: List<MssqlOrder>.unmodifiable(terms));

  /// Takes [rows] rows starting at [offset].
  ///
  /// Requires an `ORDER BY`: SQL Server rejects `OFFSET` without one, and the
  /// `ROW_NUMBER` form has no ordering to number by. The check happens at
  /// [compile] so that the failure names this query rather than arriving as a
  /// server syntax error.
  MssqlQuery paged({required int offset, required int rows}) {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'Cannot be negative.');
    }
    if (rows <= 0) {
      throw ArgumentError.value(rows, 'rows', 'Must be positive.');
    }
    return _with(offset: offset, rows: rows);
  }

  /// Applies [build] only when [condition] holds.
  ///
  /// Keeps conditional filters in the fluent chain. [otherwise] handles the
  /// false branch.
  MssqlQuery when(
    bool condition,
    MssqlQuery Function(MssqlQuery query) build, {
    MssqlQuery Function(MssqlQuery query)? otherwise,
  }) {
    if (condition) return build(this);
    return otherwise == null ? this : otherwise(this);
  }

  /// [when], inverted.
  MssqlQuery unless(
    bool condition,
    MssqlQuery Function(MssqlQuery query) build, {
    MssqlQuery Function(MssqlQuery query)? otherwise,
  }) => when(!condition, build, otherwise: otherwise);

  /// Applies [build] when [value] is not null, handing it to the callback
  /// already promoted to its non-nullable type.
  ///
  /// `whenNotNull(search, (q, s) => q.where(Col('Name').like(s)))` is the
  /// shape a filter almost always takes, and it saves the `!` that [when]
  /// would otherwise need.
  MssqlQuery whenNotNull<T extends Object>(
    T? value,
    MssqlQuery Function(MssqlQuery query, T value) build,
  ) => value == null ? this : build(this, value);

  /// The first [rows] rows, with no offset: `SELECT TOP (n)`.
  ///
  /// Unlike [paged], `TOP` needs no `ORDER BY`.
  MssqlQuery top(int rows) {
    if (rows <= 0) {
      throw ArgumentError.value(rows, 'rows', 'Must be positive.');
    }
    return _with(topRows: rows);
  }

  /// Holds a shared lock on the rows read until the transaction ends:
  /// `WITH (HOLDLOCK, ROWLOCK)`.
  ///
  /// Others can still read them but not change them. Outside a transaction the
  /// lock is released immediately, so this belongs inside one.
  MssqlQuery sharedLock() => _withSourceHint('HOLDLOCK, ROWLOCK');

  /// Locks the rows read against other readers that also intend to write:
  /// `WITH (UPDLOCK, ROWLOCK)`.
  ///
  /// The read-then-write pattern — read a row, decide, update it — is where
  /// two callers otherwise both read the old value. Also only meaningful
  /// inside a transaction.
  MssqlQuery lockForUpdate() => _withSourceHint('UPDLOCK, ROWLOCK');

  /// An arbitrary table hint, for the ones this does not name.
  ///
  /// The text is inserted verbatim, so it is the caller's SQL. `NOLOCK` is the
  /// usual reason to reach for this, and it is worth knowing what it costs:
  /// it can return rows twice, miss rows entirely, and read data that is
  /// rolled back a moment later.
  MssqlQuery withHint(String hint) => _withSourceHint(hint);

  MssqlQuery _withSourceHint(String hint) {
    if (source.query != null) {
      throw StateError('SQL Server does not allow table hints on a subquery.');
    }
    return _with(lockHint: hint);
  }

  @override
  MssqlSetQuery union(MssqlSelectQuery other) =>
      MssqlSetQuery._(<MssqlSelectQuery>[this, other], const <bool>[false]);

  @override
  MssqlSetQuery unionAll(MssqlSelectQuery other) =>
      MssqlSetQuery._(<MssqlSelectQuery>[this, other], const <bool>[true]);

  /// Compiles to SQL and its bound values.
  @override
  MssqlStatement compile({MssqlDialect dialect = MssqlDialect.sql2012}) {
    final parameters = MssqlParameterAllocator();
    return MssqlStatement.fromAllocator(
      compileInto(parameters, dialect),
      parameters,
    );
  }

  /// `SELECT COUNT_BIG(*)` over the rows *this query returns*.
  ///
  /// A count is not "the same query with the projection swapped": swapping the
  /// projection of a `SELECT DISTINCT` yields the number of source rows, and on
  /// a `GROUP BY` the size of the first group. A query whose shape collapses
  /// rows — `DISTINCT`, `GROUP BY`, `HAVING` — is therefore counted through a
  /// derived table that preserves that shape, while an ordinary query is
  /// counted in place.
  ///
  /// Rows, not entities: on a query joined to a child table this counts join
  /// result rows, and a parent that has three children contributes three of
  /// them. [countDistinct] over the parent key is the other question.
  MssqlQuery countRows() =>
      _aggregateOverResult(countAll(big: true), 'countRows()');

  /// The number of distinct values of [expressions] among the rows this query
  /// matches.
  ///
  /// One expression compiles to `COUNT_BIG(DISTINCT …)`. Several cannot:
  /// SQL Server's `COUNT(DISTINCT …)` takes exactly one argument, so a
  /// composite key is counted through a derived `SELECT DISTINCT` of its
  /// columns. Reducing a composite key to its first column would compile and
  /// return a smaller number, which is why the two shapes live behind one
  /// method that knows which it is looking at.
  MssqlQuery countDistinct(Iterable<MssqlExpression> expressions) =>
      _countDistinct(expressions);

  /// An aggregate over the rows this query returns.
  ///
  /// Follows [countRows] in every respect except which aggregate is written,
  /// including the derived table a collapsing shape needs: `SUM(Total)` beside
  /// an `ORDER BY` is not valid SQL, and beside a `GROUP BY` it is a different
  /// question.
  MssqlQuery aggregateRows(MssqlExpression aggregate) =>
      _aggregateOverResult(aggregate, 'aggregateRows()');

  @override
  String compileInto(
    MssqlParameterAllocator parameters,
    MssqlDialect dialect, {
    bool nested = false,
  }) => _MssqlSelectCompiler(this, dialect, nested: nested).compile(parameters);
}

/// Shorthand for [MssqlQuery.from]: `query('dbo.Orders')`.
MssqlQuery query(String identifier, {String? as}) =>
    MssqlQuery.from(identifier, as: as);

/// A chain of `UNION` / `UNION ALL` queries with optional outer ordering.
@immutable
class MssqlSetQuery implements MssqlSelectQuery {
  MssqlSetQuery._(
    Iterable<MssqlSelectQuery> members,
    Iterable<bool> allFlags, {
    Iterable<MssqlOrder> ordering = const <MssqlOrder>[],
    this.offset,
    this.rows,
  }) : members = List<MssqlSelectQuery>.unmodifiable(members),
       allFlags = List<bool>.unmodifiable(allFlags),
       ordering = List<MssqlOrder>.unmodifiable(ordering);

  final List<MssqlSelectQuery> members;

  /// One flag per boundary between members. True means `UNION ALL`.
  final List<bool> allFlags;
  final List<MssqlOrder> ordering;
  final int? offset;
  final int? rows;

  @override
  int? get projectionCount {
    int? count;
    for (final member in members) {
      final current = member.projectionCount;
      if (current == null) return null;
      count ??= current;
      if (current != count) return null;
    }
    return count;
  }

  @override
  MssqlSetQuery union(MssqlSelectQuery other) => MssqlSetQuery._(
    <MssqlSelectQuery>[...members, other],
    <bool>[...allFlags, false],
    ordering: ordering,
    offset: offset,
    rows: rows,
  );

  @override
  MssqlSetQuery unionAll(MssqlSelectQuery other) => MssqlSetQuery._(
    <MssqlSelectQuery>[...members, other],
    <bool>[...allFlags, true],
    ordering: ordering,
    offset: offset,
    rows: rows,
  );

  MssqlSetQuery orderBy(Iterable<MssqlOrder> terms) => MssqlSetQuery._(
    members,
    allFlags,
    ordering: terms,
    offset: offset,
    rows: rows,
  );

  MssqlSetQuery paged({required int offset, required int rows}) {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'Cannot be negative.');
    }
    if (rows <= 0) {
      throw ArgumentError.value(rows, 'rows', 'Must be positive.');
    }
    return MssqlSetQuery._(
      members,
      allFlags,
      ordering: ordering,
      offset: offset,
      rows: rows,
    );
  }

  @override
  MssqlStatement compile({MssqlDialect dialect = MssqlDialect.sql2012}) {
    final parameters = MssqlParameterAllocator();
    return MssqlStatement.fromAllocator(
      compileInto(parameters, dialect),
      parameters,
    );
  }

  @override
  String compileInto(
    MssqlParameterAllocator parameters,
    MssqlDialect dialect, {
    bool nested = false,
  }) {
    _validate(dialect, nested: nested);
    final out = StringBuffer();
    for (var i = 0; i < members.length; i++) {
      if (i > 0) out.write(allFlags[i - 1] ? ' UNION ALL ' : ' UNION ');
      out.write(members[i].compileInto(parameters, dialect, nested: true));
    }
    if (ordering.isNotEmpty) {
      out.write(
        ' ORDER BY '
        '${_MssqlSelectCompiler.orderList(ordering, parameters, dialect)}',
      );
    }
    if (offset != null) {
      out.write(
        ' OFFSET ${parameters.bind(offset)} ROWS '
        'FETCH NEXT ${parameters.bind(rows)} ROWS ONLY',
      );
    }
    return out.toString();
  }

  // Validates clauses owned by the union. Member-level restrictions are
  // enforced while each nested query is compiled.
  void _validate(MssqlDialect dialect, {required bool nested}) {
    if (members.length < 2 || allFlags.length != members.length - 1) {
      throw StateError('A set query needs at least two valid members.');
    }
    if (offset != null && ordering.isEmpty) {
      throw StateError(
        'paged() on a union needs orderBy(): SQL Server rejects OFFSET '
        'without ORDER BY, and an unordered page is not repeatable.',
      );
    }
    if (nested && ordering.isNotEmpty && offset == null) {
      throw StateError(
        'A nested union may only order rows when it also uses paged().',
      );
    }
    if (offset != null) {
      dialect.require(
        dialect.supportsOffsetFetch,
        feature: 'paged() on a union',
        requires:
            'SQL Server 2012 or newer, or a database at compatibility level '
            '110 or higher. An older target pages through a ROW_NUMBER() '
            'column, which a union cannot carry: read the union as a derived '
            'table with MssqlQuery.fromSub(union, as: …) and page that query '
            'instead',
      );
    }
    final knownCounts = members
        .map((member) => member.projectionCount)
        .whereType<int>()
        .toSet();
    if (knownCounts.length > 1) {
      throw StateError('Every member of a union must project the same count.');
    }
    for (final member in members) {
      if (member is MssqlQuery &&
          (member.ordering.isNotEmpty || member.offset != null)) {
        throw StateError(
          'A union member cannot carry its own orderBy() or paged(); apply '
          'them to the union instead.',
        );
      }
      if (member is MssqlSetQuery &&
          (member.ordering.isNotEmpty || member.offset != null)) {
        throw StateError(
          'A nested union member cannot carry its own ordering or paging.',
        );
      }
    }
  }
}
