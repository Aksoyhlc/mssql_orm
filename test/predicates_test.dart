import 'package:mssql_orm/query.dart';
import 'package:test/test.dart';

MssqlStatement of(MssqlCondition condition) =>
    MssqlQuery.from('T').where(condition).compile();

void main() {
  group('whereColumn with an operator', () {
    test('compares two columns and binds nothing', () {
      final s = of(whereColumn('a.Start', MssqlOperator.lte, 'a.End'));
      expect(s.sql, endsWith('WHERE [a].[Start] <= [a].[End]'));
      expect(s.parameters, isEmpty);
    });

    test('every operator renders', () {
      final expected = <MssqlOperator, String>{
        MssqlOperator.eq: '=',
        MssqlOperator.ne: '<>',
        MssqlOperator.lt: '<',
        MssqlOperator.lte: '<=',
        MssqlOperator.gt: '>',
        MssqlOperator.gte: '>=',
      };
      expected.forEach((operator, sql) {
        expect(
          of(whereColumn('A', operator, 'B')).sql,
          endsWith('WHERE [A] $sql [B]'),
          reason: operator.name,
        );
      });
    });
  });

  group('between', () {
    test('NOT BETWEEN binds both bounds', () {
      final s = of(Col('A').notBetween(1, 9));
      expect(s.sql, endsWith('WHERE [A] NOT BETWEEN @q0 AND @q1'));
      expect(s.parameters, <String, Object?>{'q0': 1, 'q1': 9});
    });

    test('between two columns binds nothing', () {
      final s = of(Col('Value').betweenColumns('Low', 'High'));
      expect(s.sql, endsWith('WHERE [Value] BETWEEN [Low] AND [High]'));
      expect(s.parameters, isEmpty);
    });

    test('and its negation', () {
      expect(
        of(Col('Value').notBetweenColumns('Low', 'High')).sql,
        endsWith('WHERE [Value] NOT BETWEEN [Low] AND [High]'),
      );
    });
  });

  group('date parts', () {
    test('whereDate casts the column, so the whole day matches', () {
      final s = of(Col('CreatedAt').whereDate(DateTime(2026, 9, 7)));
      expect(s.sql, endsWith('WHERE CAST([CreatedAt] AS date) = @q0'));
    });

    test('the bound value is narrowed to a date too', () {
      final s = of(Col('CreatedAt').whereDate(DateTime(2026, 9, 7)));
      expect(s.parameters['q0'].toString(), contains('MssqlValue'));
    });

    test('year, month and day use their own functions', () {
      expect(
        of(Col('CreatedAt').whereYear(2026)).sql,
        endsWith('WHERE YEAR([CreatedAt]) = @q0'),
      );
      expect(
        of(Col('CreatedAt').whereMonth(9)).sql,
        endsWith('WHERE MONTH([CreatedAt]) = @q0'),
      );
      expect(
        of(Col('CreatedAt').whereDay(7)).sql,
        endsWith('WHERE DAY([CreatedAt]) = @q0'),
      );
    });

    test('whereTime casts to time', () {
      expect(
        of(Col('CreatedAt').whereTime(DateTime(2026, 1, 1, 9))).sql,
        endsWith('WHERE CAST([CreatedAt] AS time) = @q0'),
      );
    });

    test('an operator can be given', () {
      expect(
        of(Col('CreatedAt').whereYear(2026, MssqlOperator.gte)).sql,
        endsWith('WHERE YEAR([CreatedAt]) >= @q0'),
      );
    });
  });

  group('relative to now', () {
    test('today is the server\'s today, not the application\'s', () {
      final s = of(Col('CreatedAt').whereToday());
      expect(
        s.sql,
        endsWith('WHERE CAST([CreatedAt] AS date) = CAST(GETDATE() AS date)'),
      );
      expect(s.parameters, isEmpty);
    });

    test('the four relative-to-today forms', () {
      final expected = <MssqlCondition, String>{
        Col('D').whereBeforeToday(): '<',
        Col('D').whereAfterToday(): '>',
        Col('D').whereTodayOrBefore(): '<=',
        Col('D').whereTodayOrAfter(): '>=',
      };
      expected.forEach((condition, operator) {
        expect(
          of(condition).sql,
          endsWith('CAST([D] AS date) $operator CAST(GETDATE() AS date)'),
        );
      });
    });

    test(
      'past and future compare against the server clock, not a bound value',
      () {
        expect(of(Col('D').wherePast()).sql, endsWith('[D] < SYSDATETIME()'));
        expect(of(Col('D').whereFuture()).sql, endsWith('[D] > SYSDATETIME()'));
        expect(
          of(Col('D').whereNowOrPast()).sql,
          endsWith('[D] <= SYSDATETIME()'),
        );
        expect(
          of(Col('D').whereNowOrFuture()).sql,
          endsWith('[D] >= SYSDATETIME()'),
        );
        expect(of(Col('D').wherePast()).parameters, isEmpty);
      },
    );
  });

  group('whereAny / whereAll / whereNone', () {
    test('any is an OR group, with the value bound once per column', () {
      final s = of(
        whereAny(<String>['Name', 'Code', 'Note'], (c) => c.like('ali')),
      );
      expect(
        s.sql,
        endsWith(
          r"WHERE ([Name] LIKE @q0 ESCAPE '\' OR [Code] LIKE @q1 ESCAPE '\' "
          r"OR [Note] LIKE @q2 ESCAPE '\')",
        ),
      );
      expect(s.parameters.values, everyElement('ali'));
    });

    test('all is an AND group', () {
      final s = of(whereAll(<String>['A', 'B'], (c) => c.isNotNull()));
      expect(s.sql, endsWith('WHERE ([A] IS NOT NULL AND [B] IS NOT NULL)'));
    });

    test('none negates the OR group', () {
      final s = of(whereNone(<String>['A', 'B'], (c) => c.eq(1)));
      expect(s.sql, endsWith('WHERE NOT ([A] = @q0 OR [B] = @q1)'));
    });

    test('an empty column list is refused', () {
      expect(
        () => whereAny(const <String>[], (c) => c.isNull()),
        throwsArgumentError,
      );
    });

    test('the group composes with the rest of the where clause', () {
      final s = MssqlQuery.from('T')
          .where(Col('IsActive').eq(true))
          .where(whereAny(<String>['A', 'B'], (c) => c.like('x')))
          .compile();
      expect(s.sql, contains('WHERE ([IsActive] = @q0 AND ('));
    });
  });

  group('contains, startsWith, endsWith', () {
    test('contains wraps the escaped term in wildcards', () {
      final s = of(Col('Name').contains('ali'));
      expect(s.sql, endsWith(r"WHERE [Name] LIKE @q0 ESCAPE '\'"));
      expect(s.parameters['q0'], '%ali%');
    });

    test('a wildcard the user typed stays literal', () {
      final s = of(Col('Name').contains('50%'));
      expect(s.parameters['q0'], r'%50\%%');
    });

    test('startsWith and endsWith put the wildcard on one side', () {
      expect(of(Col('Name').startsWith('A-')).parameters['q0'], 'A-%');
      expect(of(Col('Name').endsWith('.pdf')).parameters['q0'], '%.pdf');
    });

    test('notContains negates it', () {
      final s = of(Col('Name').notContains('x'));
      expect(s.sql, contains('NOT LIKE'));
      expect(s.parameters['q0'], '%x%');
    });

    test('like is still an exact match', () {
      expect(of(Col('Name').like('ali')).parameters['q0'], 'ali');
    });

    test('the escape clause is declared for all of them', () {
      for (final condition in <MssqlCondition>[
        Col('A').contains('x'),
        Col('A').startsWith('x'),
        Col('A').endsWith('x'),
      ]) {
        expect(of(condition).sql, contains(r"ESCAPE '\'"));
      }
    });
  });

  group('when / unless / whenNotNull', () {
    MssqlQuery filtered({String? search, int? minimum}) => MssqlQuery.from('T')
        .whenNotNull(search, (q, s) => q.where(Col('Name').like(s)))
        .whenNotNull(minimum, (q, m) => q.where(Col('Total').gte(m)));

    test('a null filter adds nothing', () {
      expect(filtered().compile().sql, 'SELECT * FROM [T]');
    });

    test('each filter that is set adds its own clause', () {
      final s = filtered(search: 'ali', minimum: 5).compile();
      expect(s.sql, contains('[Name] LIKE @q0'));
      expect(s.sql, contains('[Total] >= @q1'));
    });

    test('only the ones that are set', () {
      final s = filtered(minimum: 5).compile();
      expect(s.sql, isNot(contains('LIKE')));
      expect(s.sql, contains('[Total] >= @q0'));
    });

    test('when takes an else branch', () {
      final s = MssqlQuery.from('T')
          .when(
            false,
            (q) => q.where(Col('A').eq(1)),
            otherwise: (q) => q.where(Col('B').eq(2)),
          )
          .compile();
      expect(s.sql, endsWith('WHERE [B] = @q0'));
    });

    test('unless is when, inverted', () {
      final s = MssqlQuery.from(
        'T',
      ).unless(false, (q) => q.where(Col('A').eq(1))).compile();
      expect(s.sql, endsWith('WHERE [A] = @q0'));
    });

    test('the query stays immutable through a false branch', () {
      final base = MssqlQuery.from('T');
      base.when(true, (q) => q.where(Col('A').eq(1)));
      expect(base.compile().sql, 'SELECT * FROM [T]');
    });
  });

  group('top', () {
    test('renders TOP and binds the count', () {
      final s = MssqlQuery.from('T').top(5).compile();
      expect(s.sql, 'SELECT TOP (@q0) * FROM [T]');
      expect(s.parameters, <String, Object?>{'q0': 5});
    });

    test('needs no ordering, unlike paging', () {
      expect(() => MssqlQuery.from('T').top(10).compile(), returnsNormally);
    });

    test('a non-positive count is refused', () {
      expect(() => MssqlQuery.from('T').top(0), throwsArgumentError);
      expect(() => MssqlQuery.from('T').top(-1), throwsArgumentError);
    });

    test('top and paged together are refused, since both limit the query', () {
      expect(
        () => MssqlQuery.from('T')
            .orderBy(<MssqlOrder>[Col('Id').asc()])
            .top(5)
            .paged(offset: 0, rows: 10)
            .compile(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('both limit'),
          ),
        ),
      );
    });

    test('top survives into the sql2008 subquery', () {
      final s = MssqlQuery.from(
        'T',
      ).top(3).compile(dialect: MssqlDialect.sql2008);
      expect(s.sql, contains('TOP (@q0)'));
    });
  });
}

