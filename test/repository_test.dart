import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_driver.dart';
import 'support/fake_executor.dart';

class UserRow {
  const UserRow({
    required this.id,
    required this.name,
    this.email,
    this.createdAt,
    this.netTotal,
    this.version,
  });

  factory UserRow.fromRow(MssqlRow row) => UserRow(
    id: (row['Id']! as num).toInt(),
    name: row['Name']! as String,
    email: row['Email'] as String?,
    createdAt: row['CreatedAt'] as String?,
    netTotal: row['NetTotal'] as String?,
    version: row['Version'] as String?,
  );

  final int id;
  final String name;
  final String? email;
  final String? createdAt;
  final String? netTotal;
  final String? version;

  Map<String, Object?> toColumns() => <String, Object?>{
    'Id': id,
    'Name': name,
    'Email': email,
    'CreatedAt': createdAt,
    'NetTotal': netTotal,
    'Version': version,
  };

  UserRow copyWith({int? id, String? name, String? email}) => UserRow(
    id: id ?? this.id,
    name: name ?? this.name,
    email: email ?? this.email,
    createdAt: createdAt,
    netTotal: netTotal,
    version: version,
  );
}

MssqlTableBinding<UserRow> binding({
  MssqlInsertStrategy strategy = MssqlInsertStrategy.outputInserted,
  List<String> primaryKey = const <String>['Id'],
  bool readOnlyCreatedAt = false,
}) => MssqlTableBinding<UserRow>(
  schema: 'dbo',
  table: 'Users',
  primaryKey: primaryKey,
  identityColumn: 'Id',
  insertStrategy: strategy,
  columns: <MssqlBoundColumn>[
    MssqlBoundColumn(name: 'Id', type: MssqlType.int32, isIdentity: true),
    MssqlBoundColumn(name: 'Name', type: MssqlType.nvarchar),
    MssqlBoundColumn(name: 'Email', type: MssqlType.nvarchar, nullable: true),
    MssqlBoundColumn(
      name: 'CreatedAt',
      type: MssqlType.dateTime2,
      nullable: true,
      hasDefault: true,
      isReadOnly: readOnlyCreatedAt,
    ),
    MssqlBoundColumn(
      name: 'NetTotal',
      type: MssqlType.varchar,
      nullable: true,
      isComputed: true,
    ),
    MssqlBoundColumn(
      name: 'Version',
      type: MssqlType.binary,
      nullable: true,
      isRowVersion: true,
    ),
  ],
  fromRow: UserRow.fromRow,
  toColumns: (r) => r.toColumns(),
  readColumn: (r, name) => r.toColumns()[name],
  applyIdentity: (row, id) => row.copyWith(id: (id! as num).toInt()),
);

MssqlRepository<UserRow, int> repo(
  FakeExecutor executor, {
  MssqlInsertStrategy strategy = MssqlInsertStrategy.outputInserted,
  bool readOnlyCreatedAt = false,
}) => MssqlRepository<UserRow, int>(
  executor,
  binding: binding(strategy: strategy, readOnlyCreatedAt: readOnlyCreatedAt),
  dialect: MssqlDialect.sql2012,
);

const Map<String, Object?> aliRow = <String, Object?>{
  'Id': 5,
  'Name': 'Ali',
  'Email': null,
  'CreatedAt': null,
  'NetTotal': null,
  'Version': null,
};

void main() {
  group('multi-step transaction ownership', () {
    test(
      'graph writes inside an existing transaction use a savepoint',
      () async {
        final fake = FakeTransaction()
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{
              'Id': 1,
              'Name': 'saved',
              'Email': null,
              'CreatedAt': null,
              'NetTotal': null,
              'Version': null,
            },
          ]);
        final table = binding();
        final writer = MssqlGraphWriter<UserRow>(
          fake,
          binding: table,
          dialect: MssqlDialect.sql2012,
        );

        await writer.createGraph(
          MssqlGraphInsert<UserRow>(
            MssqlWriteAssignments(<String, MssqlWriteValue>{
              'Name': MssqlBoundValue(table.column('Name')!.bind('saved')),
            }),
          ),
        );

        expect(fake.savepointCalls, 1);
      },
    );
  });

  group('reading', () {
    test('findById selects every column and binds the key', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[aliRow]);
      final row = await repo(fake).findById(5);
      expect(row!.name, 'Ali');
      expect(
        fake.onlyCall.sql,
        'SELECT [Id], [Name], [Email], [CreatedAt], [NetTotal], [Version] '
        'FROM [dbo].[Users] WHERE [Id] = @q0',
      );
      expect(fake.onlyCall.parameters, <String, Object?>{'q0': 5});
    });

    test('findById returns null for no row; getById throws', () async {
      final fake = FakeExecutor();
      expect(await repo(fake).findById(5), isNull);

      final other = FakeExecutor();
      expect(
        () => repo(other).getById(5),
        throwsA(
          isA<MssqlRowNotFoundException>()
              .having((e) => e.table, 'table', 'dbo.Users')
              .having((e) => e.key, 'key', 5),
        ),
      );
    });

    test('findWhere applies the condition and the ordering', () async {
      final fake = FakeExecutor();
      await repo(fake).findWhere(
        Col('Name').like('ali'),
        orderBy: <MssqlOrder>[Col('Id').desc()],
      );
      expect(fake.onlyCall.sql, contains('WHERE [Name] LIKE @q0'));
      expect(fake.onlyCall.sql, endsWith('ORDER BY [Id] DESC'));
    });

    test('count builds COUNT(*) and reads the scalar', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'': 42},
        ]);
      expect(await repo(fake).count(Col('Name').eq('Ali')), 42);
      expect(
        fake.onlyCall.sql,
        'SELECT COUNT_BIG(*) FROM [dbo].[Users] WHERE [Name] = @q0',
      );
    });

    test(
      'exists asks for one row, not for the row and not for a count',
      () async {
        final fake = FakeExecutor()
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{'': 1},
          ]);
        expect(await repo(fake).exists(5), isTrue);
        expect(fake.onlyCall.sql, startsWith('SELECT TOP (@'));
        expect(fake.onlyCall.sql, isNot(contains('COUNT')));
        expect(fake.onlyCall.sql, isNot(contains('[Name]')));
      },
    );

    test('repository reads carry the read-retry policy', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[aliRow]);
      final r = repo(fake);
      await r.findById(5);
      await r.findWhere(Col('Name').eq('x'));
      await r.count();
      expect(fake.calls.map((c) => c.idempotent), everyElement(isTrue));
    });

    test('a read carrying raw SQL does not', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[aliRow]);
      await repo(fake).findWhere(raw('[Name] = SUSER_SNAME()'));
      expect(fake.onlyCall.idempotent, isFalse);
    });
  });

  group('paging', () {
    test('applies the requested filter exactly once', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake).page(
        rows: 10,
        where: Col('Name').eq('Ali'),
        orderBy: <MssqlOrder>[Col('Id').asc()],
      );
      expect(
        RegExp(r'\[Name\] = @q\d+').allMatches(fake.onlyCall.sql),
        hasLength(1),
      );
      expect(
        fake.onlyCall.parameters.values.where((value) => value == 'Ali'),
        hasLength(1),
      );
    });

    List<Map<String, Object?>> rowsNamed(int count) => <Map<String, Object?>>[
      for (var i = 0; i < count; i++) <String, Object?>{...aliRow, 'Id': i},
    ];

    test('fetches one row beyond the page and reports hasMore', () async {
      final fake = FakeExecutor()..replies.add(rowsNamed(4));
      final page = await repo(
        fake,
      ).page(rows: 3, orderBy: <MssqlOrder>[Col('Id').asc()]);
      expect(page.rows.length, 3);
      expect(page.hasMore, isTrue);
      expect(page.total, isNull);
      expect(fake.onlyCall.parameters['q1'], 4);
    });

    test('a short page reports hasMore false', () async {
      final fake = FakeExecutor()..replies.add(rowsNamed(2));
      final page = await repo(
        fake,
      ).page(rows: 3, orderBy: <MssqlOrder>[Col('Id').asc()]);
      expect(page.rows.length, 2);
      expect(page.hasMore, isFalse);
    });

    test(
      'includeTotal is what costs a second query, and it is off by default',
      () async {
        final withoutTotal = FakeExecutor()..replies.add(rowsNamed(1));
        await repo(
          withoutTotal,
        ).page(rows: 10, orderBy: <MssqlOrder>[Col('Id').asc()]);
        expect(withoutTotal.calls, hasLength(1));

        final withTotal = FakeExecutor()
          ..replies.add(rowsNamed(1))
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{'': 99},
          ]);
        final page = await repo(withTotal).page(
          rows: 10,
          orderBy: <MssqlOrder>[Col('Id').asc()],
          includeTotal: true,
        );
        expect(withTotal.calls, hasLength(2));
        expect(page.total, 99);
        expect(withTotal.calls.last.sql, startsWith('SELECT COUNT_BIG(*)'));
      },
    );

    test('the total counts the filtered set, not the table', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'': 7},
        ]);
      await repo(fake).page(
        rows: 10,
        orderBy: <MssqlOrder>[Col('Id').asc()],
        where: Col('Name').eq('Ali'),
        includeTotal: true,
      );
      expect(fake.calls.last.sql, contains('WHERE [Name] = @q0'));
    });

    test('a page without an ordering is refused', () {
      expect(
        repo(FakeExecutor()).page(rows: 10, orderBy: const <MssqlOrder>[]),
        throwsArgumentError,
      );
    });

    test('page bounds are checked', () {
      final order = <MssqlOrder>[Col('Id').asc()];
      expect(
        repo(FakeExecutor()).page(offset: -1, rows: 10, orderBy: order),
        throwsArgumentError,
      );
      expect(
        repo(FakeExecutor()).page(offset: 0, rows: 0, orderBy: order),
        throwsArgumentError,
      );
    });
  });

  group('insert', () {
    test(
      'identity, computed and rowversion columns are never written',
      () async {
        final fake = FakeExecutor()
          ..replies.add(<Map<String, Object?>>[aliRow]);
        await repo(fake).insert(const UserRow(id: 0, name: 'Ali'));
        final written = RegExp(
          r'INSERT INTO \[dbo\]\.\[Users\] \(([^)]*)\)',
        ).firstMatch(fake.onlyCall.sql)!.group(1);
        expect(written, '[Name], [Email], [CreatedAt]');
        expect(fake.onlyCall.parameters, hasLength(3));
      },
    );

    test(
      'outputInserted asks for every column back in one round trip',
      () async {
        final fake = FakeExecutor()
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{...aliRow, 'Id': 77, 'CreatedAt': '2026-09-07'},
          ]);
        final stored = await repo(
          fake,
        ).insert(const UserRow(id: 0, name: 'Ali'));
        expect(stored.id, 77);
        expect(stored.createdAt, '2026-09-07');
        expect(fake.calls, hasLength(1));
        expect(
          fake.onlyCall.sql,
          contains(
            'OUTPUT INSERTED.[Id], INSERTED.[Name], INSERTED.[Email], '
            'INSERTED.[CreatedAt], INSERTED.[NetTotal], INSERTED.[Version]',
          ),
        );
      },
    );

    test(
      'an enabled trigger captures the key and reads the row back',
      () async {
        final fake = FakeExecutor()
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{...aliRow, 'Id': 123},
          ]);
        final stored = await repo(
          fake,
          strategy: MssqlInsertStrategy.scopeIdentity,
        ).insert(const UserRow(id: 0, name: 'Ali'));
        expect(stored.id, 123);
        expect(stored.name, 'Ali');
        expect(fake.onlyCall.sql, contains('DECLARE @mssql_written TABLE'));
        expect(fake.onlyCall.sql, contains('INTO @mssql_written'));
      },
    );

    test('a keyless table captures through its identity column', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{...aliRow, 'Id': 123},
        ]);
      final stored = await MssqlRepository<UserRow, int>(
        fake,
        binding: binding(
          strategy: MssqlInsertStrategy.scopeIdentity,
          primaryKey: const <String>[],
        ),
        dialect: MssqlDialect.sql2012,
      ).insert(const UserRow(id: 0, name: 'Ali'));
      expect(stored.id, 123);
      expect(fake.onlyCall.sql, contains('DECLARE @mssql_written TABLE'));
      expect(fake.onlyCall.sql, isNot(contains('SCOPE_IDENTITY')));
    });

    test('noKeyReadback still reads the stored row back', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{...aliRow, 'Id': 0, 'CreatedAt': '2026-01-01'},
        ]);
      final stored = await repo(
        fake,
        strategy: MssqlInsertStrategy.noKeyReadback,
      ).insert(const UserRow(id: 0, name: 'Ali'));
      expect(stored.id, 0);
      expect(stored.createdAt, '2026-01-01');
      expect(fake.onlyCall.sql, startsWith('INSERT INTO [dbo].[Users]'));
      expect(fake.onlyCall.sql, contains('OUTPUT INSERTED.'));
      expect(fake.onlyCall.sql, isNot(contains('SCOPE_IDENTITY')));
    });

    test('a read-only column is left out of the insert', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[aliRow]);
      await repo(
        fake,
        readOnlyCreatedAt: true,
      ).insert(const UserRow(id: 0, name: 'Ali'));
      expect(fake.onlyCall.sql, contains('([Name], [Email])'));
    });
  });

  group('insertAll', () {
    test('writes one statement with a tuple per row', () async {
      final fake = FakeExecutor();
      await repo(fake).insertAll(const <UserRow>[
        UserRow(id: 0, name: 'A'),
        UserRow(id: 0, name: 'B'),
      ]);
      expect(fake.calls, hasLength(1));
      expect(
        fake.onlyCall.sql,
        'INSERT INTO [dbo].[Users] ([Name], [Email], [CreatedAt]) '
        'VALUES (@q0, @q1, @q2), (@q3, @q4, @q5)',
      );
      expect(fake.onlyCall.parameters['q0'], 'A');
      expect(fake.onlyCall.parameters['q3'], 'B');
    });

    test(
      'batches within the parameter ceiling rather than failing at it',
      () async {
        final fake = FakeExecutor();
        await repo(fake).insertAll(<UserRow>[
          for (var i = 0; i < 1400; i++) UserRow(id: 0, name: 'n$i'),
        ]);
        expect(fake.calls, hasLength(3));
        for (final call in fake.calls) {
          expect(call.parameters.length, lessThanOrEqualTo(2000));
        }
      },
    );

    test('an empty list sends nothing', () async {
      final fake = FakeExecutor();
      await repo(fake).insertAll(const <UserRow>[]);
      expect(fake.calls, isEmpty);
    });
  });

  group('update', () {
    test('writes every writable column and targets the key', () async {
      final fake = FakeExecutor()..affected.add(1);
      final affected = await repo(
        fake,
      ).update(const UserRow(id: 5, name: 'Veli', email: 'v@x'));
      expect(affected, 1);
      expect(
        fake.onlyCall.sql,
        'UPDATE [dbo].[Users] SET [Name] = @q0, [Email] = @q1, '
        '[CreatedAt] = @q2 WHERE [Id] = @q3; '
        'SELECT @@ROWCOUNT AS [mssql_affected];',
      );
      expect(fake.onlyCall.parameters['q3'], 5);
    });

    test(
      'a column subset narrows the SET without touching the WHERE',
      () async {
        final fake = FakeExecutor()..affected.add(1);
        await repo(fake).update(
          const UserRow(id: 5, name: 'Veli', email: 'v@x'),
          columns: <String>{'Name'},
        );
        expect(
          fake.onlyCall.sql,
          'UPDATE [dbo].[Users] SET [Name] = @q0 WHERE [Id] = @q1; '
          'SELECT @@ROWCOUNT AS [mssql_affected];',
        );
      },
    );

    test('the subset is matched without regard to case', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(
        fake,
      ).update(const UserRow(id: 5, name: 'Veli'), columns: <String>{'name'});
      expect(fake.onlyCall.sql, contains('SET [Name] = @q0'));
    });

    test('an empty subset is refused', () {
      expect(
        () => repo(
          FakeExecutor(),
        ).update(const UserRow(id: 5, name: 'x'), columns: const <String>{}),
        throwsArgumentError,
      );
    });

    test('a key column in the subset is refused', () {
      expect(
        () => repo(
          FakeExecutor(),
        ).update(const UserRow(id: 5, name: 'x'), columns: <String>{'Id'}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('primary key'),
          ),
        ),
      );
    });

    test('a server-generated column in the subset is refused', () {
      for (final name in <String>['NetTotal', 'Version']) {
        expect(
          () => repo(
            FakeExecutor(),
          ).update(const UserRow(id: 5, name: 'x'), columns: <String>{name}),
          throwsArgumentError,
          reason: name,
        );
      }
    });

    test('a read-only column in the subset is refused, and says why', () {
      expect(
        () => repo(FakeExecutor(), readOnlyCreatedAt: true).update(
          const UserRow(id: 5, name: 'x'),
          columns: <String>{'CreatedAt'},
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('read-only'),
          ),
        ),
      );
    });

    test('a read-only column is left out of a full-row update', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(
        fake,
        readOnlyCreatedAt: true,
      ).update(const UserRow(id: 5, name: 'x', createdAt: 'stale'));
      expect(fake.onlyCall.sql, isNot(contains('[CreatedAt]')));
    });

    test('the primary key is never in the SET, only in the WHERE', () async {
      final fake = FakeExecutor()..affected.add(1);
      final natural = MssqlTableBinding<UserRow>(
        schema: 'dbo',
        table: 'Natural',
        primaryKey: const <String>['Id'],
        columns: <MssqlBoundColumn>[
          MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
          MssqlBoundColumn(name: 'Name', type: MssqlType.nvarchar),
        ],
        fromRow: UserRow.fromRow,
        toColumns: (r) => <String, Object?>{'Id': r.id, 'Name': r.name},
        readColumn: (r, name) =>
            <String, Object?>{'Id': r.id, 'Name': r.name}[name],
      );
      await MssqlRepository<UserRow, int>(
        fake,
        binding: natural,
        dialect: MssqlDialect.sql2012,
      ).update(const UserRow(id: 5, name: 'x'));
      expect(
        fake.onlyCall.sql,
        'UPDATE [dbo].[Natural] SET [Name] = @q0 WHERE [Id] = @q1; '
        'SELECT @@ROWCOUNT AS [mssql_affected];',
      );
    });

    test('an insert still writes a natural, non-identity key', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{
            'Id': 5,
            'Name': 'x',
            'Email': null,
            'CreatedAt': null,
            'NetTotal': null,
            'Version': null,
          },
        ]);
      final natural = MssqlTableBinding<UserRow>(
        schema: 'dbo',
        table: 'Natural',
        primaryKey: const <String>['Id'],
        columns: <MssqlBoundColumn>[
          MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
          MssqlBoundColumn(name: 'Name', type: MssqlType.nvarchar),
        ],
        fromRow: UserRow.fromRow,
        toColumns: (r) => <String, Object?>{'Id': r.id, 'Name': r.name},
        readColumn: (r, name) =>
            <String, Object?>{'Id': r.id, 'Name': r.name}[name],
      );
      await MssqlRepository<UserRow, int>(
        fake,
        binding: natural,
        dialect: MssqlDialect.sql2012,
      ).insert(const UserRow(id: 5, name: 'x'));
      expect(fake.onlyCall.sql, contains('([Id], [Name])'));
    });

    test('writes are not marked idempotent', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake).update(const UserRow(id: 5, name: 'x'));
      expect(fake.onlyCall.idempotent, isFalse);
    });

    test('updateOne insists on exactly one row', () async {
      final none = FakeExecutor()..affected.add(0);
      expect(
        () => repo(none).updateOne(const UserRow(id: 5, name: 'x')),
        throwsA(isA<MssqlRowNotFoundException>()),
      );

      final many = FakeExecutor()..affected.add(2);
      expect(
        () => repo(many).updateOne(const UserRow(id: 5, name: 'x')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('does not identify a single row'),
          ),
        ),
      );

      final one = FakeExecutor()..affected.add(1);
      await repo(one).updateOne(const UserRow(id: 5, name: 'x'));
    });
  });

  group('delete', () {
    test('targets the key', () async {
      final fake = FakeExecutor()..affected.add(1);
      expect(await repo(fake).delete(5), 1);
      expect(
        fake.onlyCall.sql,
        'DELETE FROM [dbo].[Users] WHERE [Id] = @q0; '
        'SELECT @@ROWCOUNT AS [mssql_affected];',
      );
    });

    test('deleteWhere takes a condition', () async {
      final fake = FakeExecutor()..affected.add(3);
      expect(await repo(fake).deleteWhere(Col('Name').eq('Ali')), 3);
      expect(
        fake.onlyCall.sql,
        contains('DELETE FROM [dbo].[Users] WHERE [Name] = @q0'),
      );
    });
  });

  group('tables without a usable key', () {
    MssqlRepository<UserRow, int> keyless(FakeExecutor fake) =>
        MssqlRepository<UserRow, int>(
          fake,
          binding: binding(primaryKey: const <String>[]),
          dialect: MssqlDialect.sql2012,
        );

    test('the key-addressed methods refuse, and name the alternative', () {
      final fake = FakeExecutor();
      for (final call in <Future<Object?> Function()>[
        () => keyless(fake).findById(1),
        () => keyless(fake).delete(1),
        () => keyless(fake).exists(1),
        () => keyless(fake).update(const UserRow(id: 1, name: 'x')),
      ]) {
        expect(
          call,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('findWhere'),
            ),
          ),
        );
      }
    });

    test('findWhere and count still work', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[aliRow]);
      final rows = await keyless(fake).findWhere(Col('Name').eq('Ali'));
      expect(rows, hasLength(1));
    });

    test('a composite key needs withKeyValues, and says so', () {
      final fake = FakeExecutor();
      final composite = MssqlRepository<UserRow, int>(
        fake,
        binding: binding(primaryKey: const <String>['Id', 'Name']),
        dialect: MssqlDialect.sql2012,
      );
      expect(
        () => composite.findById(1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('withKeyValues'),
          ),
        ),
      );
    });

    test('withKeyValues takes a composite key apart', () async {
      final fake = FakeExecutor();
      final composite = MssqlRepository<UserRow, (int, String)>.withKeyValues(
        fake,
        binding: binding(primaryKey: const <String>['Id', 'Name']),
        keyValues: (key) => <String, Object?>{'Id': key.$1, 'Name': key.$2},
        dialect: MssqlDialect.sql2012,
      );
      await composite.findById((5, 'Ali'));
      expect(
        fake.onlyCall.sql,
        endsWith('WHERE ([Id] = @q0 AND [Name] = @q1)'),
      );
      expect(fake.onlyCall.parameters, <String, Object?>{'q0': 5, 'q1': 'Ali'});
    });

    test('a binding naming a key column the table lacks is refused', () {
      expect(
        () => binding(primaryKey: const <String>['NoSuchColumn']),
        throwsArgumentError,
      );
    });
  });

  group('decimal agreement', () {
    MssqlTableBinding<UserRow> priced({
      required MssqlDecimalMode decimalMode,
    }) => MssqlTableBinding<UserRow>(
      schema: 'dbo',
      table: 'Priced',
      primaryKey: const <String>['Id'],
      decimalMode: decimalMode,
      columns: <MssqlBoundColumn>[
        MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
        MssqlBoundColumn(name: 'Price', type: MssqlType.decimal),
      ],
      fromRow: UserRow.fromRow,
      toColumns: (r) => r.toColumns(),
      readColumn: (r, name) => r.toColumns()[name],
    );

    test('a mismatch is a clear configuration error, not a cast failure', () {
      final fake = FakeExecutor(decimalMode: MssqlDecimalMode.doublePrecision);
      final r = MssqlRepository<UserRow, int>(
        fake,
        binding: priced(decimalMode: MssqlDecimalMode.text),
        dialect: MssqlDialect.sql2012,
      );
      expect(
        () => r.findById(1),
        throwsA(
          isA<MssqlBindingMismatchException>().having(
            (e) => e.message,
            'message',
            allOf(contains('dbo.Priced'), contains('regenerate')),
          ),
        ),
      );
    });

    test('agreement passes', () async {
      final fake = FakeExecutor(decimalMode: MssqlDecimalMode.doublePrecision);
      final r = MssqlRepository<UserRow, int>(
        fake,
        binding: priced(decimalMode: MssqlDecimalMode.doublePrecision),
        dialect: MssqlDialect.sql2012,
      );
      expect(await r.findById(1), isNull);
    });

    test('a table with no exact numeric is not checked at all', () async {
      final fake = FakeExecutor(decimalMode: MssqlDecimalMode.text);
      final r = MssqlRepository<UserRow, int>(
        fake,
        binding: binding(),
        dialect: MssqlDialect.sql2012,
      );
      expect(await r.findById(1), isNull);
    });
  });

  group('type converters', () {
    final converted = MssqlTableBinding<UserRow>(
      schema: 'dbo',
      table: 'Users',
      primaryKey: const <String>['Id'],
      columns: <MssqlBoundColumn>[
        MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
        MssqlBoundColumn(
          name: 'Name',
          type: MssqlType.nvarchar,
          converter: const _UpperCaseConverter(),
        ),
      ],
      fromRow: UserRow.fromRow,
      toColumns: (r) => r.toColumns(),
      readColumn: (r, name) => r.toColumns()[name],
    );

    test('a converter runs on the way out', () async {
      final fake = FakeExecutor()..affected.add(1);
      await MssqlRepository<UserRow, int>(
        fake,
        binding: converted,
        dialect: MssqlDialect.sql2012,
      ).update(const UserRow(id: 5, name: 'ali'));
      expect(fake.onlyCall.parameters['q0'], 'ALI');
    });

    test(
      'null bypasses the converter rather than being handed to it',
      () async {
        final nullable = MssqlTableBinding<UserRow>(
          schema: 'dbo',
          table: 'Users',
          primaryKey: const <String>['Id'],
          columns: <MssqlBoundColumn>[
            MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
            MssqlBoundColumn(
              name: 'Email',
              type: MssqlType.nvarchar,
              nullable: true,
              converter: const _UpperCaseConverter(),
            ),
          ],
          fromRow: UserRow.fromRow,
          toColumns: (r) => r.toColumns(),
          readColumn: (r, name) => r.toColumns()[name],
        );
        final fake = FakeExecutor()..affected.add(1);
        await MssqlRepository<UserRow, int>(
          fake,
          binding: nullable,
          dialect: MssqlDialect.sql2012,
        ).update(const UserRow(id: 5, name: 'x'));
        final bound = fake.onlyCall.bound['q0']! as MssqlValue;
        expect(bound.value, isNull);
      },
    );
  });

  group('binding a null', () {
    test('a null is bound as the column\'s own type', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[aliRow]);
      await repo(fake).insert(const UserRow(id: 0, name: 'Ali'));
      final email = fake.onlyCall.bound['q1']! as MssqlValue;
      expect(email.value, isNull);
      expect(email.type, MssqlType.nvarchar);
    });

    test('every type produces a typed null rather than throwing', () {
      for (final type in MssqlType.values) {
        final column = MssqlBoundColumn(
          name: 'C',
          type: type,
          nullable: true,
          maxLength: 100,
          precision: 18,
          scale: 4,
        );
        final bound = column.bind(null);
        expect(bound, isA<MssqlValue>(), reason: '$type');
        expect((bound! as MssqlValue).value, isNull, reason: '$type');
      }
    });

    test('a max column reports -1 and still binds', () {
      final column = MssqlBoundColumn(
        name: 'C',
        type: MssqlType.nvarchar,
        nullable: true,
        maxLength: -1,
      );
      expect((column.bind(null)! as MssqlValue).value, isNull);
    });

    test('a non-null value carries its column type too', () {
      final column = MssqlBoundColumn(name: 'C', type: MssqlType.nvarchar);
      final bound = column.bind('text')! as MssqlValue;
      expect(bound.value, 'text');
      expect(bound.type, MssqlType.nvarchar);
    });
  });

  group('transactions', () {
    test('an executor reports whether it is inside one', () {
      expect(FakeExecutor().inTransaction, isFalse);
      expect(FakeExecutor(inTransaction: true).inTransaction, isTrue);
    });
  });
}

class _UpperCaseConverter extends MssqlTypeConverter<Object?, Object?> {
  const _UpperCaseConverter();

  @override
  Object? fromSql(Object? value) => (value! as String).toLowerCase();

  @override
  Object? toSql(Object? value) => (value! as String).toUpperCase();
}

