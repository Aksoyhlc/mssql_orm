import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'expression.dart';
import 'operators.dart';
import 'predicates.dart';

/// One output column of a [MssqlProjection].
///
/// The alias is the result-set name. Two columns with the same alias are a
/// construction error: SQL Server would still return both, and mapping by
/// name would silently pick one.
@immutable
class MssqlProjectionColumn {
  MssqlProjectionColumn(this.alias, this.expression, {this.required = false}) {
    if (alias.trim().isEmpty) {
      throw ArgumentError.value(
        alias,
        'alias',
        'A projection column needs a name.',
      );
    }
  }

  /// Result-set name, unquoted.
  final String alias;

  final MssqlExpression expression;

  /// When true, a SQL NULL is a conversion error naming this projection.
  final bool required;

  MssqlExpression get selected =>
      expression is MssqlAliased ? expression : expression.as(alias);
}

/// Column list, aliases, and `MssqlRow → R` in one descriptor.
///
/// A list screen holds [OrderListItem.projection], not a second ad-hoc
/// SELECT plus a hand-written mapper that can drift apart.
@immutable
class MssqlProjection<R> {
  MssqlProjection({
    required this.name,
    required List<MssqlProjectionColumn> columns,
    required this.map,
  }) : columns = List<MssqlProjectionColumn>.unmodifiable(columns) {
    final seen = <String>{};
    for (final column in columns) {
      final folded = column.alias.toLowerCase();
      if (!seen.add(folded)) {
        throw ArgumentError.value(
          column.alias,
          'columns',
          'Projection "$name" has two columns named "${column.alias}". '
              'Give one an explicit alias.',
        );
      }
    }
    if (this.columns.isEmpty) {
      throw ArgumentError.value(
        columns,
        'columns',
        'Projection "$name" has no columns.',
      );
    }
  }

  /// User-facing name, used in conversion errors.
  final String name;

  final List<MssqlProjectionColumn> columns;

  final R Function(MssqlRow row) map;

  List<MssqlExpression> get selectList =>
      columns.map((c) => c.selected).toList(growable: false);

  /// Reads [index] as [T], naming [name] on a conversion failure.
  static T decode<T>(
    MssqlRow row,
    int index, {
    required String projection,
    required String column,
    MssqlExpression? expression,
    bool required = false,
  }) {
    final raw = row.at(index);
    if (raw == null) {
      if (required || !_isNullable<T>()) {
        throw StateError(
          'Projection $projection column $column was NULL. '
          'The descriptor marks it non-null; fix the SQL or the override.',
        );
      }
      return null as T;
    }
    final type = expression == null ? null : MssqlSqlType.of(expression);
    if (type != null) {
      try {
        final decoded = MssqlTypeCodecs.forColumn(type).decode(raw);
        if (decoded is T) return decoded;
      } on Object catch (error) {
        throw StateError(
          'Projection $projection column $column could not decode '
          '${raw.runtimeType} as $T: $error',
        );
      }
    }
    if (raw is T) return raw as T;
    throw StateError(
      'Projection $projection column $column contains '
      '${raw.runtimeType}, not $T.',
    );
  }

  static bool _isNullable<T>() => null is T;
}
