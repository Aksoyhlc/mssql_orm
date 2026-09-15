import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'dialect.dart';
import 'expression.dart';
import 'operators.dart';
import 'predicates.dart';
import 'statement.dart';

/// Aggregate functions emitted by the query builder.
enum MssqlAggregateFunction {
  sum('SUM'),
  avg('AVG'),
  min('MIN'),
  max('MAX'),
  count('COUNT'),

  /// `COUNT_BIG`, which returns `bigint` instead of `int`.
  countBig('COUNT_BIG');

  const MssqlAggregateFunction(this.sql);

  final String sql;
}

/// Controls how `AVG` handles integer operands.
enum MssqlIntegerAverage {
  /// `AVG(CAST(x AS decimal(38, s)))`: an exact average with a scale.
  exactDecimal,

  /// Keeps SQL Server integer division and discards the remainder.
  truncating,
}

/// An aggregate expression, optionally evaluated over a window.
///
/// [resultType] records the SQL type without forcing Dart numeric constraints.
@immutable
class MssqlAggregate extends MssqlExpression implements MssqlTypedExpression {
  const MssqlAggregate._({
    required this.function,
    required this.operand,
    required this.resultType,
    required this.distinct,
    required this.window,
  });

  /// `SUM(x)`.
  ///
  /// The result follows the operand type and does not widen automatically.
  factory MssqlAggregate.sum(
    MssqlExpression operand, {
    bool distinct = false,
  }) => MssqlAggregate._(
    function: MssqlAggregateFunction.sum,
    operand: operand,
    resultType: _numericResult(operand, 'sum()'),
    distinct: distinct,
    window: null,
  );

  /// `AVG(x)`.
  ///
  /// Integer operands require an explicit [integers] policy.
  factory MssqlAggregate.avg(
    MssqlExpression operand, {
    MssqlIntegerAverage? integers,
    int exactScale = 6,
    bool distinct = false,
  }) {
    final declared = MssqlSqlType.of(operand);
    final family = declared == null
        ? null
        : MssqlSqlType.familyOf(declared.type);
    if (family == MssqlTypeFamily.integer && integers == null) {
      throw ArgumentError.value(
        operand,
        'operand',
        'avg() over the integer column '
            '${declared!.columnName ?? 'in this expression'} is integer '
            'division on SQL Server: 3 and 4 average to 3, and the result is '
            'an int. Pass integers: MssqlIntegerAverage.exactDecimal to '
            'average as decimal(38, exactScale), or '
            'MssqlIntegerAverage.truncating to say the truncation is what '
            'the report means.',
      );
    }
    if (integers != null &&
        family != null &&
        family != MssqlTypeFamily.integer) {
      throw ArgumentError.value(
        integers,
        'integers',
        'only an integer column averages by integer division, and '
            '${declared!.type} does not. Drop the argument: it would suggest '
            'a rounding that is not happening.',
      );
    }
    if (integers == MssqlIntegerAverage.exactDecimal) {
      if (exactScale < 0 || exactScale > 38) {
        throw ArgumentError.value(
          exactScale,
          'exactScale',
          'SQL Server accepts a scale of 0 to 38.',
        );
      }
      return MssqlAggregate._(
        function: MssqlAggregateFunction.avg,
        // Cast before averaging; casting the result would preserve truncation.
        operand: MssqlCast(operand, 'decimal(38, $exactScale)'),
        resultType: MssqlColumnType(
          type: MssqlType.decimal,
          precision: 38,
          scale: exactScale,
        ),
        distinct: distinct,
        window: null,
      );
    }
    return MssqlAggregate._(
      function: MssqlAggregateFunction.avg,
      operand: operand,
      resultType: _numericResult(operand, 'avg()'),
      distinct: distinct,
      window: null,
    );
  }

  /// `MIN(x)`, over anything SQL Server can order.
  factory MssqlAggregate.min(MssqlExpression operand) => MssqlAggregate._(
    function: MssqlAggregateFunction.min,
    operand: operand,
    resultType: _orderableResult(operand, 'min()'),
    distinct: false,
    window: null,
  );

  /// `MAX(x)`.
  factory MssqlAggregate.max(MssqlExpression operand) => MssqlAggregate._(
    function: MssqlAggregateFunction.max,
    operand: operand,
    resultType: _orderableResult(operand, 'max()'),
    distinct: false,
    window: null,
  );

  /// `COUNT(x)`: the number of non-null values.
  factory MssqlAggregate.count(
    MssqlExpression operand, {
    bool distinct = false,
  }) => MssqlAggregate._(
    function: MssqlAggregateFunction.count,
    operand: operand,
    resultType: const MssqlColumnType(type: MssqlType.int32, nullable: false),
    distinct: distinct,
    window: null,
  );

  /// `COUNT_BIG(x)`, for a count that can pass 2^31.
  factory MssqlAggregate.countBig(
    MssqlExpression operand, {
    bool distinct = false,
  }) => MssqlAggregate._(
    function: MssqlAggregateFunction.countBig,
    operand: operand,
    resultType: const MssqlColumnType(type: MssqlType.int64, nullable: false),
    distinct: distinct,
    window: null,
  );

  final MssqlAggregateFunction function;
  final MssqlExpression operand;

  /// SQL result type, or null when the operand type is unknown.
  ///
  /// Non-count aggregates are nullable because empty groups return null.
  @override
  final MssqlColumnType? resultType;

  /// `SUM(DISTINCT x)`.
  final bool distinct;

  /// The `OVER (…)` clause, or null for an ordinary grouped aggregate.
  final MssqlWindow? window;

  /// Returns this aggregate evaluated over [window].
  MssqlAggregate over(MssqlWindow window) => MssqlAggregate._(
    function: function,
    operand: operand,
    resultType: resultType,
    distinct: distinct,
    window: window,
  );

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final over = window;
    if (over != null) {
      if (distinct) {
        throw StateError(
          'SQL Server has no DISTINCT inside a window aggregate: '
          '${function.sql}(DISTINCT …) OVER (…) is rejected. Aggregate the '
          'distinct values in a derived table and window the result.',
        );
      }
      if (over.orderBy.isNotEmpty) {
        dialect.require(
          dialect.supportsWindowFrames,
          feature:
              'an ordered window aggregate '
              '(${function.sql} OVER (ORDER BY …))',
          requires:
              'SQL Server 2012 or newer, at database compatibility level 110 '
              'or higher. On an older target an aggregate window may only '
              'partition, not order: drop the orderBy() to get the aggregate '
              'over the whole partition, or compute the running total in a '
              'correlated subquery',
        );
      }
    }
    final inner = operand.compile(parameters, dialect);
    final prefix = distinct ? 'DISTINCT ' : '';
    final suffix = over == null
        ? ''
        : ' OVER (${over.compile(parameters, dialect)})';
    return '${function.sql}($prefix$inner)$suffix';
  }

  /// The result type of `SUM` and of a non-exact `AVG`, following SQL
  /// Server's own rules: the integer types collapse to `int`, `decimal(p, s)`
  /// widens its precision to 38 and keeps its scale, and the money types
  /// collapse to `money`.
  static MssqlColumnType? _numericResult(
    MssqlExpression operand,
    String method,
  ) {
    final declared = MssqlSqlType.of(operand);
    if (declared == null) return null;
    return switch (declared.type) {
      MssqlType.tinyInt ||
      MssqlType.smallInt ||
      MssqlType.int32 => const MssqlColumnType(type: MssqlType.int32),
      MssqlType.int64 => const MssqlColumnType(type: MssqlType.int64),
      // The scale survives and the precision does not: SQL Server answers
      // decimal(38, s), which is what keeps an exact amount exact instead of
      // rounding it into a double on the way out.
      MssqlType.decimal || MssqlType.numeric => MssqlColumnType(
        type: declared.type,
        precision: 38,
        scale: declared.scale,
      ),
      MssqlType.money ||
      MssqlType.smallMoney => const MssqlColumnType(type: MssqlType.money),
      MssqlType.real => const MssqlColumnType(type: MssqlType.real),
      MssqlType.float64 => const MssqlColumnType(type: MssqlType.float64),
      _ => throw ArgumentError.value(
        operand,
        'operand',
        '$method needs a numeric column, and '
            '${declared.columnName ?? 'this expression'} is '
            '${declared.type}. Add a CAST if the text really holds numbers.',
      ),
    };
  }

  /// The result type of `MIN` and `MAX`: the operand's own, made nullable.
  static MssqlColumnType? _orderableResult(
    MssqlExpression operand,
    String method,
  ) {
    final declared = MssqlSqlType.of(operand);
    if (declared == null) return null;
    switch (declared.type) {
      // SQL Server refuses all three, and the refusal is worth having here
      // rather than as error 8117 with no column named.
      case MssqlType.bit:
      case MssqlType.text:
      case MssqlType.ntext:
      case MssqlType.image:
        throw ArgumentError.value(
          operand,
          'operand',
          '$method is not defined for ${declared.type} on SQL Server. For a '
              'bit, count the rows where it is true; for text, ntext or '
              'image, cast to varchar, nvarchar or varbinary first.',
        );
      default:
        return MssqlSqlType.asNullable(declared);
    }
  }
}

/// Which rows a window frame counts.
enum MssqlFrameUnit {
  /// `ROWS`: a count of rows either side, regardless of their values.
  rows('ROWS'),

  /// `RANGE`: rows tied by the ordering value; numeric offsets are unsupported.
  range('RANGE');

  const MssqlFrameUnit(this.sql);

  final String sql;
}

/// One end of a [MssqlWindowFrame].
@immutable
class MssqlFrameBound {
  const MssqlFrameBound._(this.sql, this.offset);

  /// `n PRECEDING`.
  factory MssqlFrameBound.preceding(int rows) =>
      MssqlFrameBound._('$rows PRECEDING', _checked(rows, 'preceding'));

  /// `n FOLLOWING`.
  factory MssqlFrameBound.following(int rows) =>
      MssqlFrameBound._('$rows FOLLOWING', _checked(rows, 'following'));

  /// `UNBOUNDED PRECEDING`: from the start of the partition.
  static const MssqlFrameBound unboundedPreceding = MssqlFrameBound._(
    'UNBOUNDED PRECEDING',
    null,
  );

  /// `CURRENT ROW`.
  static const MssqlFrameBound currentRow = MssqlFrameBound._(
    'CURRENT ROW',
    null,
  );

  /// `UNBOUNDED FOLLOWING`: to the end of the partition.
  static const MssqlFrameBound unboundedFollowing = MssqlFrameBound._(
    'UNBOUNDED FOLLOWING',
    null,
  );

  /// Clause built from a validated integer offset.
  final String sql;

  /// How many rows, for the two offset forms; null for the rest.
  final int? offset;

  static int _checked(int rows, String form) {
    if (rows < 1) {
      throw ArgumentError.value(
        rows,
        form,
        'a frame offset counts rows, so it is at least 1. For no offset at '
        'all use MssqlFrameBound.currentRow.',
      );
    }
    return rows;
  }
}

/// Defines the `ROWS` or `RANGE` visible to a window function.
///
/// An explicit frame avoids SQL Server's tie-sensitive default `RANGE` frame.
@immutable
class MssqlWindowFrame {
  MssqlWindowFrame({
    required this.unit,
    required this.start,
    required this.end,
  }) {
    if (unit == MssqlFrameUnit.range &&
        (start.offset != null || end.offset != null)) {
      throw ArgumentError.value(
        unit,
        'unit',
        'SQL Server\'s RANGE accepts only UNBOUNDED and CURRENT ROW, never '
            'an offset: RANGE BETWEEN 3 PRECEDING is rejected. Use '
            'MssqlFrameUnit.rows for a count of rows.',
      );
    }
    if (start == MssqlFrameBound.unboundedFollowing) {
      throw ArgumentError.value(
        start,
        'start',
        'a frame cannot start after the end of its partition.',
      );
    }
    if (end == MssqlFrameBound.unboundedPreceding) {
      throw ArgumentError.value(
        end,
        'end',
        'a frame cannot end before the start of its partition.',
      );
    }
  }

  final MssqlFrameUnit unit;
  final MssqlFrameBound start;
  final MssqlFrameBound end;

  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    dialect.require(
      dialect.supportsWindowFrames,
      feature: 'a window frame (${unit.sql} BETWEEN …)',
      requires:
          'SQL Server 2012 or newer, at database compatibility level 110 or '
          'higher. An older target has windows but no frame clause: drop the '
          'frame to aggregate over the whole partition',
    );
    return '${unit.sql} BETWEEN ${start.sql} AND ${end.sql}';
  }
}

/// The `OVER (…)` clause: how the rows a window function reads are divided
/// and ordered.
@immutable
class MssqlWindow {
  MssqlWindow({
    Iterable<MssqlExpression> partitionBy = const <MssqlExpression>[],
    Iterable<MssqlOrder> orderBy = const <MssqlOrder>[],
    this.frame,
  }) : partitionBy = List<MssqlExpression>.unmodifiable(partitionBy),
       orderBy = List<MssqlOrder>.unmodifiable(orderBy) {
    if (frame != null && this.orderBy.isEmpty) {
      throw ArgumentError.value(
        frame,
        'frame',
        'a frame counts rows either side of the current one, which needs an '
            'order to count in. Add orderBy, or drop the frame.',
      );
    }
  }

  final List<MssqlExpression> partitionBy;
  final List<MssqlOrder> orderBy;
  final MssqlWindowFrame? frame;

  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    final parts = <String>[];
    if (partitionBy.isNotEmpty) {
      final terms = partitionBy.map((e) => e.compile(parameters, dialect));
      parts.add('PARTITION BY ${terms.join(', ')}');
    }
    if (orderBy.isNotEmpty) {
      // Window ordering cannot carry the paging options used by SELECT.
      final terms = orderBy.map(
        (o) =>
            '${o.expression.compile(parameters, dialect)}'
            '${o.descending ? ' DESC' : ' ASC'}',
      );
      parts.add('ORDER BY ${terms.join(', ')}');
    }
    final bounds = frame;
    if (bounds != null) parts.add(bounds.compile(parameters, dialect));
    return parts.join(' ');
  }
}

/// Window functions emitted by the query builder.
enum MssqlWindowFunction {
  /// `ROW_NUMBER()`: 1, 2, 3 … with ties broken arbitrarily.
  rowNumber('ROW_NUMBER', ranking: true),

  /// `RANK()`: ties share a number and the next one skips.
  rank('RANK', ranking: true),

  /// `DENSE_RANK()`: ties share a number and the next one does not skip.
  denseRank('DENSE_RANK', ranking: true),

  /// `NTILE(n)`: the partition split into n groups as evenly as it divides.
  ntile('NTILE', ranking: true),

  /// `LAG(x, n, default)`: the value n rows earlier in the partition.
  lag('LAG', ranking: false),

  /// `LEAD(x, n, default)`: the value n rows later.
  lead('LEAD', ranking: false);

  const MssqlWindowFunction(this.sql, {required this.ranking});

  final String sql;

  /// Whether the function ranks rows instead of reading a row value.
  final bool ranking;
}

/// A non-aggregate window function such as `ROW_NUMBER()` or `LAG()`.
@immutable
class MssqlWindowExpression extends MssqlExpression
    implements MssqlTypedExpression {
  const MssqlWindowExpression._({
    required this.function,
    required this.arguments,
    required this.window,
    required this.resultType,
    required this.literalSuffix,
  });

  /// `ROW_NUMBER() OVER (…)`, whose result is `bigint`.
  factory MssqlWindowExpression.rowNumber(MssqlWindow over) =>
      MssqlWindowExpression._(
        function: MssqlWindowFunction.rowNumber,
        arguments: const <MssqlExpression>[],
        window: over,
        resultType: const MssqlColumnType(
          type: MssqlType.int64,
          nullable: false,
        ),
        literalSuffix: '',
      );

  /// `RANK() OVER (…)`.
  factory MssqlWindowExpression.rank(MssqlWindow over) =>
      MssqlWindowExpression._(
        function: MssqlWindowFunction.rank,
        arguments: const <MssqlExpression>[],
        window: over,
        resultType: const MssqlColumnType(
          type: MssqlType.int64,
          nullable: false,
        ),
        literalSuffix: '',
      );

  /// `DENSE_RANK() OVER (…)`.
  factory MssqlWindowExpression.denseRank(MssqlWindow over) =>
      MssqlWindowExpression._(
        function: MssqlWindowFunction.denseRank,
        arguments: const <MssqlExpression>[],
        window: over,
        resultType: const MssqlColumnType(
          type: MssqlType.int64,
          nullable: false,
        ),
        literalSuffix: '',
      );

  /// `NTILE(n) OVER (…)`: which of [buckets] groups the row falls in.
  factory MssqlWindowExpression.ntile(int buckets, MssqlWindow over) {
    if (buckets < 1) {
      throw ArgumentError.value(
        buckets,
        'buckets',
        'NTILE splits a partition into at least one group.',
      );
    }
    return MssqlWindowExpression._(
      function: MssqlWindowFunction.ntile,
      arguments: const <MssqlExpression>[],
      window: over,
      resultType: const MssqlColumnType(type: MssqlType.int32, nullable: false),
      // A validated int, and part of the function's shape rather than data.
      literalSuffix: '$buckets',
    );
  }

  /// `LAG(x, offset, ifMissing) OVER (…)`: [operand] as of [offset] rows
  /// earlier in the partition.
  ///
  /// Without [ifMissing] the first row of each partition is null: there is no
  /// earlier row, and substituting zero would misstate the first change.
  factory MssqlWindowExpression.lag(
    MssqlExpression operand,
    MssqlWindow over, {
    int offset = 1,
    MssqlExpression? ifMissing,
  }) => MssqlWindowExpression._(
    function: MssqlWindowFunction.lag,
    arguments: <MssqlExpression>[operand, ?ifMissing],
    window: over,
    resultType: _offsetResult(operand),
    literalSuffix: _offsetSuffix(offset, ifMissing != null),
  );

  /// `LEAD(x, offset, ifMissing) OVER (…)`.
  factory MssqlWindowExpression.lead(
    MssqlExpression operand,
    MssqlWindow over, {
    int offset = 1,
    MssqlExpression? ifMissing,
  }) => MssqlWindowExpression._(
    function: MssqlWindowFunction.lead,
    arguments: <MssqlExpression>[operand, ?ifMissing],
    window: over,
    resultType: _offsetResult(operand),
    literalSuffix: _offsetSuffix(offset, ifMissing != null),
  );

  final MssqlWindowFunction function;

  /// The arguments that are expressions and bind their own parameters.
  final List<MssqlExpression> arguments;

  final MssqlWindow window;

  @override
  final MssqlColumnType? resultType;

  /// The arguments that are validated integers, already rendered.
  ///
  /// `NTILE(4)` and `LAG(x, 2)` name a position in the window rather than a
  /// value to compare, and SQL Server wants a constant there — so they are
  /// written into the text after being range checked, and there is nothing of
  /// the caller's in them but a number.
  final String literalSuffix;

  @override
  String compile(MssqlParameterAllocator parameters, MssqlDialect dialect) {
    if (!function.ranking) {
      dialect.require(
        dialect.supportsWindowOffsetFunctions,
        feature: '${function.sql}()',
        requires:
            'SQL Server 2012 or newer, at database compatibility level 110 '
            'or higher. An older target reads the neighbouring row by joining '
            'the table to itself on a ROW_NUMBER() column, which is a '
            'different query rather than a translation of this one',
      );
    }
    if (window.orderBy.isEmpty) {
      throw StateError(
        '${function.sql}() needs an ordered window: without orderBy the '
        'result depends on the order rows happen to arrive in, so two runs '
        'of the same query can disagree. Pass '
        'MssqlWindow(orderBy: [...]).',
      );
    }
    if (function.ranking && window.frame != null) {
      throw StateError(
        '${function.sql}() takes no frame; SQL Server rejects one. A ranking '
        'function reads the whole partition by definition, so drop the frame '
        'from the window it is given.',
      );
    }
    final compiled = <String>[
      ...arguments.map((a) => a.compile(parameters, dialect)),
    ];
    // LAG's optional default follows its offset, so the rendered integers go
    // between the first expression and the rest.
    final rendered = switch (compiled.length) {
      0 => literalSuffix,
      1 => '${compiled.first}$literalSuffix',
      _ => '${compiled.first}$literalSuffix, ${compiled.last}',
    };
    return '${function.sql}($rendered) OVER '
        '(${window.compile(parameters, dialect)})';
  }

  /// `LAG`/`LEAD` return the operand's own type, and always nullably: the
  /// first row of a partition has nothing before it.
  static MssqlColumnType? _offsetResult(MssqlExpression operand) {
    final declared = MssqlSqlType.of(operand);
    return declared == null ? null : MssqlSqlType.asNullable(declared);
  }

  static String _offsetSuffix(int offset, bool hasDefault) {
    if (offset < 0) {
      throw ArgumentError.value(
        offset,
        'offset',
        'LAG and LEAD count rows in one direction each, so the offset is not '
            'negative. Use the other function to look the other way.',
      );
    }
    // The offset has to be written whenever a default follows it: SQL Server
    // has no way to skip a positional argument.
    if (offset == 1 && !hasDefault) return '';
    return ', $offset';
  }
}
