import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'dialect.dart';
import 'expression.dart';
import 'predicates.dart';
import 'query.dart';
import 'statement.dart';

/// A scalar `(SELECT ...)` usable anywhere an expression is accepted.
@immutable
class MssqlScalarSubquery extends MssqlExpression {
  const MssqlScalarSubquery(this.query);

  final MssqlSelectQuery query;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    if (query.projectionCount != 1) {
      throw StateError('A scalar subquery must select exactly one expression.');
    }
    return '(${query.compileInto(parameters, dialect, nested: true)})';
  }
}

MssqlScalarSubquery scalarSubquery(MssqlSelectQuery query) =>
    MssqlScalarSubquery(query);

/// `EXISTS (SELECT ...)` and its negated form.
@immutable
class MssqlExistsSubquery extends MssqlCondition {
  const MssqlExistsSubquery(this.query, {required this.negated});

  final MssqlSelectQuery query;
  final bool negated;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      '${negated ? 'NOT ' : ''}EXISTS '
      '(${query.compileInto(parameters, dialect, nested: true)})';
}

/// `EXISTS (SELECT ...)` as a value, for a projection rather than a `WHERE`.
///
/// SQL Server has no boolean expression: `EXISTS` is a predicate and a
/// predicate cannot be selected, so `SELECT EXISTS (…)` is a syntax error.
/// A `CASE` around it is the only way to project the answer, and the `CAST`
/// to `bit` is what makes the result decode as a Dart `bool` rather than as
/// the 1 or 0 the `CASE` produces.
///
/// Still `EXISTS` inside, not `COUNT(*) > 0`: the server stops at the first
/// matching row rather than counting all of them.
@immutable
class MssqlExistsValue extends MssqlExpression implements MssqlTypedExpression {
  const MssqlExistsValue(this.query, {this.negated = false});

  final MssqlSelectQuery query;
  final bool negated;

  /// `bit`, and never null: the `CASE` covers both branches.
  @override
  MssqlColumnType get resultType =>
      const MssqlColumnType(type: MssqlType.bit, nullable: false);

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      'CAST(CASE WHEN ${negated ? 'NOT ' : ''}EXISTS '
      '(${query.compileInto(parameters, dialect, nested: true)}) '
      'THEN 1 ELSE 0 END AS bit)';
}

/// `EXISTS (SELECT …)` as a projectable `bit`.
MssqlExistsValue existsValue(MssqlSelectQuery query, {bool negated = false}) =>
    MssqlExistsValue(query, negated: negated);

/// `expression IN (SELECT ...)` and its negated form.
@immutable
class MssqlInSubquery extends MssqlCondition {
  const MssqlInSubquery(this.operand, this.query, {required this.negated});

  final MssqlExpression operand;
  final MssqlSelectQuery query;
  final bool negated;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    if (query.projectionCount != 1) {
      throw StateError('An IN subquery must select exactly one expression.');
    }
    return '${operand.compile(parameters, dialect)} '
        '${negated ? 'NOT IN' : 'IN'} '
        '(${query.compileInto(parameters, dialect, nested: true)})';
  }
}

extension MssqlSubqueryExpressionOperators on MssqlExpression {
  MssqlCondition inQuery(MssqlSelectQuery query) =>
      MssqlInSubquery(this, query, negated: false);

  MssqlCondition notInQuery(MssqlSelectQuery query) =>
      MssqlInSubquery(this, query, negated: true);
}

extension MssqlSubqueryClauses on MssqlQuery {
  MssqlQuery whereExists(MssqlSelectQuery query) =>
      where(MssqlExistsSubquery(query, negated: false));

  MssqlQuery whereNotExists(MssqlSelectQuery query) =>
      where(MssqlExistsSubquery(query, negated: true));
}
