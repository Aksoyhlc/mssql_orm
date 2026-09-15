import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

void main() {
  group('insert', () {
    test('columns are quoted and values bound, in call order', () {
      final s = MssqlInsert.into(
        'dbo.Users',
      ).values(<String, Object?>{'Name': 'Ali', 'IsActive': true}).compile();
      expect(
        s.sql,
        'INSERT INTO [dbo].[Users] ([Name], [IsActive]) VALUES (@q0, @q1)',
      );
      expect(s.parameters, <String, Object?>{'q0': 'Ali', 'q1': true});
    });

    test('repeated values calls merge, last write winning', () {
      final s = MssqlInsert.into('T').values(<String, Object?>{'A': 1}).values(
        <String, Object?>{'B': 2, 'A': 3},
      ).compile();
      expect(s.parameters, <String, Object?>{'q0': 3, 'q1': 2});
    });

    test('an insert with no values refuses to compile', () {
      expect(
        () => MssqlInsert.into('dbo.Users').compile(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('[dbo].[Users]'),
          ),
        ),
      );
    });

    test('a null value binds rather than being refused', () {
      final s = MssqlInsert.into(
        'T',
      ).values(<String, Object?>{'A': null}).compile();
      expect(s.sql, 'INSERT INTO [T] ([A]) VALUES (@q0)');
      expect(s.parameters, <String, Object?>{'q0': null});
    });
  });

  group('update', () {
    test('sets and predicate, with values bound in that order', () {
      final s = MssqlUpdate.table(
        'dbo.Users',
      ).set(<String, Object?>{'Name': 'Veli'}).where(Col('Id').eq(5)).compile();
      expect(s.sql, 'UPDATE [dbo].[Users] SET [Name] = @q0 WHERE [Id] = @q1');
      expect(s.parameters, <String, Object?>{'q0': 'Veli', 'q1': 5});
    });

    test('repeated where calls are ANDed', () {
      final s = MssqlUpdate.table('T')
          .set(<String, Object?>{'A': 1})
          .where(Col('B').eq(2))
          .where(Col('C').eq(3))
          .compile();
      expect(s.sql, endsWith('WHERE ([B] = @q1 AND [C] = @q2)'));
    });

    test('without a predicate it refuses, and names the way out', () {
      expect(
        () => MssqlUpdate.table(
          'dbo.Users',
        ).set(<String, Object?>{'A': 1}).compile(),
        throwsA(
          isA<MssqlUnsafeWriteException>().having(
            (e) => e.message,
            'message',
            allOf(contains('[dbo].[Users]'), contains('allRows()')),
          ),
        ),
      );
    });

    test('whereAll is accepted and writes no WHERE', () {
      final s = MssqlUpdate.table(
        'T',
      ).set(<String, Object?>{'A': 1}).allRows().compile();
      expect(s.sql, 'UPDATE [T] SET [A] = @q0');
    });

    test('where and whereAll together contradict and are refused', () {
      expect(
        () => MssqlUpdate.table('T')
            .set(<String, Object?>{'A': 1})
            .where(Col('B').eq(2))
            .allRows()
            .compile(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('contradict'),
          ),
        ),
      );
    });

    test('an update that sets nothing refuses to compile', () {
      expect(
        () => MssqlUpdate.table('T').where(Col('A').eq(1)).compile(),
        throwsStateError,
      );
    });
  });

  group('delete', () {
    test('predicate', () {
      final s = MssqlDelete.from('dbo.Users').where(Col('Id').eq(5)).compile();
      expect(s.sql, 'DELETE FROM [dbo].[Users] WHERE [Id] = @q0');
      expect(s.parameters, <String, Object?>{'q0': 5});
    });

    test('without a predicate it refuses, and names the way out', () {
      expect(
        () => MssqlDelete.from('dbo.Users').compile(),
        throwsA(
          isA<MssqlUnsafeWriteException>().having(
            (e) => e.message,
            'message',
            allOf(contains('[dbo].[Users]'), contains('allRows()')),
          ),
        ),
      );
    });

    test('whereAll is accepted', () {
      expect(MssqlDelete.from('T').allRows().compile().sql, 'DELETE FROM [T]');
    });

    test('where and whereAll together are refused', () {
      expect(
        () => MssqlDelete.from('T').where(Col('A').eq(1)).allRows().compile(),
        throwsStateError,
      );
    });
  });

  group('immutability', () {
    test('a builder is not mutated by the calls chained off it', () {
      final base = MssqlUpdate.table('T').set(<String, Object?>{'A': 1});
      base.where(Col('B').eq(2));
      expect(() => base.compile(), throwsA(isA<MssqlUnsafeWriteException>()));

      final baseDelete = MssqlDelete.from('T');
      baseDelete.where(Col('B').eq(2));
      expect(
        () => baseDelete.compile(),
        throwsA(isA<MssqlUnsafeWriteException>()),
      );

      final baseInsert = MssqlInsert.into('T');
      baseInsert.values(<String, Object?>{'A': 1});
      expect(() => baseInsert.compile(), throwsStateError);
    });
  });
}

