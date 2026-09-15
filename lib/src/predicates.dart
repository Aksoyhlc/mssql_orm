import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'dialect.dart';
import 'expression.dart';
import 'statement.dart';
import 'typed_column.dart';

/// Comparison operators accepted by column predicates.
enum MssqlOperator {
  eq('='),
  ne('<>'),
  lt('<'),
  lte('<='),
  gt('>'),
  gte('>=');

  const MssqlOperator(this.sql);
  final String sql;
}

/// Compares two columns using [operator].
MssqlCondition whereColumn(String left, MssqlOperator operator, String right) =>
    MssqlComparison(Col(left), operator.sql, Col(right));

/// `NOT BETWEEN`.
@immutable
class MssqlNotBetween extends MssqlCondition {
  const MssqlNotBetween(this.operand, this.lower, this.upper);

  final MssqlExpression operand;
  final Object? lower;
  final Object? upper;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      '${operand.compile(parameters, dialect)} NOT BETWEEN '
      '${parameters.bind(lower)} AND ${parameters.bind(upper)}';
}

/// `BETWEEN` with expression bounds.
@immutable
class MssqlBetweenColumns extends MssqlCondition {
  const MssqlBetweenColumns(
    this.operand,
    this.lower,
    this.upper, {
    required this.negated,
  });

  final MssqlExpression operand;
  final MssqlExpression lower;
  final MssqlExpression upper;
  final bool negated;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      '${operand.compile(parameters, dialect)} '
      '${negated ? 'NOT ' : ''}BETWEEN '
      '${lower.compile(parameters, dialect)} AND '
      '${upper.compile(parameters, dialect)}';
}

/// Date or time component used by comparison helpers.
enum MssqlDatePart {
  /// The date alone, with the time discarded.
  date,
  year,
  month,
  day,

  /// The time of day, with the date discarded.
  time,
}

/// Compares a part of a date column to a value.
@immutable
class MssqlDatePartComparison extends MssqlCondition {
  const MssqlDatePartComparison(
    this.operand,
    this.part,
    this.operator,
    this.value,
  );

  final MssqlExpression operand;
  final MssqlDatePart part;
  final MssqlOperator operator;
  final Object? value;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final inner = operand.compile(parameters, dialect);
    // CAST to date rather than CONVERT with a style: it is the sargable form,
    // so an index on the column can still be used.
    final left = switch (part) {
      MssqlDatePart.date => 'CAST($inner AS date)',
      MssqlDatePart.time => 'CAST($inner AS time)',
      MssqlDatePart.year => 'YEAR($inner)',
      MssqlDatePart.month => 'MONTH($inner)',
      MssqlDatePart.day => 'DAY($inner)',
    };
    return '$left ${operator.sql} ${parameters.bind(_bound(value))}';
  }

  // Match the parameter type to the cast so SQL Server does not widen the
  // column and bypass its index.
  Object? _bound(Object? raw) {
    if (raw is! DateTime) return raw;
    return switch (part) {
      MssqlDatePart.date => MssqlValue.date(raw),
      MssqlDatePart.time => MssqlValue.time(raw),
      _ => raw,
    };
  }
}

/// `CAST(expression AS type)` while preserving parameter binding.
@immutable
class MssqlCast extends MssqlExpression {
  MssqlCast(this.operand, this.sqlType) {
    if (!_sqlCastType.hasMatch(sqlType)) {
      throw ArgumentError.value(
        sqlType,
        'sqlType',
        'Use a supported SQL Server scalar type with an optional size, '
            'precision or scale.',
      );
    }
  }

  final MssqlExpression operand;
  final String sqlType;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      'CAST(${operand.compile(parameters, dialect)} AS $sqlType)';
}

/// Applies a predicate to several columns and groups the results.
@immutable
class MssqlColumnGroup extends MssqlCondition {
  MssqlColumnGroup(
    Iterable<String> columns,
    this.build, {
    required this.operator,
    required this.negated,
  }) : columns = List<String>.unmodifiable(columns) {
    if (operator != 'AND' && operator != 'OR') {
      throw ArgumentError.value(operator, 'operator', 'Use AND or OR.');
    }
    if (this.columns.isEmpty) {
      throw ArgumentError.value(
        columns,
        'columns',
        'Name at least one column: an empty group has no meaning, and '
            'compiling it to a constant would hide the mistake.',
      );
    }
  }

  final List<String> columns;
  final MssqlCondition Function(MssqlColumnRef column) build;
  final String operator;
  final bool negated;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final parts = columns
        .map((c) => build(Col(c)).compile(parameters, dialect))
        .join(' $operator ');
    return negated ? 'NOT ($parts)' : '($parts)';
  }
}

final RegExp _sqlCastType = RegExp(
  r'^(?:bigint|binary|bit|char|date|datetime|datetime2|datetimeoffset|decimal|float|int|money|nchar|ntext|numeric|nvarchar|real|smalldatetime|smallint|smallmoney|text|time|tinyint|uniqueidentifier|varbinary|varchar|xml)(?:\((?:max|\d+)(?:\s*,\s*\d+)?\))?$',
  caseSensitive: false,
);

/// True when [build] holds for **any** of [columns].
///
/// ```dart
/// whereAny(['Name', 'Code', 'Note'], (c) => c.like(search))
/// ```
MssqlCondition whereAny(
  Iterable<String> columns,
  MssqlCondition Function(MssqlColumnRef column) build,
) => MssqlColumnGroup(columns, build, operator: 'OR', negated: false);

/// True when [build] holds for **every** one of [columns].
MssqlCondition whereAll(
  Iterable<String> columns,
  MssqlCondition Function(MssqlColumnRef column) build,
) => MssqlColumnGroup(columns, build, operator: 'AND', negated: false);

/// True when [build] holds for **none** of [columns].
MssqlCondition whereNone(
  Iterable<String> columns,
  MssqlCondition Function(MssqlColumnRef column) build,
) => MssqlColumnGroup(columns, build, operator: 'OR', negated: true);

/// SQL Server clock functions and their result types.
///
/// Server time avoids differences between application and database time zones.
enum MssqlServerClock {
  /// `SYSDATETIME()`: `datetime2(7)` in the server's own time zone.
  localDateTime2('SYSDATETIME()'),

  /// `SYSUTCDATETIME()`: `datetime2(7)` in UTC.
  utcDateTime2('SYSUTCDATETIME()'),

  /// `SYSDATETIMEOFFSET()`: the server's now, with its offset attached.
  ///
  /// The only one comparable with a `datetimeoffset` column without the
  /// server inventing an offset for the other side.
  localDateTimeOffset('SYSDATETIMEOFFSET()'),

  /// `GETDATE()`: `datetime`, so 3.33 ms resolution.
  localDateTime('GETDATE()'),

  /// `GETUTCDATE()`: `datetime` in UTC.
  utcDateTime('GETUTCDATE()');

  const MssqlServerClock(this.sql);

  /// The complete SQL function call.
  final String sql;
}

/// A builder-owned server clock expression.
///
/// Keeping this separate from raw SQL preserves read-retry classification.
@immutable
class MssqlServerNow extends MssqlExpression with MssqlTemporalExpression {
  const MssqlServerNow(this.clock);

  final MssqlServerClock clock;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      clock.sql;
}

/// Supported arithmetic operators.
///
/// A closed set prevents operator text from being injected into SQL.
enum MssqlArithmeticOperator {
  add('+'),
  subtract('-'),
  multiply('*'),

  /// SQL Server division; integer operands produce integer division.
  divide('/'),

  /// `%`: the remainder, for integer operands.
  modulo('%'),

  /// Bitwise exclusive or, which SQL Server spells `^`.
  bitwiseXor('^');

  const MssqlArithmeticOperator(this.sql);

  final String sql;
}

/// Arithmetic between expressions or a bound value.
///
/// SQL Server determines the result type; operands are not promoted here.
@immutable
class MssqlArithmetic extends MssqlExpression {
  const MssqlArithmetic(this.left, this.operator, this.right);

  final MssqlExpression left;
  final MssqlArithmeticOperator operator;

  /// A value to bind, or an [MssqlExpression] to compile in place.
  final Object? right;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final operand = right;
    final rendered = operand is MssqlExpression
        ? operand.compile(parameters, dialect)
        : parameters.bind(operand);
    return '(${left.compile(parameters, dialect)} ${operator.sql} $rendered)';
  }
}

/// An expression that can report its SQL result type.
abstract mixin class MssqlTypedExpression implements MssqlExpression {
  /// The SQL result type, or null when it cannot be inferred.
  MssqlColumnType? get resultType;
}

/// Caches rendered SQL for the duration of one statement.
///
/// Reused expressions retain the same parameter names in projections and
/// grouping clauses.
mixin MssqlStableExpression implements MssqlExpression {
  /// Scoped by allocator so compiled SQL cannot leak between statements.
  final Expando<String> _perStatement = Expando<String>(
    'MssqlStableExpression',
  );

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      _perStatement[parameters] ??= compileStable(parameters, dialect);

  /// Writes the SQL. Called at most once per statement.
  @protected
  String compileStable(
    MssqlParameterAllocator parameters,
    MssqlDialect dialect,
  );
}

/// Coarse SQL type families used for compatibility checks.
enum MssqlTypeFamily {
  boolean,
  integer,

  /// `decimal`, `numeric`, `money`, `smallmoney`: exact, with a scale.
  exactNumeric,

  /// `real`, `float`: binary floating point.
  approximateNumeric,
  text,
  binary,
  temporal,
  guid,
  xml,
}

/// What an expression is in SQL, as far as anything here can tell.
abstract final class MssqlSqlType {
  /// The SQL type of [expression], or null when it is not knowable.
  ///
  /// An alias is transparent: `sum(total).as('Total')` is still a `SUM`.
  static MssqlColumnType? of(MssqlExpression expression) {
    if (expression is MssqlAliased) return of(expression.expression);
    if (expression is MssqlTypedColumn<Object?>) return expression.columnType;
    if (expression is MssqlTypedExpression) return expression.resultType;
    return null;
  }

  /// [type] with its nullability set, since an aggregate over no rows is null
  /// however the column it reads was declared.
  static MssqlColumnType asNullable(MssqlColumnType type) => MssqlColumnType(
    type: type.type,
    size: type.size,
    precision: type.precision,
    scale: type.scale,
    columnName: type.columnName,
  );

  /// Which family [type] belongs to.
  static MssqlTypeFamily familyOf(MssqlType type) => switch (type) {
    MssqlType.bit => MssqlTypeFamily.boolean,
    MssqlType.tinyInt ||
    MssqlType.smallInt ||
    MssqlType.int32 ||
    MssqlType.int64 => MssqlTypeFamily.integer,
    MssqlType.decimal ||
    MssqlType.numeric ||
    MssqlType.money ||
    MssqlType.smallMoney => MssqlTypeFamily.exactNumeric,
    MssqlType.real || MssqlType.float64 => MssqlTypeFamily.approximateNumeric,
    MssqlType.char ||
    MssqlType.varchar ||
    MssqlType.nchar ||
    MssqlType.nvarchar ||
    MssqlType.text ||
    MssqlType.ntext => MssqlTypeFamily.text,
    MssqlType.binary ||
    MssqlType.varbinary ||
    MssqlType.image => MssqlTypeFamily.binary,
    MssqlType.date ||
    MssqlType.time ||
    MssqlType.smallDateTime ||
    MssqlType.dateTime ||
    MssqlType.dateTime2 ||
    MssqlType.dateTimeOffset => MssqlTypeFamily.temporal,
    MssqlType.uniqueIdentifier => MssqlTypeFamily.guid,
    MssqlType.xml => MssqlTypeFamily.xml,
  };
}

/// Binds a calendar boundary using the operand's SQL type.
///
/// Matching the parameter type prevents SQL Server from widening an indexed
/// date column during comparison.
MssqlValue _calendarBound(
  MssqlExpression operand,
  DateTime instant,
  Duration? zoneOffset,
) {
  final type = MssqlSqlType.of(operand);
  final sqlType = type?.type;
  if (sqlType != null &&
      MssqlSqlType.familyOf(sqlType) != MssqlTypeFamily.temporal) {
    throw ArgumentError.value(
      operand,
      'operand',
      'a calendar range needs a date or datetime column, and '
          '${type!.columnName ?? 'this expression'} is $sqlType. Compare a '
          'number with between() instead.',
    );
  }
  if (sqlType == MssqlType.time) {
    throw ArgumentError.value(
      operand,
      'operand',
      'a time column carries no date, so a year or a day is not a range on '
          'it. Use whereTime() to compare the time of day.',
    );
  }
  if (sqlType == MssqlType.dateTimeOffset) {
    if (zoneOffset == null) {
      throw ArgumentError.value(
        operand,
        'operand',
        'a datetimeoffset column stores an offset, so "the year 2026" is not '
            'one range until someone says whose calendar it is: 2026 in '
            '+03:00 starts three hours before 2026 in UTC. Pass '
            'zoneOffset: Duration(hours: 3) — or whatever the report means by '
            'a day — rather than letting the server compare an offset value '
            'against a bound with no offset, which it resolves by assuming '
            'the parameter is UTC.',
      );
    }
    return MssqlValue.dateTimeOffset(
      MssqlDateTimeValue(
        year: instant.year,
        month: instant.month,
        day: instant.day,
        timezoneOffsetMinutes: zoneOffset.inMinutes,
      ),
      scale: type == null || type.scale < 0 || type.scale > 7 ? 7 : type.scale,
    );
  }
  if (zoneOffset != null) {
    throw ArgumentError.value(
      zoneOffset,
      'zoneOffset',
      sqlType == null
          ? 'nothing here knows what this column is, so an offset cannot be '
                'attached to the bound: an untyped Col() carries no SQL type. '
                'Compare a generated datetimeoffset column, which does.'
          : 'only a datetimeoffset column carries an offset, and $sqlType '
                'does not. An offset passed here would be dropped on the way '
                'to the server, so it is refused instead.',
    );
  }
  final column = operand is MssqlTypedColumn<Object?> ? operand : null;
  final codec = column?.codec;
  if (codec != null) return codec.encode(instant);
  // An untyped Col names a column nothing here has metadata for. datetime2 is
  // the widest of the date types and orders the same way as the rest, so the
  // comparison is still correct; it is the typed path that also keeps the
  // parameter exactly what the column is.
  return MssqlValue.dateTime2(instant);
}

/// An index-friendly half-open calendar range.
///
/// The exclusive upper bound avoids type-specific “last instant” values and
/// keeps the indexed column unwrapped.
@immutable
class MssqlCalendarRange extends MssqlCondition {
  MssqlCalendarRange(
    this.operand, {
    required this.start,
    required this.endExclusive,
    this.operator = MssqlOperator.eq,
    this.zoneOffset,
  }) : _lower = _calendarBound(operand, start, zoneOffset),
       _upper = _calendarBound(operand, endExclusive, zoneOffset) {
    if (!endExclusive.isAfter(start)) {
      throw ArgumentError.value(
        endExclusive,
        'endExclusive',
        'must be after start ($start); an empty range matches nothing and '
            'says so only by returning no rows.',
      );
    }
  }

  final MssqlExpression operand;

  /// The first instant in the range, included.
  final DateTime start;

  /// The first instant after the range, excluded.
  final DateTime endExclusive;

  /// Which side of the range is being asked about.
  final MssqlOperator operator;

  /// Calendar offset for a `datetimeoffset` operand.
  final Duration? zoneOffset;

  final MssqlValue _lower;
  final MssqlValue _upper;

  // Inclusive comparisons use the opposite edge of the half-open interval.
  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final left = operand.compile(parameters, dialect);
    return switch (operator) {
      MssqlOperator.eq =>
        '($left >= ${parameters.bind(_lower)} AND '
            '$left < ${parameters.bind(_upper)})',
      // NULL rows match neither side, exactly as they do not match `<>`.
      MssqlOperator.ne =>
        '($left < ${parameters.bind(_lower)} OR '
            '$left >= ${parameters.bind(_upper)})',
      MssqlOperator.lt => '$left < ${parameters.bind(_lower)}',
      MssqlOperator.lte => '$left < ${parameters.bind(_upper)}',
      MssqlOperator.gt => '$left >= ${parameters.bind(_upper)}',
      MssqlOperator.gte => '$left >= ${parameters.bind(_lower)}',
    };
  }
}

/// Calendar boundaries supported by [MssqlDateTruncate].
///
/// Weeks require an explicit bucket origin, while second-based truncation can
/// overflow SQL Server's `DATEDIFF` integer range.
enum MssqlTemporalGrain {
  year('year', wholeDays: true),
  quarter('quarter', wholeDays: true),
  month('month', wholeDays: true),
  day('day', wholeDays: true),
  hour('hour', wholeDays: false),
  minute('minute', wholeDays: false);

  const MssqlTemporalGrain(this.datePart, {required this.wholeDays});

  /// SQL Server `datepart` keyword.
  final String datePart;

  /// Whether snapping to this grain always lands on midnight, and so can be
  /// narrowed to a `date`.
  final bool wholeDays;
}

/// Snaps a temporal expression to a calendar boundary.
///
/// Uses the broadly compatible `DATEADD`/`DATEDIFF` form and remains stable
/// when reused in projections and grouping clauses.
@immutable
class MssqlDateTruncate extends MssqlExpression
    with MssqlTemporalExpression, MssqlStableExpression
    implements MssqlTypedExpression {
  MssqlDateTruncate(this.operand, this.grain);

  final MssqlExpression operand;
  final MssqlTemporalGrain grain;

  /// `date` for whole-day grains and `datetime` otherwise.
  @override
  MssqlColumnType get resultType => grain.wholeDays
      ? const MssqlColumnType(type: MssqlType.date)
      : const MssqlColumnType(type: MssqlType.dateTime);

  @override
  String compileStable(
    MssqlParameterAllocator parameters,
    MssqlDialect dialect,
  ) {
    final inner = operand.compile(parameters, dialect);
    final part = grain.datePart;
    final snapped = 'DATEADD($part, DATEDIFF($part, 0, $inner), 0)';
    return grain.wholeDays ? 'CAST($snapped AS date)' : snapped;
  }
}

/// The width unit of a [MssqlDateBucket].
enum MssqlDateBucketUnit {
  year('year'),
  quarter('quarter'),
  month('month'),
  week('week'),
  day('day'),
  hour('hour'),
  minute('minute'),
  second('second');

  const MssqlDateBucketUnit(this.datePart);

  /// SQL Server `datepart` keyword.
  final String datePart;
}

/// Fixed-width `DATE_BUCKET` groups from an optional origin.
///
/// Requires SQL Server 2022 at compatibility level 160. No fallback is used
/// because alternate arithmetic can produce different boundaries.
@immutable
class MssqlDateBucket extends MssqlExpression
    with MssqlTemporalExpression, MssqlStableExpression
    implements MssqlTypedExpression {
  MssqlDateBucket(
    this.operand, {
    required this.unit,
    required this.width,
    this.origin,
    this.zoneOffset,
  }) {
    if (width < 1) {
      throw ArgumentError.value(
        width,
        'width',
        'a bucket is at least one ${unit.datePart} wide.',
      );
    }
  }

  final MssqlExpression operand;
  final MssqlDateBucketUnit unit;

  /// How many [unit]s one bucket spans.
  final int width;

  /// Where the counting starts. Null leaves SQL Server's 1900-01-01.
  final DateTime? origin;

  /// The offset [origin] is read in, for a `datetimeoffset` operand.
  final Duration? zoneOffset;

  /// The operand's own type: `DATE_BUCKET` returns what it was given.
  @override
  MssqlColumnType? get resultType => MssqlSqlType.of(operand);

  @override
  String compileStable(
    MssqlParameterAllocator parameters,
    MssqlDialect dialect,
  ) {
    dialect.require(
      dialect.supportsDateBucket,
      feature: 'dateBucket()',
      requires:
          'SQL Server 2022 or newer, at database compatibility level 160 or '
          'higher. For an older target, group by truncatedTo() or '
          'monthStart(), which snap to a calendar boundary with '
          'DATEADD/DATEDIFF and need no version at all',
    );
    final inner = operand.compile(parameters, dialect);
    final at = origin;
    // SQL Server requires the origin and operand to have matching types.
    final from = at == null
        ? ''
        : ', ${parameters.bind(_calendarBound(operand, at, zoneOffset))}';
    return 'DATE_BUCKET(${unit.datePart}, ${parameters.bind(width)}, '
        '$inner$from)';
  }
}

/// The unit `DATEDIFF` counts in.
enum MssqlDateDiffUnit {
  year('year'),
  quarter('quarter'),
  month('month'),
  week('week'),
  day('day'),
  hour('hour'),
  minute('minute'),

  /// Can overflow after roughly 68 years because `DATEDIFF` returns `int`.
  second('second');

  const MssqlDateDiffUnit(this.datePart);

  /// SQL Server `datepart` keyword.
  final String datePart;
}

/// Counts [unit] boundaries between two temporal expressions.
///
/// This follows SQL Server boundary semantics, not elapsed duration.
@immutable
class MssqlDateDiff extends MssqlExpression
    with MssqlNumericExpression
    implements MssqlTypedExpression {
  const MssqlDateDiff(this.unit, this.start, this.end);

  final MssqlDateDiffUnit unit;
  final MssqlExpression start;
  final MssqlExpression end;

  /// `int`, and nullable: either end being null makes the difference null.
  @override
  MssqlColumnType get resultType =>
      const MssqlColumnType(type: MssqlType.int32);

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) =>
      'DATEDIFF(${unit.datePart}, ${start.compile(parameters, dialect)}, '
      '${end.compile(parameters, dialect)})';
}

/// One `WHEN … THEN …` of a [MssqlCase].
@immutable
class MssqlCaseBranch {
  const MssqlCaseBranch(this.when, this.then);

  final MssqlCondition when;
  final MssqlExpression then;
}

/// A searched `CASE WHEN … THEN … ELSE … END` expression.
///
/// Searched form also supports explicit null conditions.
@immutable
class MssqlCase extends MssqlExpression implements MssqlTypedExpression {
  MssqlCase(Iterable<MssqlCaseBranch> branches, {this.otherwise, this.type})
    : branches = List<MssqlCaseBranch>.unmodifiable(branches) {
    if (this.branches.isEmpty) {
      throw ArgumentError.value(
        branches,
        'branches',
        'a CASE needs at least one WHEN. With none it is either its ELSE or '
            'nothing at all, and both are clearer written directly.',
      );
    }
  }

  final List<MssqlCaseBranch> branches;

  /// The `ELSE`. Omitted, SQL Server's own `ELSE NULL` applies, which is why
  /// [resultType] is nullable whenever this is null.
  final MssqlExpression? otherwise;

  /// Caller-declared result type; null when SQL precedence must decide it.
  final MssqlColumnType? type;

  @override
  MssqlColumnType? get resultType {
    final declared = type;
    if (declared == null) return null;
    return otherwise == null ? MssqlSqlType.asNullable(declared) : declared;
  }

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final out = StringBuffer('CASE');
    for (final branch in branches) {
      out.write(' WHEN ${branch.when.compile(parameters, dialect)}');
      out.write(' THEN ${branch.then.compile(parameters, dialect)}');
    }
    final fallback = otherwise;
    if (fallback != null) {
      out.write(' ELSE ${fallback.compile(parameters, dialect)}');
    }
    out.write(' END');
    return out.toString();
  }
}

/// Returns the first non-null operand using SQL type precedence.
///
/// Unlike `ISNULL`, the result type is not fixed to the first operand.
@immutable
class MssqlCoalesce extends MssqlExpression {
  MssqlCoalesce(Iterable<MssqlExpression> operands)
    : operands = List<MssqlExpression>.unmodifiable(operands) {
    if (this.operands.length < 2) {
      throw ArgumentError.value(
        operands,
        'operands',
        'COALESCE needs at least two operands; with one it is that operand.',
      );
    }
  }

  final List<MssqlExpression> operands;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final parts = operands.map((o) => o.compile(parameters, dialect));
    return 'COALESCE(${parts.join(', ')})';
  }
}
