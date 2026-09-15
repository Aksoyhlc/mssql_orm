import 'package:mssql_orm/query.dart';

void main() {
  final s = MssqlQuery.from('dbo.Orders')
      .select(<MssqlExpression>[Col('Id')])
      .orderBy(<MssqlOrder>[Col('Id').desc()])
      .paged(offset: 20, rows: 10)
      .compile(dialect: MssqlDialect.sql2008);
  print('SQL2008: ${s.sql}');
  print('PARAMS: ${s.parameters}');
  final base = MssqlQuery.from('dbo.Orders')
      .where(Col('IsOpen').eq(true))
      .orderBy(<MssqlOrder>[Col('Id').desc()])
      .paged(offset: 20, rows: 10);
  final c = base.countRows().compile();
  print('COUNT: ${c.sql}');
  print('CPARAMS: ${c.parameters}');
  try {
    MssqlQuery.from('dbo.B')
        .select(<MssqlExpression>[Col('Id')])
        .union(
          MssqlQuery.from('dbo.B').select(<MssqlExpression>[Col('Id')]),
        )
        .orderBy(<MssqlOrder>[Col('Id').asc()])
        .paged(offset: 0, rows: 10)
        .compile(dialect: MssqlDialect.sql2008);
  } catch (e) {
    print('UNION2008: ${e.runtimeType}: $e');
  }
}
