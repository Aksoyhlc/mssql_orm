import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mssql_orm/schema.dart';

import '../api_version.dart';

/// A stable digest of the parts of a table that generated code depends on.
///
/// What is left out is as deliberate as what is in. Indexes, foreign keys,
/// permissions and statistics all change without breaking a single line of
/// generated code, and folding them in would make the drift check cry wolf. A
/// check that fires on harmless changes is a check people turn off.
///
/// The API contract version is folded in on purpose: generated code depends on
/// the runtime's method names and meanings just as much as on the table, so a
/// contract bump has to invalidate the file even when the table stood still.
String fingerprintOf(MssqlTableSchema table) {
  final buffer = StringBuffer()
    ..writeln('api=${MssqlApiVersion.current}')
    ..writeln('${table.schema}.${table.name}')
    ..writeln('view=${table.isView}');
  for (final column in table.columns) {
    buffer.writeln(
      <Object?>[
        column.name,
        column.sqlTypeName,
        column.nullable,
        column.precision,
        column.scale,
        column.maxLength,
        column.isIdentity,
        column.isComputed,
        column.isRowVersion,
        column.hasDefault,
      ].join('|'),
    );
  }
  buffer.writeln('pk=${table.primaryKey?.columns.join(',') ?? ''}');
  for (final key in table.uniqueKeys) {
    if (!key.guaranteesUniqueness) continue;
    buffer.writeln(
      'uq=${key.name}|${key.columns.join(',')}|'
      '${key.nullable.join(',')}|${key.collations.join(',')}',
    );
  }
  buffer.writeln('trigger=${table.hasEnabledTrigger}');
  return sha256.convert(utf8.encode(buffer.toString())).toString();
}
