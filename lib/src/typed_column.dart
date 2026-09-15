import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'dialect.dart';
import 'expression.dart';
import 'source_ref.dart';
import 'statement.dart';

/// A value bound with a column's own SQL type.
///
/// [MssqlLiteral] leaves the type to the driver's inference, which sees a Dart
/// `String` and sends `nvarchar` and a Dart number and sends `float`. Against a
/// `varchar` or a `decimal` column, SQL Server's type precedence then converts
/// the *column* rather than the parameter: the comparison changes meaning for
/// money, and the index on the column stops being usable. A typed literal
/// carries the column's codec, so the parameter is what the column is.
@immutable
class MssqlTypedLiteral extends MssqlExpression {
  const MssqlTypedLiteral(this.value, this.codec);

  final Object? value;
  final MssqlTypeCodec<Object?> codec;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      parameters.bind(codec.encode(value));
}

/// An expression whose SQL type is text, and which the text predicates accept.
///
/// A marker rather than a class, so that a column, a `CONCAT` and an untyped
/// `Col('Name')` can all be one without sharing an implementation. It is what
/// keeps `total.contains('5')` from compiling: a numeric column is not one.
abstract mixin class MssqlTextExpression implements MssqlExpression {}

/// An expression whose SQL type is a number.
abstract mixin class MssqlNumericExpression implements MssqlExpression {}

/// An expression whose SQL type is a date, a time or both.
abstract mixin class MssqlTemporalExpression implements MssqlExpression {}

/// A column that knows its Dart type.
///
/// Generated code uses these columns to constrain operators to the column's
/// Dart type. For example, `Users.name.gt(5)` fails to compile. Code written
/// against the untyped core remains compatible with generated columns.
///
/// Instance comparison methods take precedence over the untyped extensions on
/// [MssqlExpression], making invalid operands compile-time errors.
class MssqlTypedColumn<T> extends MssqlColumnBase {
  /// A column written out in full. Kept for hand-written schemas and for the
  /// untyped builder; generated code uses [MssqlTypedColumn.of].
  MssqlTypedColumn(super.quoted, super.name, {this.columnType})
    : super.quoted();

  /// A generated column: it belongs to a source, and it knows its SQL type.
  MssqlTypedColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required MssqlColumnType this.columnType,
  }) : super.inSource();

  /// What the column is in SQL, or null for a hand-written column that never
  /// said.
  ///
  /// Null means values fall back to the driver's type inference, the best that
  /// can be done without column metadata.
  final MssqlColumnType? columnType;

  /// Whether SQL says this column can be null.
  ///
  /// A nullable column still takes a non-null operand in every comparison:
  /// `= NULL` never matches anything, so accepting null there would be
  /// offering a predicate that cannot work. NULL is [isNull] and [isNotNull].
  bool get isNullable => columnType?.nullable ?? true;

  /// The codec for this column, built once.
  late final MssqlTypeCodec<Object?>? codec = columnType == null
      ? null
      : MssqlTypeCodecs.forColumn(columnType!);

  /// This column, seen through another source.
  ///
  /// What rebinding a query's root to another schema or alias does to its
  /// columns.
  MssqlTypedColumn<T> at(MssqlSourceRef source) {
    final ref = this.source;
    if (ref == null || columnType == null) {
      throw StateError(
        'Column $name was written out in full, so it cannot be moved to '
        'another source. Only generated columns carry a source.',
      );
    }
    return MssqlTypedColumn<T>.of(
      source: source,
      name: name,
      quotedName: _quotedNameOrThrow,
      columnType: columnType!,
    );
  }

  String get _quotedNameOrThrow => MssqlSql.quoteIdentifier(name);

  /// Typed comparisons. The untyped versions on [MssqlExpression] stay
  /// available for untyped columns; these shadow them with a narrower operand.
  MssqlCondition eq(T value) =>
      MssqlComparison(this, '=', operand(value, 'eq'));
  MssqlCondition ne(T value) =>
      MssqlComparison(this, '<>', operand(value, 'ne'));
  MssqlCondition lt(T value) =>
      MssqlComparison(this, '<', operand(value, 'lt'));
  MssqlCondition lte(T value) =>
      MssqlComparison(this, '<=', operand(value, 'lte'));
  MssqlCondition gt(T value) =>
      MssqlComparison(this, '>', operand(value, 'gt'));
  MssqlCondition gte(T value) =>
      MssqlComparison(this, '>=', operand(value, 'gte'));

  MssqlCondition inList(Iterable<T> values, {MssqlEmptyIn? onEmpty}) =>
      MssqlTypedInList(
        this,
        <MssqlExpression>[for (final value in values) operand(value, 'inList')],
        negated: false,
        onEmpty: onEmpty ?? MssqlEmptyIn.error,
      );

  MssqlCondition notInList(Iterable<T> values, {MssqlEmptyIn? onEmpty}) =>
      MssqlTypedInList(
        this,
        <MssqlExpression>[
          for (final value in values) operand(value, 'notInList'),
        ],
        negated: true,
        onEmpty: onEmpty ?? MssqlEmptyIn.error,
      );

  MssqlCondition between(T lower, T upper) => MssqlComparison(
    this,
    'BETWEEN',
    _BetweenBounds(operand(lower, 'between'), operand(upper, 'between')),
  );

  /// Binds [value] with this column's SQL type.
  ///
  /// Protected in spirit: the family subclasses below use it to build their
  /// own predicates, and nothing outside this file should need it.
  @protected
  MssqlExpression operand(T value, String method) {
    if (value == null) {
      throw ArgumentError.value(
        value,
        'value',
        "$method(null) is not a null test: SQL's \"= NULL\" never matches. "
            'Use isNull() or isNotNull().',
      );
    }
    final typed = codec;
    return typed == null
        ? MssqlLiteral(value)
        : MssqlTypedLiteral(value, typed);
  }
}

/// The right-hand side of a `BETWEEN`, so that the comparison node stays one
/// shape instead of growing a special case.
@immutable
class _BetweenBounds extends MssqlExpression {
  const _BetweenBounds(this.lower, this.upper);

  final MssqlExpression lower;
  final MssqlExpression upper;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      '${lower.compile(parameters, dialect)} AND '
      '${upper.compile(parameters, dialect)}';
}

/// What an `IN` with no values should do.
///
/// `IN ()` is invalid SQL. The default throws so missing filter values are not
/// mistaken for a successful query with no matches.
enum MssqlEmptyIn {
  /// Throw. The default.
  error,

  /// Match no rows: `1 = 0`, or `1 = 1` for `NOT IN`.
  ///
  /// For a UI filter where "none selected" means "nothing matches".
  matchNone,

  /// Leave the predicate out entirely.
  ///
  /// Use when an empty selection means no filter. Writes require
  /// [MssqlWriteScope.unrestricted] because omitting the predicate widens their
  /// scope.
  omit,
}

/// `IN (…)` over already-bound operands.
///
/// Separate from [MssqlInList] because the values here have been through a
/// column's codec: they are expressions, not raw Dart values waiting for the
/// driver to guess a type for them.
@immutable
class MssqlTypedInList extends MssqlCondition {
  MssqlTypedInList(
    this.operand,
    List<MssqlExpression> values, {
    required this.negated,
    this.onEmpty = MssqlEmptyIn.error,
  }) : values = List<MssqlExpression>.unmodifiable(values) {
    if (this.values.isEmpty && onEmpty == MssqlEmptyIn.error) {
      throw ArgumentError.value(
        values,
        'values',
        'IN () is not valid SQL. Compiling an empty list to 1 = 0 would turn '
            'a forgotten empty filter into a query that returns nothing and '
            'looks like it worked. Pass onEmpty: MssqlEmptyIn.matchNone or '
            'MssqlEmptyIn.omit to say which you meant.',
      );
    }
  }

  final MssqlExpression operand;
  final List<MssqlExpression> values;
  final bool negated;
  final MssqlEmptyIn onEmpty;

  /// Whether this predicate contributes nothing and should be dropped.
  bool get isOmitted => values.isEmpty && onEmpty == MssqlEmptyIn.omit;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    if (values.isEmpty) {
      // omit is resolved by whoever assembles the WHERE clause, the only place
      // that can drop a predicate. Reaching here means it did not, so compile
      // as matching nothing.
      return negated ? '1 = 1' : '1 = 0';
    }
    final bound = values.map((v) => v.compile(parameters, dialect)).join(', ');
    return '${operand.compile(parameters, dialect)} '
        '${negated ? 'NOT IN' : 'IN'} ($bound)';
  }
}

/// How far a write is allowed to reach.
///
/// An empty `IN` that is omitted removes a predicate, and removing a predicate
/// from an `UPDATE` widens it. That is a decision, not a default: this is how
/// a caller says they meant it.
enum MssqlWriteScope {
  /// The predicates as written must narrow the write. The default.
  filtered,

  /// The caller accepts a write that reaches every row the remaining
  /// predicates allow, including all of them.
  unrestricted,
}

// One subclass per SQL type family, so the operations a column offers are the
// operations its type supports. `total.contains('5')` and `name.gt(5)` both
// fail to compile; the alternative is a parameter the server rejects at run
// time.

/// A `bit` column. Comparable and nothing else.
class MssqlBoolColumn extends MssqlTypedColumn<bool> {
  /// A column written out in full, for a hand-written schema.
  MssqlBoolColumn(super.quoted, super.name, {super.columnType});

  MssqlBoolColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();

  /// `= 1`, spelled the way the reader thinks about it.
  MssqlCondition isTrue() => eq(true);
  MssqlCondition isFalse() => eq(false);
}

/// An integer column.
class MssqlIntColumn extends MssqlTypedColumn<int> with MssqlNumericExpression {
  /// A column written out in full, for a hand-written schema.
  MssqlIntColumn(super.quoted, super.name, {super.columnType});

  MssqlIntColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();
}

/// A `real`/`float` column.
class MssqlDoubleColumn extends MssqlTypedColumn<double>
    with MssqlNumericExpression {
  /// A column written out in full, for a hand-written schema.
  MssqlDoubleColumn(super.quoted, super.name, {super.columnType});

  MssqlDoubleColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();
}

/// A `decimal`, `numeric`, `money` or `smallmoney` column.
class MssqlDecimalColumn extends MssqlTypedColumn<MssqlDecimal>
    with MssqlNumericExpression {
  /// A column written out in full, for a hand-written schema.
  MssqlDecimalColumn(super.quoted, super.name, {super.columnType});

  MssqlDecimalColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();
}

/// A character column.
///
/// The one family that carries the text predicates. They are here rather than
/// on every expression so that a numeric or temporal column simply does not
/// have them.
class MssqlStringColumn extends MssqlTypedColumn<String>
    with MssqlTextExpression {
  /// A column written out in full, for a hand-written schema.
  MssqlStringColumn(super.quoted, super.name, {super.columnType});

  MssqlStringColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();
}

/// A `date`, `datetime`, `datetime2` or `smalldatetime` column.
class MssqlDateTimeColumn extends MssqlTypedColumn<DateTime>
    with MssqlTemporalExpression {
  /// A column written out in full, for a hand-written schema.
  MssqlDateTimeColumn(super.quoted, super.name, {super.columnType});

  MssqlDateTimeColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();
}

/// A `time` column, read as an offset from midnight.
class MssqlTimeColumn extends MssqlTypedColumn<Duration>
    with MssqlTemporalExpression {
  /// A column written out in full, for a hand-written schema.
  MssqlTimeColumn(super.quoted, super.name, {super.columnType});

  MssqlTimeColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();
}

/// A `datetimeoffset`, or a `datetime2(7)`/`time(7)` that keeps its 100 ns.
class MssqlDateTimeValueColumn extends MssqlTypedColumn<MssqlDateTimeValue>
    with MssqlTemporalExpression {
  /// A column written out in full, for a hand-written schema.
  MssqlDateTimeValueColumn(super.quoted, super.name, {super.columnType});

  MssqlDateTimeValueColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();
}

/// A `uniqueidentifier` column.
///
/// Supports comparison and ordering using SQL Server's GUID order. Text
/// operators such as `like` are unavailable.
class MssqlGuidColumn extends MssqlTypedColumn<String> {
  /// A column written out in full, for a hand-written schema.
  MssqlGuidColumn(super.quoted, super.name, {super.columnType});

  MssqlGuidColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();
}

/// A `binary`, `varbinary` or `image` column.
class MssqlBinaryColumn extends MssqlTypedColumn<Uint8List> {
  /// A column written out in full, for a hand-written schema.
  MssqlBinaryColumn(super.quoted, super.name, {super.columnType});

  MssqlBinaryColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
  }) : super.of();
}

/// A column whose stored value maps to a Dart enum.
///
/// The codec converts in both directions, so `status.eq(OrderStatus.open)`
/// binds whatever the database stores and `status.eq(1)` does not compile.
class MssqlEnumColumn<T extends Object> extends MssqlTypedColumn<T> {
  MssqlEnumColumn.of({
    required super.source,
    required super.name,
    required super.quotedName,
    required super.columnType,
    required this.toSql,
  }) : super.of();

  /// The stored value for a member.
  final Object Function(T value) toSql;

  @override
  MssqlExpression operand(T value, String method) {
    final typed = codec;
    final stored = toSql(value);
    return typed == null
        ? MssqlLiteral(stored)
        : MssqlTypedLiteral(stored, typed);
  }
}
