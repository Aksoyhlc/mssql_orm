import 'package:mssql_native/mssql_native.dart';

/// SQL Server's base system type names, mapped to the driver's classification.
///
/// Keyed by the name in `sys.types` for the *base* system type, so a type
/// alias such as `sysname` never reaches this map: the reader resolves it to
/// `nvarchar` first.
const Map<String, MssqlType> _byName = <String, MssqlType>{
  'bit': MssqlType.bit,
  'tinyint': MssqlType.tinyInt,
  'smallint': MssqlType.smallInt,
  'int': MssqlType.int32,
  'bigint': MssqlType.int64,
  'real': MssqlType.real,
  'float': MssqlType.float64,
  'decimal': MssqlType.decimal,
  'numeric': MssqlType.numeric,
  'money': MssqlType.money,
  'smallmoney': MssqlType.smallMoney,
  'char': MssqlType.char,
  'varchar': MssqlType.varchar,
  'nchar': MssqlType.nchar,
  'nvarchar': MssqlType.nvarchar,
  'text': MssqlType.text,
  'ntext': MssqlType.ntext,
  'binary': MssqlType.binary,
  'varbinary': MssqlType.varbinary,
  'image': MssqlType.image,
  'timestamp': MssqlType.binary,
  'rowversion': MssqlType.binary,
  'date': MssqlType.date,
  'time': MssqlType.time,
  'smalldatetime': MssqlType.smallDateTime,
  'datetime': MssqlType.dateTime,
  'datetime2': MssqlType.dateTime2,
  'datetimeoffset': MssqlType.dateTimeOffset,
  'uniqueidentifier': MssqlType.uniqueIdentifier,
  'xml': MssqlType.xml,
};

/// Types the driver has no dedicated model for, which `dbconvert` returns as
/// their canonical text.
///
/// They are not unknown and they are not lost: `logicalTypeFor` in the driver
/// falls back to `varchar`, so the value arrives as a `String`. Whoever
/// generates code from a schema should read them and never write them, since
/// writing needs the CLR type itself.
const Set<String> textOnlySqlTypes = <String>{
  'hierarchyid',
  'geometry',
  'geography',
  'sql_variant',
};

/// The driver's classification of [sqlTypeName], or null if nothing here
/// recognises it.
///
/// A null answer is a real answer: the caller decides whether to stop, skip
/// the column or ask for a converter. Guessing would move the failure to
/// runtime.
MssqlType? mssqlTypeForSqlTypeName(String sqlTypeName) {
  final name = sqlTypeName.toLowerCase();
  final known = _byName[name];
  if (known != null) return known;
  // The CLR types arrive as text, which is what varchar means to the driver.
  if (textOnlySqlTypes.contains(name)) return MssqlType.varchar;
  return null;
}
