import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'dialect.dart';
import 'source_ref.dart';
import 'statement.dart';
import 'typed_column.dart';

/// Anything that compiles to a fragment of SQL.
@immutable
abstract class MssqlExpression {
  const MssqlExpression();

  /// Writes this expression's SQL, binding any values through [parameters].
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect);
}

/// An expression that produces a boolean, usable in `WHERE` and `HAVING`.
///
/// `&` and `|` combine two of them, and every combination is parenthesised as
/// it compiles, so `a & b | c` means what the Dart precedence says rather than
/// what SQL's would.
///
/// Dart's `&&` and `||` are not part of this DSL and cannot be: they take
/// `bool`, and short-circuit, so they would have to evaluate a condition
/// rather than build one. `==` is not either — it is Dart equality between two
/// condition objects, which is never what a query means. Column equality is
/// `eq`.
@immutable
abstract class MssqlCondition extends MssqlExpression {
  const MssqlCondition();

  /// `(this AND other)`.
  MssqlCondition operator &(MssqlCondition other) =>
      MssqlJunction('AND', <MssqlCondition>[this, other]);

  /// `(this OR other)`.
  MssqlCondition operator |(MssqlCondition other) =>
      MssqlJunction('OR', <MssqlCondition>[this, other]);
}

/// A reference to a column, optionally qualified by a table or alias.
///
/// `MssqlColumn` is taken: the driver uses it for result-set metadata.
///
/// The base of both the untyped [MssqlColumnRef] and the generated
/// [MssqlTypedColumn]. They are siblings so an untyped column stays open to
/// every predicate while a typed one offers only those its type supports.
@immutable
abstract class MssqlColumnBase extends MssqlExpression {
  MssqlColumnBase(String identifier)
    : _quoted = MssqlMultipartIdentifier.parse(
        identifier,
        maximumParts: 4,
      ).quoted,
      name = MssqlMultipartIdentifier.parse(
        identifier,
        maximumParts: 4,
      ).parts.last,
      source = null,
      _quotedName = null;

  /// For a column written out in full, qualifier and all.
  const MssqlColumnBase.quoted(String quoted, this.name)
    : _quoted = quoted,
      source = null,
      _quotedName = null;

  /// A column that belongs to a source and is qualified while the query is
  /// compiled, rather than when the column is declared.
  ///
  /// This is what generated code emits. The alias a query gives the table, or
  /// the schema a tenant points it at, is not knowable when the column is
  /// declared; a column that had baked its qualifier in would go on naming the
  /// table it was generated from, which is a source the query may not even
  /// have.
  const MssqlColumnBase.inSource({
    required MssqlSourceRef this.source,
    required this.name,
    required String quotedName,
  }) : _quoted = null,
       _quotedName = quotedName;

  final String? _quoted;

  /// The source this column belongs to, or null when it was written in full.
  final MssqlSourceRef? source;

  /// The column's own name, without any qualifier.
  final String name;

  /// `[Name]`, precomputed so compiling does not re-quote on every use.
  final String? _quotedName;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final ref = source;
    if (ref == null) return _quoted!;
    return '${parameters.sources.qualifierFor(ref)}.$_quotedName';
  }

  @override
  String toString() {
    final ref = source;
    return 'Col(${ref == null ? _quoted : '${ref.qualifiedName}.$name'})';
  }
}

/// A column named as text, with no declared SQL type.
///
/// Every predicate is available on one, because nothing here knows enough to
/// rule any of them out — `Col('Name').contains('a')` is exactly what the
/// untyped builder is for. Generated code produces [MssqlTypedColumn] instead,
/// where the type does know, and where `total.contains('5')` therefore does
/// not compile.
@immutable
class MssqlColumnRef extends MssqlColumnBase
    with MssqlTextExpression, MssqlNumericExpression, MssqlTemporalExpression {
  MssqlColumnRef(super.identifier);

  const MssqlColumnRef.quoted(super.quoted, super.name) : super.quoted();

  const MssqlColumnRef.inSource({
    required super.source,
    required super.name,
    required super.quotedName,
  }) : super.inSource();

  /// A short factory: `Col('o.Total')`.
  // ignore: non_constant_identifier_names
  static MssqlColumnRef of(String identifier) => MssqlColumnRef(identifier);
}

/// A short factory for [MssqlColumnRef].
// ignore: non_constant_identifier_names
MssqlColumnRef Col(String identifier) => MssqlColumnRef(identifier);

/// A value bound as a parameter. Values never reach the SQL text.
@immutable
class MssqlLiteral extends MssqlExpression {
  const MssqlLiteral(this.value);

  final Object? value;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      parameters.bind(value);
}

/// A SQL function or aggregate over other expressions.
@immutable
class MssqlFunction extends MssqlExpression {
  MssqlFunction(this.name, Iterable<MssqlExpression> arguments)
    : arguments = List<MssqlExpression>.unmodifiable(arguments) {
    if (!_sqlFunctionName.hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'A SQL function name must be an unquoted identifier, optionally '
            'qualified by schema.',
      );
    }
  }

  final String name;
  final List<MssqlExpression> arguments;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final compiled = arguments
        .map((a) => a.compile(parameters, dialect))
        .join(', ');
    return '$name($compiled)';
  }
}

/// `COUNT(*)`, or `COUNT_BIG(*)`.
///
/// Its own node rather than an [MssqlFunction] over a `*` argument, because
/// `*` is not an expression — there is nothing on the inside to compile. Its
/// own node rather than `raw('COUNT(*)')` for the more consequential reason: a
/// raw fragment marks the whole statement as SQL the builder did not write,
/// which takes a plain count out of the read-retry class it belongs to.
@immutable
class MssqlCountAll extends MssqlExpression {
  const MssqlCountAll({this.big = false});

  /// `COUNT_BIG`, whose result is `bigint`.
  ///
  /// `COUNT` returns `int` and overflows past 2^31 with an error rather than
  /// widening, so the compilers count with this form. The narrow one stays
  /// reachable for a caller writing their own projection against a column
  /// whose type they have chosen.
  final bool big;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      big ? 'COUNT_BIG(*)' : 'COUNT(*)';
}

/// `COUNT_BIG(DISTINCT expression)`.
///
/// Its own node because `DISTINCT` inside an aggregate is a modifier on the
/// argument rather than another argument, so [MssqlFunction] cannot write it.
/// Only ever one expression: that is SQL Server's own limit, and it is why a
/// composite key is counted through a derived `SELECT DISTINCT` instead.
@immutable
class MssqlDistinctCount extends MssqlExpression {
  const MssqlDistinctCount(this.expression);

  final MssqlExpression expression;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      'COUNT_BIG(DISTINCT ${expression.compile(parameters, dialect)})';
}

/// A fragment of SQL written by the caller, with the parameters it uses.
///
/// No builder covers SQL Server, and a builder with no way out becomes
/// unusable at the first query it does not cover. The fragment is inserted
/// verbatim — it is the caller's SQL and the caller owns it — but a value
/// still never needs to be concatenated into it.
@immutable
class MssqlRaw extends MssqlCondition {
  MssqlRaw(
    this.sql, [
    Map<String, Object?> parameters = const <String, Object?>{},
  ]) : parameters = Map<String, Object?>.unmodifiable(parameters);

  final String sql;
  final Map<String, Object?> parameters;

  @override
  String compile(MssqlParameterAllocator allocator, MssqlDialect dialect) {
    allocator.merge(parameters);
    allocator.markRaw();
    return sql;
  }
}

/// The constant `1`, written into the SQL text rather than bound.
///
/// The single place the builder puts a value into SQL, and it is not a value:
/// `SELECT TOP (@n) 1 FROM …` is the existence probe's projection, where the
/// digit is part of the shape and carries no data. The two other ways to get
/// it are both worse. Binding it adds a parameter to every `exists()` for no
/// purpose and spends one of the statement's 2100. Writing `raw('1')` marks
/// the statement as carrying caller SQL, which correctly turns off the
/// read-retry classification a builder-written SELECT is entitled to — so an
/// `exists()` stopped being retryable because of the digit `1`.
///
/// There is no constructor that takes a value, so no caller input can reach
/// SQL text through this class.
@immutable
class MssqlProbeLiteral extends MssqlExpression {
  const MssqlProbeLiteral();

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      '1';

  @override
  String toString() => 'MssqlProbeLiteral(1)';
}

/// A raw SQL fragment carrying its own parameters.
MssqlRaw raw(
  String sql, [
  Map<String, Object?> parameters = const <String, Object?>{},
]) => MssqlRaw(sql, parameters);

/// An expression given a result alias, as in `SELECT c.Name AS Customer`.
@immutable
class MssqlAliased extends MssqlExpression {
  MssqlAliased(this.expression, this.alias) {
    MssqlSql.quoteIdentifier(alias);
  }

  final MssqlExpression expression;
  final String alias;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      '${expression.compile(parameters, dialect)} AS '
      '${MssqlSql.quoteIdentifier(alias)}';
}

/// A binary comparison between an expression and an operand.
@immutable
class MssqlComparison extends MssqlCondition {
  MssqlComparison(this.left, this.operator, this.right) {
    if (!_comparisonOperators.contains(operator)) {
      throw ArgumentError.value(
        operator,
        'operator',
        'Use one of =, <>, <, <=, > or >=.',
      );
    }
  }

  final MssqlExpression left;
  final String operator;
  final MssqlExpression right;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      '${left.compile(parameters, dialect)} $operator '
      '${right.compile(parameters, dialect)}';
}

/// `IS NULL` / `IS NOT NULL`.
@immutable
class MssqlNullCheck extends MssqlCondition {
  const MssqlNullCheck(this.operand, {required this.negated});

  final MssqlExpression operand;
  final bool negated;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      '${operand.compile(parameters, dialect)} '
      'IS ${negated ? 'NOT ' : ''}NULL';
}

/// `IN (…)` / `NOT IN (…)`.
@immutable
class MssqlInList extends MssqlCondition {
  MssqlInList(this.operand, Iterable<Object?> values, {required this.negated})
    : values = List<Object?>.unmodifiable(values) {
    if (this.values.isEmpty) {
      throw ArgumentError.value(
        values,
        'values',
        'IN () is not valid SQL. Compiling an empty list to 1 = 0 would turn '
            'a forgotten empty filter into a query that returns nothing and '
            'looks like it worked; handle the empty case at the call site.',
      );
    }
  }

  final MssqlExpression operand;
  final List<Object?> values;
  final bool negated;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final bound = values.map(parameters.bind).join(', ');
    return '${operand.compile(parameters, dialect)} '
        '${negated ? 'NOT IN' : 'IN'} ($bound)';
  }
}

/// `BETWEEN … AND …`.
@immutable
class MssqlBetween extends MssqlCondition {
  const MssqlBetween(this.operand, this.lower, this.upper);

  final MssqlExpression operand;
  final Object? lower;
  final Object? upper;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      '${operand.compile(parameters, dialect)} BETWEEN '
      '${parameters.bind(lower)} AND ${parameters.bind(upper)}';
}

/// Where the wildcards go around an escaped search term.
enum MssqlLikePosition {
  /// The term as written: an exact match.
  exact,

  /// `%term%`.
  anywhere,

  /// `term%`.
  starting,

  /// `%term`.
  ending;

  /// Wraps an already-escaped term in this position's wildcards.
  String apply(String escaped) => switch (this) {
    exact => escaped,
    anywhere => '%$escaped%',
    starting => '$escaped%',
    ending => '%$escaped',
  };
}

/// `LIKE`, with the pattern escaped unless the caller asked for raw wildcards.
@immutable
class MssqlLike extends MssqlCondition {
  const MssqlLike(
    this.operand,
    this.pattern, {
    required this.negated,
    required this.escaped,
    this.position = MssqlLikePosition.exact,
  });

  final MssqlExpression operand;
  final String pattern;
  final bool negated;
  final bool escaped;

  /// Where the wildcards sit around the escaped term.
  ///
  /// Wildcards are added after escaping, so a `%` typed into a search box stays
  /// literal while the search is still a contains-match. Escaping afterwards
  /// would neutralise the added wildcards; adding them before would let the
  /// term smuggle its own.
  final MssqlLikePosition position;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final value = escaped
        ? position.apply(MssqlSql.escapeLike(pattern))
        : pattern;
    final bound = parameters.bind(value);
    final not = negated ? 'NOT ' : '';
    final suffix = escaped ? r" ESCAPE '\'" : '';
    return '${operand.compile(parameters, dialect)} ${not}LIKE $bound$suffix';
  }
}

/// `AND` / `OR` over two or more conditions.
@immutable
class MssqlJunction extends MssqlCondition {
  MssqlJunction(this.operator, Iterable<MssqlCondition> operands)
    : operands = List<MssqlCondition>.unmodifiable(operands) {
    if (!_junctionOperators.contains(operator)) {
      throw ArgumentError.value(operator, 'operator', 'Use AND or OR.');
    }
    if (this.operands.isEmpty) {
      throw ArgumentError.value(
        operands,
        'operands',
        'An $operator needs at least one condition.',
      );
    }
  }

  final String operator;
  final List<MssqlCondition> operands;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    if (operands.length == 1) {
      return operands.single.compile(parameters, dialect);
    }
    final parts = operands.map((o) => o.compile(parameters, dialect));
    return '(${parts.join(' $operator ')})';
  }
}

final RegExp _sqlFunctionName = RegExp(
  r'^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$',
);

const Set<String> _comparisonOperators = <String>{
  '=',
  '<>',
  '<',
  '<=',
  '>',
  '>=',
};
const Set<String> _junctionOperators = <String>{'AND', 'OR'};

/// `NOT (…)`.
@immutable
class MssqlNegation extends MssqlCondition {
  const MssqlNegation(this.operand);

  final MssqlCondition operand;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      'NOT (${operand.compile(parameters, dialect)})';
}

/// Combines [conditions] with `AND`.
MssqlCondition and(Iterable<MssqlCondition> conditions) =>
    MssqlJunction('AND', conditions);

/// Combines [conditions] with `OR`.
MssqlCondition or(Iterable<MssqlCondition> conditions) =>
    MssqlJunction('OR', conditions);

/// Negates [condition].
MssqlCondition not(MssqlCondition condition) => MssqlNegation(condition);
