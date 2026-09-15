import 'package:mssql_orm/query.dart';
import 'package:test/test.dart';

const hostileValues = <String>[
  "'; DROP TABLE Users; --",
  "1 OR 1=1",
  "x'; EXEC sp_configure --",
  r"\'; SELECT @@version; --",
  "'' UNION ALL SELECT NULL --",
  '/* comment */ 1',
  "İstanbul'da",
  '\u0000null byte',
];

const hostileIdentifiers = <String>[
  'Users]; DROP TABLE Users; --',
  'Users] WHERE 1=1 --',
  "Users'",
];

void main() {
  group('values never reach the SQL text', () {
    test('through every comparison operator', () {
      for (final value in hostileValues) {
        final builders = <MssqlCondition Function()>[
          () => Col('A').eq(value),
          () => Col('A').ne(value),
          () => Col('A').lt(value),
          () => Col('A').gt(value),
          () => Col('A').lte(value),
          () => Col('A').gte(value),
        ];
        for (final build in builders) {
          final s = MssqlQuery.from('T').where(build()).compile();
          expect(s.sql, isNot(contains(value)), reason: value);
          expect(s.parameters.values, contains(value));
        }
      }
    });

    test('through IN and BETWEEN', () {
      for (final value in hostileValues) {
        final inList = MssqlQuery.from(
          'T',
        ).where(Col('A').inList(<String>[value, 'safe'])).compile();
        expect(inList.sql, isNot(contains(value)));
        expect(inList.parameters.values, contains(value));

        final between = MssqlQuery.from(
          'T',
        ).where(Col('A').between(value, value)).compile();
        expect(between.sql, isNot(contains(value)));
      }
    });

    test('through LIKE, in both the escaped and raw forms', () {
      for (final value in hostileValues) {
        for (final condition in <MssqlCondition>[
          Col('A').like(value),
          Col('A').likeRaw(value),
        ]) {
          final s = MssqlQuery.from('T').where(condition).compile();
          expect(s.sql, isNot(contains(value)), reason: value);
        }
      }
    });

    test('through INSERT, UPDATE and DELETE', () {
      for (final value in hostileValues) {
        final insert = MssqlInsert.into(
          'T',
        ).values(<String, Object?>{'A': value}).compile();
        expect(insert.sql, isNot(contains(value)));

        final update = MssqlUpdate.table('T')
            .set(<String, Object?>{'A': value})
            .where(Col('B').eq(value))
            .compile();
        expect(update.sql, isNot(contains(value)));

        final delete = MssqlDelete.from(
          'T',
        ).where(Col('B').eq(value)).compile();
        expect(delete.sql, isNot(contains(value)));
      }
    });

    test('through paging bounds', () {
      final s = MssqlQuery.from('T')
          .orderBy(<MssqlOrder>[Col('Id').asc()])
          .paged(offset: 40, rows: 20)
          .compile();
      expect(s.sql, isNot(contains('40')));
      expect(s.sql, isNot(contains('20')));
      expect(s.parameters.values, containsAll(<int>[40, 20]));
    });
  });

  group('identifiers cannot escape their quoting', () {
    void expectContained(String sql, String identifier) {
      final bare = sql.replaceAll(RegExp(r'\[(?:[^\]]|\]\])*\]'), '');
      expect(
        bare,
        allOf(
          isNot(contains('DROP')),
          isNot(contains('--')),
          isNot(contains("'")),
        ),
        reason: '$identifier -> $sql',
      );
    }

    test('a hostile table name stays inside its quoting, or is refused', () {
      for (final identifier in hostileIdentifiers) {
        try {
          expectContained(
            MssqlQuery.from(identifier).compile().sql,
            identifier,
          );
        } on ArgumentError {
          continue;
        }
      }
    });

    test('a hostile column name stays inside its quoting, or is refused', () {
      for (final identifier in hostileIdentifiers) {
        try {
          expectContained(
            MssqlQuery.from('T').where(Col(identifier).eq(1)).compile().sql,
            identifier,
          );
        } on ArgumentError {
          continue;
        }
      }
    });

    test('a hostile alias stays inside its quoting, or is refused', () {
      for (final identifier in hostileIdentifiers) {
        try {
          expectContained(
            MssqlQuery.from(
              'T',
            ).select(<MssqlExpression>[Col('A').as(identifier)]).compile().sql,
            identifier,
          );
        } on ArgumentError {
          continue;
        }
      }
    });

    test('the stripper itself notices text outside the quoting', () {
      expect(
        () => expectContained("SELECT * FROM [T]; DROP TABLE Users; --", 'x'),
        throwsA(isA<TestFailure>()),
      );
    });
  });

  group('LIKE wildcards', () {
    test('a search box % matches a literal %, not everything', () {
      final s = MssqlQuery.from('T').where(Col('Code').like('50%')).compile();
      expect(s.parameters['q0'], r'50\%');
      expect(s.sql, contains(r"ESCAPE '\'"));
    });

    test('every wildcard character is escaped', () {
      final s = MssqlQuery.from('T').where(Col('A').like(r'%_[]\')).compile();
      expect(s.parameters['q0'], r'\%\_\[]\\');
    });

    test(
      'likeRaw is the named opt-out, so the unsafe form is never silent',
      () {
        final s = MssqlQuery.from('T').where(Col('A').likeRaw('%x%')).compile();
        expect(s.parameters['q0'], '%x%');
      },
    );
  });

  group('the raw escape hatch stays a deliberate act', () {
    test('a raw fragment is the only text the caller controls', () {
      final s = MssqlQuery.from('T')
          .where(
            raw('LEN([A]) > @n', <String, Object?>{'n': hostileValues.first}),
          )
          .compile();
      expect(s.sql, contains('LEN([A]) > @n'));
      expect(s.sql, isNot(contains('DROP')));
      expect(s.parameters['n'], hostileValues.first);
    });

    test('free-form SQL tokens reject statement-breaking text', () {
      expect(
        () => MssqlFunction('SUM); DROP TABLE T; --', <MssqlExpression>[]),
        throwsArgumentError,
      );
      expect(
        () => MssqlComparison(
          Col('A'),
          '= 1; DROP TABLE T; --',
          const MssqlLiteral(1),
        ),
        throwsArgumentError,
      );
      expect(
        () => MssqlJunction('OR 1=1 --', <MssqlCondition>[
          Col('A').eq(1),
          Col('B').eq(2),
        ]),
        throwsArgumentError,
      );
      expect(
        () => MssqlCast(Col('A'), 'int); DROP TABLE T; --'),
        throwsArgumentError,
      );
    });

    test('a caller-authored table hint marks the statement raw', () {
      final statement = MssqlQuery.from('T').withHint('NOLOCK').compile();

      expect(statement.containsRawSql, isTrue);
    });
  });
}

