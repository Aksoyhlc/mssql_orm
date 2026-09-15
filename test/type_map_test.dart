import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/schema.dart';
import 'package:test/test.dart';

void main() {
  group('the SQL type map', () {
    test('maps the exact numerics the driver keeps exact', () {
      for (final name in <String>[
        'decimal',
        'numeric',
        'money',
        'smallmoney',
      ]) {
        expect(mssqlTypeForSqlTypeName(name), isNotNull, reason: name);
      }
      expect(mssqlTypeForSqlTypeName('decimal'), MssqlType.decimal);
      expect(mssqlTypeForSqlTypeName('money'), MssqlType.money);
    });

    test('maps the integer widths to their own classifications', () {
      expect(mssqlTypeForSqlTypeName('tinyint'), MssqlType.tinyInt);
      expect(mssqlTypeForSqlTypeName('smallint'), MssqlType.smallInt);
      expect(mssqlTypeForSqlTypeName('int'), MssqlType.int32);
      expect(mssqlTypeForSqlTypeName('bigint'), MssqlType.int64);
    });

    test('maps every date and time type', () {
      expect(mssqlTypeForSqlTypeName('date'), MssqlType.date);
      expect(mssqlTypeForSqlTypeName('time'), MssqlType.time);
      expect(mssqlTypeForSqlTypeName('smalldatetime'), MssqlType.smallDateTime);
      expect(mssqlTypeForSqlTypeName('datetime'), MssqlType.dateTime);
      expect(mssqlTypeForSqlTypeName('datetime2'), MssqlType.dateTime2);
      expect(
        mssqlTypeForSqlTypeName('datetimeoffset'),
        MssqlType.dateTimeOffset,
      );
    });

    test('rowversion and timestamp are the same type, carried as bytes', () {
      expect(mssqlTypeForSqlTypeName('timestamp'), MssqlType.binary);
      expect(mssqlTypeForSqlTypeName('rowversion'), MssqlType.binary);
    });

    test('the name is matched without regard to case', () {
      expect(mssqlTypeForSqlTypeName('NVARCHAR'), MssqlType.nvarchar);
      expect(mssqlTypeForSqlTypeName('NVarChar'), MssqlType.nvarchar);
    });

    test('the CLR types map to text rather than being refused', () {
      for (final name in textOnlySqlTypes) {
        expect(mssqlTypeForSqlTypeName(name), MssqlType.varchar, reason: name);
      }
      expect(
        textOnlySqlTypes,
        containsAll(<String>[
          'hierarchyid',
          'geometry',
          'geography',
          'sql_variant',
        ]),
      );
    });

    test('a genuinely unknown type is null, not a guess', () {
      for (final name in <String>['myUserDefinedType', 'vector', '']) {
        expect(mssqlTypeForSqlTypeName(name), isNull, reason: name);
      }
    });
  });
}

