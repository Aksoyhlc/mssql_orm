import 'package:mssql_native/mssql_native.dart' show MssqlServerInfo;
import 'package:mssql_orm/query.dart';
import 'package:test/test.dart';

const dialects = <MssqlDialect>[MssqlDialect.sql2012, MssqlDialect.sql2008];

void main() {
  group('sources and identifiers', () {
    test('a multipart source is quoted part by part', () {
      for (final dialect in dialects) {
        final s = MssqlQuery.from('dbo.Users').compile(dialect: dialect);
        expect(s.sql, 'SELECT * FROM [dbo].[Users]');
        expect(s.parameters, isEmpty);
      }
    });

    test('an alias is quoted and applied', () {
      final s = MssqlQuery.from('dbo.Orders', as: 'o').compile();
      expect(s.sql, 'SELECT * FROM [dbo].[Orders] AS [o]');
    });

    test('a closing bracket in an identifier cannot end the quoting', () {
      final s = MssqlQuery.from('[order]]detail]').compile();
      expect(s.sql, 'SELECT * FROM [order]]detail]');
    });

    test('a malformed identifier is refused', () {
      expect(() => MssqlQuery.from('dbo.'), throwsArgumentError);
      expect(() => MssqlQuery.from(''), throwsArgumentError);
      expect(() => MssqlQuery.from('a.b.c.d.e'), throwsArgumentError);
    });
  });

  group('projection', () {
    test('columns and aliases', () {
      final s = MssqlQuery.from('dbo.Orders', as: 'o').select(<MssqlExpression>[
        Col('o.Id'),
        Col('o.Total').as('Sum'),
      ]).compile();
      expect(
        s.sql,
        'SELECT [o].[Id], [o].[Total] AS [Sum] FROM [dbo].[Orders] AS [o]',
      );
    });

    test('distinct', () {
      final s = MssqlQuery.from(
        'dbo.Orders',
      ).selectDistinct(<MssqlExpression>[Col('Status')]).compile();
      expect(s.sql, 'SELECT DISTINCT [Status] FROM [dbo].[Orders]');
    });

    test('countRows counts the rows the query returns, page and all', () {
      final base = MssqlQuery.from('dbo.Orders')
          .where(Col('IsOpen').eq(true))
          .orderBy(<MssqlOrder>[Col('Id').desc()])
          .paged(offset: 20, rows: 10);
      final s = base.countRows().compile();
      expect(s.sql, contains('SELECT COUNT_BIG(*) FROM ('));
      expect(s.sql, contains('FROM [dbo].[Orders] WHERE [IsOpen] = @q0'));
      expect(s.parameters, <String, Object?>{'q0': true, 'q1': 20, 'q2': 10});
      expect(s.sql, contains('ORDER BY [Id] DESC OFFSET @q1'));
      expect(s.sql, isNot(endsWith('ORDER BY [Id] DESC')));
    });
  });

  group('comparisons', () {
    test('every operator binds its value rather than writing it', () {
      final cases = <String, MssqlCondition>{
        '=': Col('A').eq(1),
        '<>': Col('A').ne(1),
        '<': Col('A').lt(1),
        '<=': Col('A').lte(1),
        '>': Col('A').gt(1),
        '>=': Col('A').gte(1),
      };
      cases.forEach((operator, condition) {
        final s = MssqlQuery.from('T').where(condition).compile();
        expect(s.sql, 'SELECT * FROM [T] WHERE [A] $operator @q0');
        expect(s.parameters, <String, Object?>{'q0': 1});
      });
    });

    test('eqCol compares two columns and binds nothing', () {
      final s = MssqlQuery.from(
        'dbo.Orders',
        as: 'o',
      ).where(Col('o.CustomerId').eqCol('c.Id')).compile();
      expect(s.sql, endsWith('WHERE [o].[CustomerId] = [c].[Id]'));
      expect(s.parameters, isEmpty);
    });

    test(
      'a bare null operand is refused, with isNull named in the message',
      () {
        for (final build in <MssqlCondition Function()>[
          () => Col('A').eq(null),
          () => Col('A').ne(null),
          () => Col('A').gt(null),
        ]) {
          expect(
            build,
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message.toString(),
                'message',
                contains('isNull()'),
              ),
            ),
          );
        }
      },
    );
  });

  group('predicates', () {
    test('null checks', () {
      final s = MssqlQuery.from('T')
          .where(and(<MssqlCondition>[Col('A').isNull(), Col('B').isNotNull()]))
          .compile();
      expect(s.sql, endsWith('WHERE ([A] IS NULL AND [B] IS NOT NULL)'));
      expect(s.parameters, isEmpty);
    });

    test('IN binds every element', () {
      final s = MssqlQuery.from(
        'T',
      ).where(Col('A').inList(<int>[1, 2, 3])).compile();
      expect(s.sql, endsWith('WHERE [A] IN (@q0, @q1, @q2)'));
      expect(s.parameters, <String, Object?>{'q0': 1, 'q1': 2, 'q2': 3});
    });

    test('NOT IN', () {
      final s = MssqlQuery.from(
        'T',
      ).where(Col('A').notInList(<int>[1])).compile();
      expect(s.sql, endsWith('WHERE [A] NOT IN (@q0)'));
    });

    test('an empty IN list is refused rather than compiled to 1 = 0', () {
      expect(() => Col('A').inList(const <int>[]), throwsArgumentError);
    });

    test('BETWEEN binds both bounds', () {
      final s = MssqlQuery.from('T').where(Col('A').between(1, 9)).compile();
      expect(s.sql, endsWith('WHERE [A] BETWEEN @q0 AND @q1'));
      expect(s.parameters, <String, Object?>{'q0': 1, 'q1': 9});
    });
  });

  group('LIKE', () {
    test('the pattern is escaped by default and declares its escape char', () {
      final s = MssqlQuery.from('T').where(Col('Code').like('50%_x')).compile();
      expect(s.sql, endsWith(r"WHERE [Code] LIKE @q0 ESCAPE '\'"));
      expect(s.parameters, <String, Object?>{'q0': r'50\%\_x'});
    });

    test('likeRaw passes the pattern through with its wildcards', () {
      final s = MssqlQuery.from(
        'T',
      ).where(Col('Code').likeRaw('TEST%')).compile();
      expect(s.sql, endsWith('WHERE [Code] LIKE @q0'));
      expect(s.sql, isNot(contains('ESCAPE')));
      expect(s.parameters, <String, Object?>{'q0': 'TEST%'});
    });

    test('NOT LIKE, both forms', () {
      expect(
        MssqlQuery.from('T').where(Col('A').notLike('x')).compile().sql,
        endsWith(r"WHERE [A] NOT LIKE @q0 ESCAPE '\'"),
      );
      expect(
        MssqlQuery.from('T').where(Col('A').notLikeRaw('x%')).compile().sql,
        endsWith('WHERE [A] NOT LIKE @q0'),
      );
    });
  });

  group('composition', () {
    test('repeated where calls are ANDed', () {
      final s = MssqlQuery.from(
        'T',
      ).where(Col('A').eq(1)).where(Col('B').eq(2)).compile();
      expect(s.sql, endsWith('WHERE ([A] = @q0 AND [B] = @q1)'));
    });

    test('a single condition is not parenthesised', () {
      final s = MssqlQuery.from('T').where(Col('A').eq(1)).compile();
      expect(s.sql, endsWith('WHERE [A] = @q0'));
    });

    test('nested and/or/not keep their grouping', () {
      final s = MssqlQuery.from('T')
          .where(
            and(<MssqlCondition>[
              Col('A').gte(100),
              or(<MssqlCondition>[Col('B').eq('x'), Col('C').isNotNull()]),
              not(Col('D').likeRaw('T%')),
            ]),
          )
          .compile();
      expect(
        s.sql,
        endsWith(
          'WHERE ([A] >= @q0 AND ([B] = @q1 OR [C] IS NOT NULL) '
          'AND NOT ([D] LIKE @q2))',
        ),
      );
    });

    test('an empty junction is refused', () {
      expect(() => and(const <MssqlCondition>[]), throwsArgumentError);
      expect(() => or(const <MssqlCondition>[]), throwsArgumentError);
    });

    test('a base query is reusable and the two do not drift', () {
      final active = MssqlQuery.from(
        'dbo.Orders',
      ).where(Col('IsOpen').eq(true));
      final page = active
          .orderBy(<MssqlOrder>[Col('Id').asc()])
          .paged(offset: 0, rows: 10);
      final total = active.countRows();
      expect(page.compile().sql, contains('WHERE [IsOpen] = @q0'));
      expect(total.compile().sql, contains('WHERE [IsOpen] = @q0'));
    });
  });

  group('joins', () {
    test('every kind renders its keyword', () {
      final kinds = <MssqlJoinKind, String>{
        MssqlJoinKind.inner: 'INNER JOIN',
        MssqlJoinKind.left: 'LEFT JOIN',
        MssqlJoinKind.right: 'RIGHT JOIN',
        MssqlJoinKind.full: 'FULL JOIN',
      };
      kinds.forEach((kind, keyword) {
        final s = MssqlQuery.from('dbo.Orders', as: 'o')
            .join(
              kind,
              'dbo.Customers',
              as: 'c',
              on: Col('o.CustomerId').eqCol('c.Id'),
            )
            .compile();
        expect(
          s.sql,
          'SELECT * FROM [dbo].[Orders] AS [o] $keyword [dbo].[Customers] AS [c] '
          'ON [o].[CustomerId] = [c].[Id]',
        );
      });
    });

    test('cross join takes no ON, and refuses one', () {
      final s = MssqlQuery.from('A').crossJoin('B').compile();
      expect(s.sql, 'SELECT * FROM [A] CROSS JOIN [B]');
      expect(
        () => MssqlQuery.from(
          'A',
        ).join(MssqlJoinKind.cross, 'B', on: Col('A.x').eqCol('B.x')),
        throwsArgumentError,
      );
    });

    test('joins keep the order they were added', () {
      final s = MssqlQuery.from('A')
          .innerJoin('B', on: Col('A.x').eqCol('B.x'))
          .leftJoin('C', on: Col('B.y').eqCol('C.y'))
          .compile();
      expect(s.sql.indexOf('INNER JOIN'), lessThan(s.sql.indexOf('LEFT JOIN')));
    });
  });

  group('grouping and aggregates', () {
    test('group by with having over an aggregate', () {
      final s = MssqlQuery.from('dbo.Orders', as: 'o')
          .select(<MssqlExpression>[
            Col('o.CustomerId'),
            sum(Col('o.Total')).as('T'),
          ])
          .groupBy(<MssqlExpression>[Col('o.CustomerId')])
          .havingCondition(sum(Col('o.Total')).gt(1000))
          .compile();
      expect(
        s.sql,
        'SELECT [o].[CustomerId], SUM([o].[Total]) AS [T] '
        'FROM [dbo].[Orders] AS [o] '
        'GROUP BY [o].[CustomerId] '
        'HAVING SUM([o].[Total]) > @q0',
      );
      expect(s.parameters, <String, Object?>{'q0': 1000});
    });

    test('the aggregate set renders', () {
      final s = MssqlQuery.from('T').select(<MssqlExpression>[
        sum(Col('A')),
        avg(Col('A')),
        min(Col('A')),
        max(Col('A')),
        count(Col('A')),
        countAll(),
      ]).compile();
      expect(
        s.sql,
        'SELECT SUM([A]), AVG([A]), MIN([A]), MAX([A]), COUNT([A]), COUNT(*) '
        'FROM [T]',
      );
    });
  });

  group('ordering and paging', () {
    test('order by renders direction for every term', () {
      final s = MssqlQuery.from(
        'T',
      ).orderBy(<MssqlOrder>[Col('A').asc(), Col('B').desc()]).compile();
      expect(s.sql, endsWith('ORDER BY [A] ASC, [B] DESC'));
    });

    test('sql2012 pages with OFFSET/FETCH', () {
      final s = MssqlQuery.from('dbo.Orders')
          .orderBy(<MssqlOrder>[Col('Id').desc()])
          .paged(offset: 20, rows: 10)
          .compile(dialect: MssqlDialect.sql2012);
      expect(
        s.sql,
        'SELECT * FROM [dbo].[Orders] ORDER BY [Id] DESC '
        'OFFSET @q0 ROWS FETCH NEXT @q1 ROWS ONLY',
      );
      expect(s.parameters, <String, Object?>{'q0': 20, 'q1': 10});
    });

    test('sql2008 pages through ROW_NUMBER with an inclusive range', () {
      final s = MssqlQuery.from('dbo.Orders')
          .select(<MssqlExpression>[Col('Id')])
          .orderBy(<MssqlOrder>[Col('Id').desc()])
          .paged(offset: 20, rows: 10)
          .compile(dialect: MssqlDialect.sql2008);
      expect(
        s.sql,
        'SELECT [mssql_orm_page].[Id] FROM ('
        'SELECT [mssql_orm_result].[Id], '
        'ROW_NUMBER() OVER (ORDER BY [mssql_orm_result].[Id] DESC) '
        'AS [mssql_orm_row] '
        'FROM (SELECT [Id] FROM [dbo].[Orders]) AS [mssql_orm_result]'
        ') AS [mssql_orm_page] '
        'WHERE [mssql_orm_page].[mssql_orm_row] BETWEEN @q0 AND @q1 '
        'ORDER BY [mssql_orm_page].[mssql_orm_row]',
      );
      expect(s.parameters, <String, Object?>{'q0': 21, 'q1': 30});
    });

    test('sql2008 paging keeps the WHERE inside the numbered subquery', () {
      final s = MssqlQuery.from('T')
          .select(<MssqlExpression>[Col('A'), Col('Id')])
          .where(Col('A').eq(1))
          .orderBy(<MssqlOrder>[Col('Id').asc()])
          .paged(offset: 0, rows: 5)
          .compile(dialect: MssqlDialect.sql2008);
      expect(
        s.sql.indexOf('WHERE [A] = @q0'),
        lessThan(s.sql.indexOf('AS [mssql_orm_page]')),
      );
      expect(s.parameters, <String, Object?>{'q0': 1, 'q1': 1, 'q2': 5});
    });

    test('paging without an order refuses to compile, in both dialects', () {
      for (final dialect in dialects) {
        expect(
          () => MssqlQuery.from(
            'dbo.Orders',
          ).paged(offset: 0, rows: 10).compile(dialect: dialect),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('orderBy()'), contains('[dbo].[Orders]')),
            ),
          ),
          reason: '$dialect',
        );
      }
    });

    test('paging arguments are checked at the call site', () {
      final q = MssqlQuery.from('T');
      expect(() => q.paged(offset: -1, rows: 10), throwsArgumentError);
      expect(() => q.paged(offset: 0, rows: 0), throwsArgumentError);
      expect(() => q.paged(offset: 0, rows: -5), throwsArgumentError);
    });
  });

  group('the raw escape hatch', () {
    test('a fragment carries its own parameters', () {
      final s = MssqlQuery.from('dbo.Orders', as: 'o')
          .where(
            raw('DATEDIFF(day, @since, o.CreatedAt) > 30', <String, Object?>{
              'since': '2026-01-01',
            }),
          )
          .compile();
      expect(s.sql, endsWith('WHERE DATEDIFF(day, @since, o.CreatedAt) > 30'));
      expect(s.parameters, <String, Object?>{'since': '2026-01-01'});
    });

    test('a fragment can project', () {
      final s = MssqlQuery.from('T').select(<MssqlExpression>[
        Col('Id'),
        raw('LEN([Name])').as('Length'),
      ]).compile();
      expect(s.sql, 'SELECT [Id], LEN([Name]) AS [Length] FROM [T]');
    });

    test('a fragment may not use the generated parameter shape', () {
      expect(
        () => MssqlQuery.from(
          'T',
        ).where(raw('A = @q0', <String, Object?>{'q0': 1})).compile(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('reserved'),
          ),
        ),
      );
    });

    test('the leading @ is optional and normalised', () {
      final s = MssqlQuery.from(
        'T',
      ).where(raw('A = @x', <String, Object?>{'@x': 5})).compile();
      expect(s.parameters, <String, Object?>{'x': 5});
    });

    test('two fragments may share a name only if they agree on the value', () {
      final agreeing = MssqlQuery.from('T')
          .where(raw('A > @from', <String, Object?>{'from': 1}))
          .where(raw('B > @from', <String, Object?>{'from': 1}))
          .compile();
      expect(agreeing.parameters, <String, Object?>{'from': 1});

      expect(
        () => MssqlQuery.from('T')
            .where(raw('A > @from', <String, Object?>{'from': 1}))
            .where(raw('B > @from', <String, Object?>{'from': 2}))
            .compile(),
        throwsArgumentError,
      );
    });

    test('generated names keep counting around a raw fragment', () {
      final s = MssqlQuery.from('T')
          .where(Col('A').eq(1))
          .where(raw('B = @b', <String, Object?>{'b': 2}))
          .where(Col('C').eq(3))
          .compile();
      expect(s.parameters, <String, Object?>{'q0': 1, 'b': 2, 'q1': 3});
    });
  });

  group('dialect selection', () {
    MssqlServerInfoStub info(String version) => MssqlServerInfoStub(version);

    test('11 and above pages with OFFSET FETCH', () {
      for (final v in <String>['11.0.2100.60', '12.0.2000', '16.0.1000.6']) {
        expect(
          MssqlDialect.forServer(info(v).value).supportsOffsetFetch,
          isTrue,
          reason: v,
        );
      }
    });

    test('below 11 does not', () {
      for (final v in <String>['10.0.1600.22', '10.50.4000.0', '9.00.5000']) {
        expect(
          MssqlDialect.forServer(info(v).value).supportsOffsetFetch,
          isFalse,
          reason: v,
        );
      }
    });

    test('an unreadable version yields the modern dialect', () {
      for (final v in <String>['', 'unknown', 'v12']) {
        expect(
          MssqlDialect.forServer(info(v).value),
          MssqlDialect.sql2012,
          reason: v,
        );
      }
    });
  });
}

class MssqlServerInfoStub {
  MssqlServerInfoStub(this.version);
  final String version;
  MssqlServerInfo get value => MssqlServerInfo(
    productVersion: version,
    productLevel: 'RTM',
    edition: 'Developer Edition',
    engineEdition: 3,
    serverName: 'SRV',
  );
}

