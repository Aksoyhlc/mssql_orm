import 'package:mssql_native/mssql_native.dart';

import 'expression.dart';
import 'predicates.dart';
import 'typed_column.dart';
import 'window.dart';

/// The comparison and predicate operators, on any expression.
///
/// They hang off [MssqlExpression] rather than off columns alone so that an
/// aggregate can be compared too: `having(sum(Col('Total')).gt(1000))`.
extension MssqlExpressionOperators on MssqlExpression {
  MssqlCondition eq(Object? value) =>
      MssqlComparison(this, '=', _operand(value, 'eq'));
  MssqlCondition ne(Object? value) =>
      MssqlComparison(this, '<>', _operand(value, 'ne'));
  MssqlCondition lt(Object? value) =>
      MssqlComparison(this, '<', _operand(value, 'lt'));
  MssqlCondition lte(Object? value) =>
      MssqlComparison(this, '<=', _operand(value, 'lte'));
  MssqlCondition gt(Object? value) =>
      MssqlComparison(this, '>', _operand(value, 'gt'));
  MssqlCondition gte(Object? value) =>
      MssqlComparison(this, '>=', _operand(value, 'gte'));

  /// Compares this expression to another column rather than to a value.
  MssqlCondition eqCol(String identifier) =>
      MssqlComparison(this, '=', Col(identifier));

  /// Compares this expression to another expression.
  MssqlCondition eqExpr(MssqlExpression other) =>
      MssqlComparison(this, '=', other);

  MssqlCondition isNull() => MssqlNullCheck(this, negated: false);
  MssqlCondition isNotNull() => MssqlNullCheck(this, negated: true);

  MssqlCondition inList(Iterable<Object?> values) =>
      MssqlInList(this, values, negated: false);
  MssqlCondition notInList(Iterable<Object?> values) =>
      MssqlInList(this, values, negated: true);

  MssqlCondition between(Object? lower, Object? upper) =>
      MssqlBetween(this, lower, upper);

  /// Gives this expression a result alias.
  MssqlAliased as(String alias) => MssqlAliased(this, alias);

  /// Orders by this expression, ascending.
  MssqlOrder asc({MssqlNulls? nulls}) =>
      MssqlOrder(this, descending: false, nulls: nulls);

  /// Orders by this expression, descending.
  MssqlOrder desc({MssqlNulls? nulls}) =>
      MssqlOrder(this, descending: true, nulls: nulls);

  MssqlCondition notBetween(Object? lower, Object? upper) =>
      MssqlNotBetween(this, lower, upper);

  /// `BETWEEN` two other columns rather than two values.
  MssqlCondition betweenColumns(String lower, String upper) =>
      MssqlBetweenColumns(this, Col(lower), Col(upper), negated: false);

  MssqlCondition notBetweenColumns(String lower, String upper) =>
      MssqlBetweenColumns(this, Col(lower), Col(upper), negated: true);

  /// Compares the date alone, so the whole day matches rather than midnight.
  MssqlCondition whereDate(
    Object? value, [
    MssqlOperator operator = MssqlOperator.eq,
  ]) => MssqlDatePartComparison(this, MssqlDatePart.date, operator, value);

  /// Compares the time of day, with the date discarded.
  MssqlCondition whereTime(
    Object? value, [
    MssqlOperator operator = MssqlOperator.eq,
  ]) => MssqlDatePartComparison(this, MssqlDatePart.time, operator, value);

  MssqlCondition whereYear(
    int value, [
    MssqlOperator operator = MssqlOperator.eq,
  ]) => MssqlDatePartComparison(this, MssqlDatePart.year, operator, value);

  MssqlCondition whereMonth(
    int value, [
    MssqlOperator operator = MssqlOperator.eq,
  ]) => MssqlDatePartComparison(this, MssqlDatePart.month, operator, value);

  MssqlCondition whereDay(
    int value, [
    MssqlOperator operator = MssqlOperator.eq,
  ]) => MssqlDatePartComparison(this, MssqlDatePart.day, operator, value);

  /// The date part equals today, as the *server* reckons it.
  ///
  /// `CAST(GETDATE() AS date)` rather than a Dart `DateTime.now()`: the
  /// application and the database can sit in different time zones, and a
  /// report that says "today" means the server's today.
  MssqlCondition whereToday() => _relativeToToday('=');
  MssqlCondition whereBeforeToday() => _relativeToToday('<');
  MssqlCondition whereAfterToday() => _relativeToToday('>');
  MssqlCondition whereTodayOrBefore() => _relativeToToday('<=');
  MssqlCondition whereTodayOrAfter() => _relativeToToday('>=');

  /// Strictly earlier than now, again by the server's clock.
  MssqlCondition wherePast() => _relativeToNow('<');
  MssqlCondition whereFuture() => _relativeToNow('>');
  MssqlCondition whereNowOrPast() => _relativeToNow('<=');
  MssqlCondition whereNowOrFuture() => _relativeToNow('>=');

  MssqlCondition _relativeToNow(String operator) => MssqlComparison(
    this,
    operator,
    const MssqlServerNow(MssqlServerClock.localDateTime2),
  );

  MssqlCondition _relativeToToday(String operator) => MssqlComparison(
    MssqlCast(this, 'date'),
    operator,
    MssqlCast(const MssqlServerNow(MssqlServerClock.localDateTime), 'date'),
  );
}

/// Rejects a bare `null` operand.
///
/// The driver's own `inferMssqlValue` refuses a bare null because it cannot
/// know the SQL type, and SQL's `= NULL` never matches anything, so accepting
/// one here would mean either an error further down or a silent change of
/// meaning. Null tests are written `isNull()` / `isNotNull()`.
MssqlExpression _operand(Object? value, String method) {
  if (value == null) {
    throw ArgumentError.value(
      value,
      'value',
      '$method(null) is not a null test: SQL\'s "= NULL" never matches. '
          'Use isNull() or isNotNull().',
    );
  }
  if (value is MssqlExpression) return value;
  return MssqlLiteral(value);
}

/// Where SQL Server should put NULLs relative to other values.
///
/// SQL Server has no `NULLS FIRST` / `NULLS LAST` syntax. The default treats
/// NULL as the lowest value, so `ASC` is nulls first and `DESC` is nulls
/// last. An explicit value compiles to a `CASE` ahead of the real term.
enum MssqlNulls { first, last }

/// One term of an `ORDER BY`.
class MssqlOrder {
  const MssqlOrder(this.expression, {required this.descending, this.nulls});

  final MssqlExpression expression;
  final bool descending;

  /// Null keeps SQL Server's own rule (NULL is lowest).
  final MssqlNulls? nulls;

  /// Same term with NULLs before every other value.
  MssqlOrder get nullsFirst =>
      MssqlOrder(expression, descending: descending, nulls: MssqlNulls.first);

  /// Same term with NULLs after every other value.
  MssqlOrder get nullsLast =>
      MssqlOrder(expression, descending: descending, nulls: MssqlNulls.last);
}

/// [orderBy] with the columns of [keyColumns] appended, skipping any the
/// ordering already names.
///
/// A unique tie-breaker is what makes a page or a per-parent window
/// deterministic, and appending the key blindly is not it: an ordering that
/// already says `[Id] DESC` becomes `ORDER BY [Id] DESC, [Id] ASC`, where the
/// second term can never be reached — so the ordering claims a tie-break it
/// does not have. Worse for a keyset cursor, whose lexicographic predicate is
/// built term by term from this list: a column appearing twice with opposite
/// directions yields `[Id] < @a AND … [Id] > @a`, which matches nothing.
///
/// Comparison is by column name, folded, because that is what SQL Server
/// compares; an expression that is not a plain column cannot be recognised as
/// the key and is left alone.
List<MssqlOrder> mssqlWithKeyTieBreak(
  List<MssqlOrder> orderBy,
  List<String> keyColumns,
) {
  if (keyColumns.isEmpty) return orderBy;
  final named = <String>{};
  for (final order in orderBy) {
    final expression = order.expression;
    if (expression is MssqlColumnBase) named.add(expression.name.toLowerCase());
  }
  final missing = <String>[
    for (final name in keyColumns)
      if (!named.contains(name.toLowerCase())) name,
  ];
  if (missing.isEmpty) return orderBy;
  return <MssqlOrder>[...orderBy, for (final name in missing) Col(name).asc()];
}

/// `SUM(x)`, carrying SQL Server's own result type; see [MssqlAggregate.sum].
MssqlAggregate sum(MssqlExpression operand) => MssqlAggregate.sum(operand);

/// `AVG(x)`.
///
/// [integers] has to be given when the operand is a known integer column,
/// because SQL Server's answer there is integer division; see
/// [MssqlIntegerAverage].
MssqlAggregate avg(
  MssqlExpression operand, {
  MssqlIntegerAverage? integers,
  int exactScale = 6,
}) => MssqlAggregate.avg(operand, integers: integers, exactScale: exactScale);

MssqlAggregate min(MssqlExpression operand) => MssqlAggregate.min(operand);
MssqlAggregate max(MssqlExpression operand) => MssqlAggregate.max(operand);

/// `COUNT(x)`, or `COUNT(DISTINCT x)` when [distinct].
///
/// One expression when [distinct], because that is SQL Server's own limit on
/// `COUNT(DISTINCT …)`. A composite key is counted through
/// `MssqlQuery.countDistinct`, which routes it via a derived `SELECT
/// DISTINCT` rather than quietly counting the first column.
MssqlAggregate count(MssqlExpression operand, {bool distinct = false}) =>
    MssqlAggregate.count(operand, distinct: distinct);

/// `COUNT(*)`, or `COUNT_BIG(*)` when [big].
MssqlExpression countAll({bool big = false}) => MssqlCountAll(big: big);

/// `DATEDIFF(unit, start, end)`: the number of [unit] boundaries between two
/// temporal expressions.
MssqlExpression dateDiff(
  MssqlDateDiffUnit unit,
  MssqlTemporalExpression start,
  MssqlTemporalExpression end,
) => MssqlDateDiff(unit, start, end);

/// `CASE WHEN … THEN … ELSE … END`.
///
/// [type] states what the result is in SQL, for a projection that has to
/// decode it. It is optional because SQL Server resolves a `CASE` by type
/// precedence across every branch, which this does not try to reimplement.
MssqlExpression caseWhen(
  Iterable<MssqlCaseBranch> branches, {
  MssqlExpression? otherwise,
  MssqlColumnType? type,
}) => MssqlCase(branches, otherwise: otherwise, type: type);

/// `COALESCE(a, b, …)`: the first operand that is not null.
MssqlExpression coalesce(Iterable<MssqlExpression> operands) =>
    MssqlCoalesce(operands);

/// The text predicates, on expressions whose SQL type is text.
///
/// Not on every expression: `total.contains('5')` would ask SQL Server to
/// `LIKE` a `decimal`, which either converts the column or fails. A generated
/// numeric column therefore does not have these, while an untyped `Col('Name')`
/// still does, since nothing is known about it.
extension MssqlTextOperators on MssqlTextExpression {
  /// `LIKE`, with `%`, `_` and `[` in [pattern] treated as literal text.
  ///
  /// This is the safe reading, so it is the unnamed one: a `%` typed into a
  /// search box matches a `%`. Use [likeRaw] for wildcard semantics.
  MssqlCondition like(String pattern) =>
      MssqlLike(this, pattern, negated: false, escaped: true);
  MssqlCondition notLike(String pattern) =>
      MssqlLike(this, pattern, negated: true, escaped: true);

  /// `LIKE '%term%'`, with [term] escaped.
  ///
  /// What a search box needs. [like] is an exact match — it escapes the term,
  /// so `like('%ali%')` looks for a literal `%ali%` — and [likeRaw] would let
  /// a `%` the user typed become a wildcard. This is the safe middle: the term
  /// stays literal, the wildcards are ours.
  MssqlCondition contains(String term) => MssqlLike(
    this,
    term,
    negated: false,
    escaped: true,
    position: MssqlLikePosition.anywhere,
  );

  MssqlCondition notContains(String term) => MssqlLike(
    this,
    term,
    negated: true,
    escaped: true,
    position: MssqlLikePosition.anywhere,
  );

  /// `LIKE 'term%'`, with [term] escaped.
  MssqlCondition startsWith(String term) => MssqlLike(
    this,
    term,
    negated: false,
    escaped: true,
    position: MssqlLikePosition.starting,
  );

  /// `LIKE '%term'`, with [term] escaped.
  MssqlCondition endsWith(String term) => MssqlLike(
    this,
    term,
    negated: false,
    escaped: true,
    position: MssqlLikePosition.ending,
  );

  /// `LIKE` with [pattern] passed through unescaped, wildcards and all.
  MssqlCondition likeRaw(String pattern) =>
      MssqlLike(this, pattern, negated: false, escaped: false);
  MssqlCondition notLikeRaw(String pattern) =>
      MssqlLike(this, pattern, negated: true, escaped: false);
}

/// The date and time expressions, on expressions whose SQL type is temporal.
///
/// Not on every expression, for the same reason the text predicates are not:
/// `total.inYear(2026)` would compile and then ask SQL Server to compare a
/// `decimal` against a date. A generated numeric column simply does not have
/// these; an untyped `Col('CreatedAt')` does, because untyped means nothing
/// here knows enough to refuse.
extension MssqlTemporalOperators on MssqlTemporalExpression {
  /// Every row whose value falls in [year], as a half-open range.
  ///
  /// The sargable form: `[CreatedAt] >= @start AND [CreatedAt] < @end` leaves
  /// the column bare, so an index on it can still be seeked. [whereYear] asks
  /// the same question as `YEAR([CreatedAt]) = 2026`, which hides the column
  /// from its own index — and which is still the only way to ask for a year
  /// *in the offset a `datetimeoffset` column stored*, rather than in a
  /// calendar the caller names. That is why both exist.
  ///
  /// [operator] chooses which boundary is meant: `lt` is before the year,
  /// `lte` is up to the end of it, `gt` is after it, `gte` is from its start.
  ///
  /// [zoneOffset] is required for a `datetimeoffset` column and refused for
  /// every other: a calendar year is not one range on that type until the
  /// offset is stated.
  MssqlCondition inYear(
    int year, {
    MssqlOperator operator = MssqlOperator.eq,
    Duration? zoneOffset,
  }) {
    if (year < 1 || year > 9999) {
      throw ArgumentError.value(
        year,
        'year',
        'SQL Server dates run from year 1 to year 9999.',
      );
    }
    return MssqlCalendarRange(
      this,
      start: DateTime(year),
      // DateTime(year + 1) rather than adding 365 days: the calendar
      // constructor normalises, and adding a duration to a local DateTime
      // lands an hour out either side of a daylight-saving boundary.
      endExclusive: DateTime(year + 1),
      operator: operator,
      zoneOffset: zoneOffset,
    );
  }

  /// Every row whose value falls on the calendar day [day], as a half-open
  /// range.
  ///
  /// The time of day in [day] is ignored: it names a day, and the range runs
  /// from its midnight to the next. See [inYear] for [operator] and
  /// [zoneOffset].
  MssqlCondition onDate(
    DateTime day, {
    MssqlOperator operator = MssqlOperator.eq,
    Duration? zoneOffset,
  }) => MssqlCalendarRange(
    this,
    start: DateTime(day.year, day.month, day.day),
    endExclusive: DateTime(day.year, day.month, day.day + 1),
    operator: operator,
    zoneOffset: zoneOffset,
  );

  /// This value snapped back to the start of its [grain].
  ///
  /// The same descriptor goes into the `SELECT` list and the `GROUP BY`, and
  /// compiles to identical SQL in both, which is what ties the two together.
  MssqlExpression truncatedTo(MssqlTemporalGrain grain) =>
      MssqlDateTruncate(this, grain);

  /// This value snapped back to the first day of its month, as a `date`.
  ///
  /// The axis of every monthly report, and named because that is what it is
  /// called; it is [truncatedTo] with [MssqlTemporalGrain.month].
  MssqlExpression monthStart() =>
      MssqlDateTruncate(this, MssqlTemporalGrain.month);

  /// This value snapped back to a fixed-width bucket: `DATE_BUCKET`.
  ///
  /// For the widths a calendar boundary cannot express — ten minutes,
  /// fortnights, a week that starts on the day the business says it does.
  /// Needs SQL Server 2022; the refusal names the function and the version.
  MssqlExpression dateBucket({
    required MssqlDateBucketUnit unit,
    required int width,
    DateTime? origin,
    Duration? zoneOffset,
  }) => MssqlDateBucket(
    this,
    unit: unit,
    width: width,
    origin: origin,
    zoneOffset: zoneOffset,
  );
}
