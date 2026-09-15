import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_executor.dart';

void main() {
  group('INSERT SELECT', () {
    test('shares bindings with the source query and executes once', () async {
      final query = MssqlQuery.from('dbo.Source')
          .select(<MssqlExpression>[Col('Name'), Col('Score')])
          .where(Col('TenantId').eq(7));
      final insert = MssqlInsert.into(
        'dbo.Target',
      ).using(<String>['Name', 'Score'], query);
      final statement = insert.compile();

      expect(
        statement.sql,
        startsWith('INSERT INTO [dbo].[Target] ([Name], [Score]) SELECT'),
      );
      expect(statement.parameters, <String, Object?>{'q0': 7});
      final fake = FakeExecutor()..affected.add(4);
      expect(await insert.run(fake), 4);
      expect(fake.calls, hasLength(1));
    });

    test('rejects empty, duplicate and mismatched target columns', () {
      final one = MssqlQuery.from(
        'dbo.Source',
      ).select(<MssqlExpression>[Col('Name')]);
      expect(
        () => MssqlInsert.into('dbo.T').using(const <String>[], one),
        throwsArgumentError,
      );
      expect(
        () => MssqlInsert.into('dbo.T').using(<String>['Name', 'name'], one),
        throwsArgumentError,
      );
      expect(
        () => MssqlInsert.into(
          'dbo.T',
        ).using(<String>['Name', 'Score'], one).compile(),
        throwsStateError,
      );
    });
  });

  group('upsert', () {
    test(
      'uses guarded UPDATE and INSERT, never MERGE or interpolated values',
      () {
        const hostile = "x'); DROP TABLE dbo.Users; --";
        final statement = MssqlUpsert.into(
          'dbo.Users',
          matching: const <String, Object?>{'Email': 'a@example.test'},
          insertValues: const <String, Object?>{
            'Email': 'a@example.test',
            'Name': hostile,
          },
          updateValues: const <String, Object?>{'Name': hostile},
        ).compile();

        expect(statement.sql.toUpperCase(), isNot(contains('MERGE')));
        expect(statement.sql, contains('WITH (UPDLOCK, HOLDLOCK)'));
        expect(statement.sql, isNot(contains(hostile)));
        expect(statement.parameters.values, contains(hostile));
        expect(statement.parameters.length, 7);
      },
    );

    test('allows an insert-only guarded path', () {
      final statement = MssqlUpsert.into(
        'dbo.Users',
        matching: const <String, Object?>{'Email': 'a@example.test'},
        insertValues: const <String, Object?>{'Email': 'a@example.test'},
        updateValues: const <String, Object?>{},
      ).compile();
      expect(statement.sql, startsWith('INSERT INTO'));
      expect(statement.sql, isNot(contains('@@ROWCOUNT')));
    });

    test('matches a nullable conflict key with IS NULL', () {
      final statement = MssqlUpsert.into(
        'dbo.Users',
        matching: const <String, Object?>{'ExternalId': null},
        insertValues: const <String, Object?>{'ExternalId': null, 'Name': 'A'},
        updateValues: const <String, Object?>{'Name': 'A'},
      ).compile();

      expect(statement.sql, contains('[ExternalId] IS NULL'));
      expect(statement.sql, isNot(contains('[ExternalId] =')));
    });

    test('rejects missing conflict keys and incomplete insert values', () {
      expect(
        () => MssqlUpsert.into(
          'dbo.Users',
          matching: const <String, Object?>{},
          insertValues: const <String, Object?>{'Email': 'a'},
          updateValues: const <String, Object?>{},
        ),
        throwsArgumentError,
      );
      expect(
        () => MssqlUpsert.into(
          'dbo.Users',
          matching: const <String, Object?>{'Email': 'a'},
          insertValues: const <String, Object?>{'Name': 'A'},
          updateValues: const <String, Object?>{},
        ),
        throwsArgumentError,
      );
      expect(
        () => MssqlUpsert.into(
          'dbo.Users',
          matching: const <String, Object?>{'Email': 'a'},
          insertValues: const <String, Object?>{'Email': 'b'},
          updateValues: const <String, Object?>{},
        ),
        throwsArgumentError,
      );
    });

    test('executes as one statement', () async {
      final fake = FakeExecutor()..affected.add(1);
      final upsert = MssqlUpsert.into(
        'dbo.Users',
        matching: const <String, Object?>{'Email': 'a'},
        insertValues: const <String, Object?>{'Email': 'a'},
        updateValues: const <String, Object?>{},
      );
      expect(await upsert.run(fake), 1);
      expect(fake.calls, hasLength(1));
    });
  });
}
