import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

const String cteSchema = 'orm_cte_fixture';
const String categories = '$cteSchema.Categories';

void main() {
  group('common table expressions, against a server', () {
    late MssqlConnection connection;

    setUpAll(() async {
      if (!liveEnabled) return;
      await initializeLive();
      connection = await MssqlConnection.open(liveConfig());
      await connection.execute(
        "IF SCHEMA_ID(N'$cteSchema') IS NULL "
        "EXEC(N'CREATE SCHEMA [$cteSchema]');",
      );
      await connection.execute(
        "IF OBJECT_ID(N'[$cteSchema].[Categories]', N'U') IS NOT NULL "
        'DROP TABLE [$cteSchema].[Categories];',
      );
      await connection.execute('''
CREATE TABLE [$cteSchema].[Categories] (
  [Id]       INT NOT NULL PRIMARY KEY,
  [ParentId] INT NULL,
  [Name]     NVARCHAR(50) NOT NULL
);''');
      await connection.execute('''
INSERT INTO [$cteSchema].[Categories] ([Id], [ParentId], [Name]) VALUES
  (1, NULL, N'Kırtasiye'),
  (2, 1,    N'Defter'),
  (3, 1,    N'Kalem'),
  (4, 2,    N'Spiralli defter'),
  (5, NULL, N'Ofis');''');
    });

    tearDownAll(() async {
      if (!liveEnabled) return;
      await connection.execute('DROP TABLE [$cteSchema].[Categories];');
      await connection.close();
    });

    MssqlQuery treeFrom(String source, {int? maxRecursion}) =>
        MssqlQuery.from(source).withRecursiveCte(
          'tree',
          anchor: MssqlQuery.from(categories)
              .select(<MssqlExpression>[
                Col('Id'),
                Col('ParentId'),
                Col('Name'),
                MssqlLiteral(0),
              ])
              .where(Col('ParentId').isNull()),
          recursive: MssqlQuery.from(categories, as: 'c')
              .innerJoin('tree', on: Col('tree.Id').eqCol('c.ParentId'))
              .select(<MssqlExpression>[
                Col('c.Id'),
                Col('c.ParentId'),
                Col('c.Name'),
                MssqlArithmetic(
                  Col('tree.Depth'),
                  MssqlArithmeticOperator.add,
                  1,
                ),
              ]),
          columns: <String>['Id', 'ParentId', 'Name', 'Depth'],
          maxRecursion: maxRecursion,
        );

    Future<List<MssqlRow>> run(MssqlQuery query) async {
      final statement = query.compile();
      return connection.queryTypedRows(
        statement.sql,
        parameters: statement.parameters,
      );
    }

    test('walks the whole tree and numbers the levels', () async {
      final rows = await run(
        treeFrom(
          'tree',
        ).orderBy(<MssqlOrder>[Col('Depth').asc(), Col('Id').asc()]),
      );
      expect(rows, hasLength(5));
      expect(rows.map((r) => (r['Depth']! as num).toInt()), <int>[
        0,
        0,
        1,
        1,
        2,
      ]);
      expect(rows.last['Name'], 'Spiralli defter');
    }, skip: liveSkip);

    test('the outer query filters the expression it built', () async {
      final rows = await run(
        treeFrom(
          'tree',
        ).where(Col('Depth').lte(1)).orderBy(<MssqlOrder>[Col('Id').asc()]),
      );
      expect(rows, hasLength(4));
    }, skip: liveSkip);

    test('a page over a recursive expression works', () async {
      final rows = await run(
        treeFrom(
          'tree',
        ).orderBy(<MssqlOrder>[Col('Id').asc()]).paged(offset: 1, rows: 2),
      );
      expect(rows.map((r) => (r['Id']! as num).toInt()), <int>[2, 3]);
    }, skip: liveSkip);

    test('counting one gives the same total as reading it', () async {
      final rows = await run(treeFrom('tree').countRows());
      expect((rows.single.at(0)! as num).toInt(), 5);
    }, skip: liveSkip);

    test('the ceiling stops a walk deeper than it allows', () async {
      await expectLater(
        run(treeFrom('tree', maxRecursion: 1)),
        throwsA(
          isA<MssqlException>().having(
            (e) => e.message,
            'message',
            contains('recursion'),
          ),
        ),
      );
    }, skip: liveSkip);

    test('a ceiling above the depth lets it finish', () async {
      expect(await run(treeFrom('tree', maxRecursion: 10)), hasLength(5));
    }, skip: liveSkip);

    test('a plain expression is accepted, and can be joined to', () async {
      final rows = await run(
        MssqlQuery.from(categories, as: 'c')
            .withCte(
              'roots',
              MssqlQuery.from(categories)
                  .select(<MssqlExpression>[Col('Id')])
                  .where(Col('ParentId').isNull()),
            )
            .innerJoin('roots', on: Col('roots.Id').eqCol('c.ParentId'))
            .select(<MssqlExpression>[Col('c.Name')])
            .orderBy(<MssqlOrder>[Col('c.Id').asc()]),
      );
      expect(rows.map((r) => r['Name']), <String>['Defter', 'Kalem']);
    }, skip: liveSkip);

    test('two expressions, the second reading the first', () async {
      final rows = await run(
        MssqlQuery.from('deep')
            .withCte(
              'leaves',
              MssqlQuery.from(categories, as: 'c')
                  .select(<MssqlExpression>[Col('c.Id'), Col('c.Name')])
                  .where(
                    MssqlRaw(
                      'NOT EXISTS (SELECT 1 FROM $categories AS k '
                      'WHERE k.ParentId = c.Id)',
                    ),
                  ),
            )
            .withCte('deep', MssqlQuery.from('leaves'))
            .orderBy(<MssqlOrder>[Col('Id').asc()]),
      );
      expect(rows.map((r) => (r['Id']! as num).toInt()), <int>[3, 4, 5]);
    }, skip: liveSkip);

    test(
      'a parameter inside the expression is bound, not interpolated',
      () async {
        final rows = await run(
          MssqlQuery.from('named').withCte(
            'named',
            MssqlQuery.from(categories)
                .select(<MssqlExpression>[Col('Id')])
                .where(Col('Name').eq("Kayıt'; DROP TABLE x --")),
          ),
        );
        expect(rows, isEmpty);
        expect(await run(treeFrom('tree')), hasLength(5));
      },
      skip: liveSkip,
    );
  });
}

