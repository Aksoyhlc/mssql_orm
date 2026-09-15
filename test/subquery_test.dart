import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_executor.dart';

void main() {
  group('subqueries', () {
    test('share one parameter allocator with the outer query', () {
      final children = MssqlQuery.from('dbo.Children')
          .select(<MssqlExpression>[Col('ParentId')])
          .where(Col('Kind').eq('active'));
      final statement = MssqlQuery.from('dbo.Parents')
          .select(<MssqlExpression>[Col('Id')])
          .where(Col('Id').inQuery(children))
          .where(Col('TenantId').eq(7))
          .compile();

      expect(statement.sql, contains('[Kind] = @q0'));
      expect(statement.sql, contains('[TenantId] = @q1'));
      expect(statement.parameters, <String, Object?>{'q0': 'active', 'q1': 7});
    });

    test('supports correlated EXISTS and NOT EXISTS', () {
      final child = MssqlQuery.from('dbo.Children', as: 'c')
          .select(<MssqlExpression>[raw('1')])
          .where(whereColumn('c.ParentId', MssqlOperator.eq, 'p.Id'));

      expect(
        MssqlQuery.from(
          'dbo.Parents',
          as: 'p',
        ).whereExists(child).compile().sql,
        contains(
          'EXISTS (SELECT 1 FROM [dbo].[Children] AS [c] WHERE [c].[ParentId] = [p].[Id])',
        ),
      );
      expect(
        MssqlQuery.from(
          'dbo.Parents',
          as: 'p',
        ).whereNotExists(child).compile().sql,
        contains('NOT EXISTS (SELECT 1 FROM [dbo].[Children] AS [c]'),
      );
    });

    test(
      'IN and scalar subqueries require exactly one projected expression',
      () {
        final star = MssqlQuery.from('dbo.Children');
        final two = star.select(<MssqlExpression>[Col('Id'), Col('Name')]);

        expect(
          () => MssqlQuery.from(
            'dbo.Parents',
          ).where(Col('Id').inQuery(star)).compile(),
          throwsStateError,
        );
        expect(
          () => MssqlQuery.from(
            'dbo.Parents',
          ).select(<MssqlExpression>[scalarSubquery(two)]).compile(),
          throwsStateError,
        );
      },
    );

    test('fromSub and joinSub quote aliases and preserve parameter order', () {
      final source = MssqlQuery.from('dbo.Orders')
          .select(<MssqlExpression>[Col('CustomerId')])
          .where(Col('Status').eq('open'));
      final statement = MssqlQuery.fromSub(source, as: 'recent')
          .select(<MssqlExpression>[Col('recent.CustomerId')])
          .joinSub(
            MssqlJoinKind.inner,
            MssqlQuery.from(
              'dbo.Customers',
            ).select(<MssqlExpression>[Col('Id')]),
            as: 'customers',
            on: whereColumn(
              'recent.CustomerId',
              MssqlOperator.eq,
              'customers.Id',
            ),
          )
          .where(Col('recent.CustomerId').gt(10))
          .compile();

      expect(statement.sql, contains(') AS [recent] INNER JOIN ('));
      expect(statement.sql, contains(') AS [customers] ON'));
      expect(statement.parameters, <String, Object?>{'q0': 'open', 'q1': 10});
    });

    test('rejects table hints on a derived-table source', () {
      final nested = MssqlQuery.from(
        'dbo.Children',
      ).select(<MssqlExpression>[Col('Id')]);
      final derived = MssqlQuery.fromSub(nested, as: 'children');

      expect(() => derived.withHint('NOLOCK'), throwsStateError);
      expect(() => derived.sharedLock(), throwsStateError);
      expect(() => derived.lockForUpdate(), throwsStateError);
    });

    test('rejects invalid joinSub ON combinations', () {
      final nested = MssqlQuery.from(
        'dbo.Children',
      ).select(<MssqlExpression>[Col('Id')]);
      expect(
        () => MssqlQuery.from(
          'dbo.Parents',
        ).joinSub(MssqlJoinKind.inner, nested, as: 'c'),
        throwsArgumentError,
      );
      expect(
        () => MssqlQuery.from('dbo.Parents').joinSub(
          MssqlJoinKind.cross,
          nested,
          as: 'c',
          on: Col('Id').eqCol('c.Id'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('set queries', () {
    MssqlQuery member(String table, int tenant) => MssqlQuery.from(
      table,
    ).select(<MssqlExpression>[Col('Id')]).where(Col('TenantId').eq(tenant));

    test('chains UNION and UNION ALL without parameter collisions', () {
      final statement = member(
        'dbo.A',
        1,
      ).union(member('dbo.B', 2)).unionAll(member('dbo.C', 3)).compile();
      expect(statement.sql, contains(' UNION '));
      expect(statement.sql, contains(' UNION ALL '));
      expect(statement.parameters, <String, Object?>{
        'q0': 1,
        'q1': 2,
        'q2': 3,
      });
    });

    test('rejects different known projection counts', () {
      final one = MssqlQuery.from('dbo.A').select(<MssqlExpression>[Col('Id')]);
      final two = MssqlQuery.from(
        'dbo.B',
      ).select(<MssqlExpression>[Col('Id'), Col('Name')]);
      expect(() => one.union(two).compile(), throwsStateError);
    });

    test('puts ordering and paging on the complete set', () {
      final statement = member('dbo.A', 1)
          .unionAll(member('dbo.B', 2))
          .orderBy(<MssqlOrder>[Col('Id').desc()])
          .paged(offset: 20, rows: 10)
          .compile();
      expect(
        statement.sql,
        endsWith('ORDER BY [Id] DESC OFFSET @q2 ROWS FETCH NEXT @q3 ROWS ONLY'),
      );
      expect(statement.parameters['q2'], 20);
      expect(statement.parameters['q3'], 10);
    });

    test('rejects member ordering and SQL Server 2008 paging', () {
      final ordered = MssqlQuery.from('dbo.A')
          .select(<MssqlExpression>[Col('Id')])
          .orderBy(<MssqlOrder>[Col('Id').asc()]);
      final plain = MssqlQuery.from(
        'dbo.B',
      ).select(<MssqlExpression>[Col('Id')]);
      expect(() => ordered.union(plain).compile(), throwsStateError);
      expect(
        () => plain
            .union(plain)
            .orderBy(<MssqlOrder>[Col('Id').asc()])
            .paged(offset: 0, rows: 10)
            .compile(dialect: MssqlDialect.sql2008),
        throwsA(isA<MssqlCapabilityException>()),
      );
    });

    test('rejects a bare ORDER BY when the set is nested', () {
      final first = MssqlQuery.from(
        'dbo.A',
      ).select(<MssqlExpression>[Col('Id')]);
      final second = MssqlQuery.from(
        'dbo.B',
      ).select(<MssqlExpression>[Col('Id')]);
      final ordered = first.unionAll(second).orderBy(<MssqlOrder>[
        Col('Id').asc(),
      ]);

      expect(
        () => MssqlQuery.fromSub(ordered, as: 'ids').compile(),
        throwsStateError,
      );
    });

    test('runs as an idempotent select', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await member('dbo.A', 1).unionAll(member('dbo.B', 2)).get(fake);
      expect(fake.onlyCall.idempotent, isTrue);
    });
  });
}

