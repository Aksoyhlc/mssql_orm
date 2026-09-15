import 'package:mssql_orm/query.dart';
import 'package:test/test.dart';

MssqlQuery get roots => MssqlQuery.from('dbo.Categories')
    .select(<MssqlExpression>[Col('Id'), Col('ParentId'), MssqlLiteral(0)])
    .where(Col('ParentId').isNull());

MssqlQuery get children => MssqlQuery.from('dbo.Categories', as: 'c')
    .innerJoin('tree', on: Col('tree.Id').eqCol('c.ParentId'))
    .select(<MssqlExpression>[
      Col('c.Id'),
      Col('c.ParentId'),
      MssqlArithmetic(Col('tree.Depth'), MssqlArithmeticOperator.add, 1),
    ]);

MssqlQuery tree({int? maxRecursion}) =>
    MssqlQuery.from('tree').withRecursiveCte(
      'tree',
      anchor: roots,
      recursive: children,
      columns: <String>['Id', 'ParentId', 'Depth'],
      maxRecursion: maxRecursion,
    );

void main() {
  group('a plain expression', () {
    test('is written before the query that uses it', () {
      final sql = MssqlQuery.from(
        'recent',
      ).withCte('recent', MssqlQuery.from('dbo.Orders').top(100)).compile().sql;
      expect(
        sql,
        'WITH [recent] AS (SELECT TOP (@q0) * FROM [dbo].[Orders]) '
        'SELECT * FROM [recent]',
      );
    });

    test('names its columns when asked to', () {
      final sql = MssqlQuery.from('t')
          .withCte(
            't',
            MssqlQuery.from('dbo.Orders').select(<MssqlExpression>[Col('Id')]),
            columns: <String>['OrderId'],
          )
          .compile()
          .sql;
      expect(sql, startsWith('WITH [t] ([OrderId]) AS ('));
    });

    test('can be joined to like any other source', () {
      final sql = MssqlQuery.from('dbo.Customers', as: 'c')
          .withCte(
            'totals',
            MssqlQuery.from(
              'dbo.Orders',
            ).groupBy(<MssqlExpression>[Col('CustomerId')]).select(
              <MssqlExpression>[Col('CustomerId'), sum(Col('Total')).as('Sum')],
            ),
          )
          .innerJoin('totals', on: Col('totals.CustomerId').eqCol('c.Id'))
          .compile()
          .sql;
      expect(sql, contains('INNER JOIN [totals] ON'));
      expect(sql, startsWith('WITH [totals] AS ('));
    });

    test('several are separated by commas, in the order written', () {
      final sql = MssqlQuery.from('b')
          .withCte('a', MssqlQuery.from('dbo.A'))
          .withCte('b', MssqlQuery.from('a'))
          .compile()
          .sql;
      expect(
        sql,
        'WITH [a] AS (SELECT * FROM [dbo].[A]), [b] AS (SELECT * FROM [a]) '
        'SELECT * FROM [b]',
      );
    });

    test('two expressions of one name are refused', () {
      expect(
        () => MssqlQuery.from('a')
            .withCte('a', MssqlQuery.from('dbo.A'))
            .withCte('A', MssqlQuery.from('dbo.B')),
        throwsArgumentError,
      );
    });

    test('the name is quoted, not concatenated', () {
      final sql = MssqlQuery.fromParts(<String>[
        'tree]evil',
      ]).withCte('tree]evil', MssqlQuery.from('T')).compile().sql;
      expect(sql, contains('[tree]]evil]'));
      expect(sql, isNot(contains('DROP')));
    });

    test('a name the server cannot hold is refused where it is written', () {
      expect(() => MssqlCte('', MssqlQuery.from('T')), throwsArgumentError);
      expect(
        () => MssqlCte('t' * 129, MssqlQuery.from('T')),
        throwsArgumentError,
      );
      expect(
        () => MssqlCte('t', MssqlQuery.from('T'), columns: <String>['']),
        throwsArgumentError,
      );
    });

    test('the count over it keeps the clause', () {
      final sql = MssqlQuery.from(
        't',
      ).withCte('t', MssqlQuery.from('dbo.Orders')).countRows().compile().sql;
      expect(sql, startsWith('WITH [t] AS ('));
      expect(sql, contains('SELECT COUNT_BIG(*) FROM [t]'));
    });
  });

  group('parameters', () {
    test('are numbered in the order the text reads, clause first', () {
      final statement = MssqlQuery.from('t')
          .withCte(
            't',
            MssqlQuery.from('dbo.Orders').where(Col('Total').gt(100)),
          )
          .where(Col('Id').eq(7))
          .compile();
      expect(statement.parameters, <String, Object?>{'q0': 100, 'q1': 7});
      expect(
        statement.sql.indexOf('@q0'),
        lessThan(statement.sql.indexOf('@q1')),
      );
    });

    test('two expressions each get their own', () {
      final statement = MssqlQuery.from('b')
          .withCte('a', MssqlQuery.from('dbo.A').where(Col('X').eq(1)))
          .withCte('b', MssqlQuery.from('a').where(Col('Y').eq(2)))
          .compile();
      expect(statement.parameters, <String, Object?>{'q0': 1, 'q1': 2});
    });
  });

  group('a recursive expression', () {
    test('compiles to an anchor and a member that refers back to it', () {
      final sql = tree().compile().sql;
      expect(sql, startsWith('WITH [tree] ([Id], [ParentId], [Depth]) AS ('));
      expect(sql, contains('UNION ALL'));
      expect(sql, contains('INNER JOIN [tree] ON'));
      expect(sql, endsWith('SELECT * FROM [tree]'));
      expect(sql, isNot(contains('RECURSIVE')));
    });

    test('insists on a column list', () {
      expect(
        () => MssqlQuery.from('tree').withRecursiveCte(
          'tree',
          anchor: roots,
          recursive: children,
          columns: const <String>[],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('refers to itself'),
          ),
        ),
      );
    });

    test('the ceiling is a hint on the whole statement, written last', () {
      final sql = tree(
        maxRecursion: 50,
      ).orderBy(<MssqlOrder>[Col('Depth').asc()]).compile().sql;
      expect(sql, endsWith('ORDER BY [Depth] ASC OPTION (MAXRECURSION 50)'));
    });

    test('no ceiling given leaves the server default of 100', () {
      expect(tree().compile().sql, isNot(contains('MAXRECURSION')));
    });

    test('0 is accepted, and it means no ceiling at all', () {
      expect(
        tree(maxRecursion: 0).compile().sql,
        endsWith('OPTION (MAXRECURSION 0)'),
      );
    });

    test('a ceiling outside what the server accepts is refused', () {
      expect(() => tree(maxRecursion: -1), throwsArgumentError);
      expect(() => tree(maxRecursion: 32768), throwsArgumentError);
      expect(() => tree(maxRecursion: 32767), returnsNormally);
    });

    test('the outer query still filters, orders and pages', () {
      final sql = tree()
          .where(Col('Depth').lte(3))
          .orderBy(<MssqlOrder>[Col('Depth').asc()])
          .paged(offset: 10, rows: 5)
          .compile()
          .sql;
      expect(sql, contains('WHERE [Depth] <= @'));
      expect(sql, contains('ORDER BY [Depth] ASC'));
      expect(sql, contains('OFFSET @'));
    });
  });

  group('where a WITH clause may not go', () {
    test('not inside a derived table', () {
      final inner = MssqlQuery.from('t').withCte('t', MssqlQuery.from('dbo.A'));
      expect(
        () => MssqlQuery.fromSub(inner, as: 'x').compile(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('outermost'),
          ),
        ),
      );
    });

    test('but the outermost query may carry one over a derived table', () {
      final sql = MssqlQuery.fromSub(
        MssqlQuery.from('dbo.Orders'),
        as: 'x',
      ).withCte('t', MssqlQuery.from('dbo.A')).compile().sql;
      expect(sql, startsWith('WITH [t] AS ('));
      expect(sql, contains('AS [x]'));
    });
  });

  group('on SQL Server 2008', () {
    test('the clause survives the ROW_NUMBER rewrite', () {
      final sql = tree()
          .select(<MssqlExpression>[Col('Id'), Col('ParentId'), Col('Depth')])
          .orderBy(<MssqlOrder>[Col('Depth').asc()])
          .paged(offset: 10, rows: 5)
          .compile(dialect: MssqlDialect.sql2008)
          .sql;
      expect(sql, startsWith('WITH [tree] ('));
      expect(sql, contains('ROW_NUMBER() OVER'));
      expect(sql, contains('[mssql_orm_row] BETWEEN'));
    });

    test('and so does the recursion ceiling', () {
      final sql = tree(maxRecursion: 10)
          .select(<MssqlExpression>[Col('Id'), Col('ParentId'), Col('Depth')])
          .orderBy(<MssqlOrder>[Col('Depth').asc()])
          .paged(offset: 0, rows: 5)
          .compile(dialect: MssqlDialect.sql2008)
          .sql;
      expect(sql, endsWith('OPTION (MAXRECURSION 10)'));
    });
  });
}

