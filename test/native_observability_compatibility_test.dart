import 'package:mssql_native/mssql_native.dart' as native;
import 'package:mssql_orm/orm.dart' as orm;
import 'package:test/test.dart';

void main() {
  test('native and ORM query-kind APIs coexist in one consumer', () {
    expect(native.MssqlQueryKind.query.name, 'query');
    expect(orm.MssqlOrmQueryKind.query.name, 'query');
  });
}
