import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_executor.dart';

MssqlQuery get base => MssqlQuery.from('dbo.Users');

List<Map<String, Object?>> rows(int count) => <Map<String, Object?>>[
  for (var i = 1; i <= count; i++) <String, Object?>{'Id': i, 'Name': 'n$i'},
];

void main() {
  group('reading', () {
    test('get sends the compiled query and marks it idempotent', () async {
      final fake = FakeExecutor()..replies.add(rows(2));
      final result = await base.get(fake);
      expect(result, hasLength(2));
      expect(fake.onlyCall.sql, 'SELECT * FROM [dbo].[Users]');
      expect(fake.onlyCall.idempotent, isTrue);
    });

    test('getAs maps every row', () async {
      final fake = FakeExecutor()..replies.add(rows(2));
      final names = await base.getAs(fake, (r) => r['Name']! as String);
      expect(names, <String>['n1', 'n2']);
    });

    test('first adds TOP (1) so the server stops early', () async {
      final fake = FakeExecutor()..replies.add(rows(1));
      await base.first(fake);
      expect(fake.onlyCall.sql, startsWith('SELECT TOP (@q0)'));
    });

    test('first leaves an existing limit alone', () async {
      final fake = FakeExecutor()..replies.add(rows(1));
      await base
          .orderBy(<MssqlOrder>[Col('Id').asc()])
          .paged(offset: 10, rows: 5)
          .first(fake);
      expect(fake.onlyCall.sql, contains('OFFSET'));
      expect(fake.onlyCall.sql, isNot(contains('TOP')));
    });

    test('first returns null for no row; firstOrFail throws', () async {
      expect(await base.first(FakeExecutor()), isNull);
      await expectLater(base.firstOrFail(FakeExecutor()), throwsStateError);
    });

    test('value reads one column of the first row', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Name': 'ali'},
        ]);
      expect(await base.value<String>(fake, 'Name'), 'ali');
      expect(fake.onlyCall.sql, startsWith('SELECT TOP (@q0) [Name]'));
    });

    test('pluck reads one column of every row', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Name': 'a'},
          <String, Object?>{'Name': 'b'},
        ]);
      expect(await base.pluck<String>(fake, 'Name'), <String>['a', 'b']);
      expect(fake.onlyCall.sql, 'SELECT [Name] FROM [dbo].[Users]');
    });
  });

  group('existence and aggregates', () {
    test('exists asks for one row, not for a count', () async {
      final fake = FakeExecutor()..replies.add(rows(1));
      expect(await base.where(Col('A').eq(1)).exists(fake), isTrue);
      expect(fake.onlyCall.sql, startsWith('SELECT TOP (@q0) 1 FROM'));
      expect(fake.onlyCall.sql, isNot(contains('COUNT')));
    });

    test('exists is false for no rows, and doesntExist inverts it', () async {
      expect(await base.exists(FakeExecutor()), isFalse);
      expect(await base.doesntExist(FakeExecutor()), isTrue);
    });

    test('count builds COUNT(*)', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'': 42},
        ]);
      expect(await base.count(fake), 42);
      expect(fake.onlyCall.sql, 'SELECT COUNT_BIG(*) FROM [dbo].[Users]');
    });

    test('the aggregates each render their function', () async {
      for (final entry in <String, Future<Object?> Function(FakeExecutor)>{
        'SUM': (f) => base.sum<int>(f, 'Total'),
        'AVG': (f) => base.avg<double>(f, 'Total'),
        'MIN': (f) => base.min<int>(f, 'Total'),
        'MAX': (f) => base.max<int>(f, 'Total'),
      }.entries) {
        final fake = FakeExecutor()
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{'': 7},
          ]);
        await entry.value(fake);
        expect(
          fake.onlyCall.sql,
          'SELECT ${entry.key}([Total]) FROM [dbo].[Users]',
        );
      }
    });

    test('an aggregate over no rows is null, not zero', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'': null},
        ]);
      expect(await base.avg<double>(fake, 'Total'), isNull);
    });

    test('a numeric aggregate is widened to the type asked for', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'': 7},
        ]);
      expect(await base.avg<double>(fake, 'Total'), 7.0);
    });
  });

  group('chunk and lazy', () {
    MssqlQuery ordered() => base.orderBy(<MssqlOrder>[Col('Id').asc()]);

    test('walks page by page and stops on a short page', () async {
      final fake = FakeExecutor()
        ..replies.add(rows(3))
        ..replies.add(rows(3))
        ..replies.add(rows(1));
      final seen = <int>[];
      await ordered().chunk(fake, 3, (page) async {
        seen.add(page.length);
        return true;
      });
      expect(seen, <int>[3, 3, 1]);
      expect(fake.calls, hasLength(3));
    });

    test('a callback returning false stops the walk early', () async {
      final fake = FakeExecutor()
        ..replies.add(rows(3))
        ..replies.add(rows(3));
      var pages = 0;
      await ordered().chunk(fake, 3, (page) async {
        pages++;
        return false;
      });
      expect(pages, 1);
      expect(fake.calls, hasLength(1));
    });

    test('an exactly-full last page costs one more empty query', () async {
      final fake = FakeExecutor()
        ..replies.add(rows(2))
        ..replies.add(<Map<String, Object?>>[]);
      await ordered().chunk(fake, 2, (page) async => true);
      expect(fake.calls, hasLength(2));
    });

    test('chunking without an ordering is refused', () async {
      await expectLater(
        base.chunk(FakeExecutor(), 10, (page) async => true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('orderBy()'),
          ),
        ),
      );
    });

    test('lazy yields every row across pages', () async {
      final fake = FakeExecutor()
        ..replies.add(rows(2))
        ..replies.add(rows(1));
      final ids = <Object?>[];
      await for (final row in ordered().lazy(fake, size: 2)) {
        ids.add(row['Id']);
      }
      expect(ids, hasLength(3));
    });

    test('a non-positive page size is refused', () async {
      await expectLater(
        ordered().chunk(FakeExecutor(), 0, (page) async => true),
        throwsArgumentError,
      );
    });
  });

  group('running DML', () {
    test('insert, update and delete each report affected rows', () async {
      final fake = FakeExecutor()..affected.addAll(<int>[1, 2, 3]);
      expect(
        await MssqlInsert.into('T').values(<String, Object?>{'A': 1}).run(fake),
        1,
      );
      expect(
        await MssqlUpdate.table(
          'T',
        ).set(<String, Object?>{'A': 1}).where(Col('B').eq(2)).run(fake),
        2,
      );
      expect(await MssqlDelete.from('T').where(Col('B').eq(2)).run(fake), 3);
      expect(fake.calls, hasLength(3));
    });

    test('a write is not marked idempotent', () async {
      final fake = FakeExecutor()..affected.add(1);
      await MssqlDelete.from('T').allRows().run(fake);
      expect(fake.onlyCall.idempotent, isFalse);
    });
  });
}

