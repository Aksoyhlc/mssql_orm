import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

class CustomerRow {
  const CustomerRow({required this.id, required this.name, this.note});

  factory CustomerRow.fromRow(MssqlRow row) => CustomerRow(
    id: (row['Id']! as num).toInt(),
    name: row['Name']! as String,
    note: row['Note'] as String?,
  );

  final int id;
  final String name;
  final String? note;

  Map<String, Object?> toColumns() => <String, Object?>{
    'Id': id,
    'Name': name,
    'Note': note,
  };

  CustomerRow copyWith({int? id, String? name, String? note}) => CustomerRow(
    id: id ?? this.id,
    name: name ?? this.name,
    note: note ?? this.note,
  );
}

final customers = MssqlTableBinding<CustomerRow>(
  schema: repositorySchema,
  table: 'Customers',
  primaryKey: const <String>['Id'],
  identityColumn: 'Id',
  insertStrategy: MssqlInsertStrategy.outputInserted,
  columns: <MssqlBoundColumn>[
    MssqlBoundColumn(name: 'Id', type: MssqlType.int32, isIdentity: true),
    MssqlBoundColumn(name: 'Name', type: MssqlType.nvarchar),
    MssqlBoundColumn(name: 'Note', type: MssqlType.nvarchar, nullable: true),
  ],
  fromRow: CustomerRow.fromRow,
  toColumns: (r) => r.toColumns(),
  readColumn: (r, name) => r.toColumns()[name],
  applyIdentity: (row, id) => row.copyWith(id: (id! as num).toInt()),
);

class TriggeredRow {
  const TriggeredRow({required this.id, required this.name});

  factory TriggeredRow.fromRow(MssqlRow row) => TriggeredRow(
    id: (row['Id']! as num).toInt(),
    name: row['Name']! as String,
  );

  final int id;
  final String name;

  Map<String, Object?> toColumns() => <String, Object?>{'Id': id, 'Name': name};

  TriggeredRow copyWith({int? id}) =>
      TriggeredRow(id: id ?? this.id, name: name);
}

MssqlTableBinding<TriggeredRow> triggeredBinding(
  MssqlInsertStrategy strategy,
) => MssqlTableBinding<TriggeredRow>(
  schema: repositorySchema,
  table: 'Triggered',
  primaryKey: const <String>['Id'],
  identityColumn: 'Id',
  insertStrategy: strategy,
  columns: <MssqlBoundColumn>[
    MssqlBoundColumn(name: 'Id', type: MssqlType.int32, isIdentity: true),
    MssqlBoundColumn(name: 'Name', type: MssqlType.nvarchar),
  ],
  fromRow: TriggeredRow.fromRow,
  toColumns: (r) => r.toColumns(),
  readColumn: (r, name) => r.toColumns()[name],
  applyIdentity: (row, id) => row.copyWith(id: (id! as num).toInt()),
);

void main() {
  group('the repository, against a server', () {
    late MssqlConnection connection;
    late MssqlConnectionPool pool;
    late MssqlRepository<CustomerRow, int> repo;

    setUpAll(() async {
      if (!liveEnabled) return;
      await initializeLive();
      connection = await MssqlConnection.open(liveConfig());
      await createFixtureSchema(connection, repositorySchema);
      pool = MssqlConnectionPool(liveConfig());
      repo = MssqlRepository<CustomerRow, int>(connection, binding: customers);
    });

    tearDownAll(() async {
      if (!liveEnabled) return;
      await pool.close();
      await dropFixtureSchema(connection, repositorySchema);
      await connection.close();
    });

    setUp(() async {
      if (!liveEnabled) return;
      await connection.execute('DELETE FROM [$repositorySchema].[Customers];');
      await connection.execute('DELETE FROM [$repositorySchema].[Triggered];');
    });

    test('insert returns the row the server stored', () async {
      final stored = await repo.insert(const CustomerRow(id: 0, name: 'Ali'));
      expect(stored.id, greaterThan(0));
      expect(stored.name, 'Ali');
      expect(await repo.getById(stored.id), isA<CustomerRow>());
    }, skip: liveSkip);

    test('the dialect is discovered from the server when not given', () async {
      final page = await repo.page(
        offset: 0,
        rows: 5,
        orderBy: <MssqlOrder>[Col('Id').asc()],
      );
      expect(page.rows, isEmpty);
    }, skip: liveSkip);

    test('findById round-trips, and a missing row is null', () async {
      final stored = await repo.insert(
        const CustomerRow(id: 0, name: 'Veli', note: 'n'),
      );
      final read = await repo.findById(stored.id);
      expect(read!.name, 'Veli');
      expect(read.note, 'n');
      expect(await repo.findById(stored.id + 10000), isNull);
    }, skip: liveSkip);

    test('update writes and reports one affected row', () async {
      final stored = await repo.insert(const CustomerRow(id: 0, name: 'A'));
      final affected = await repo.update(stored.copyWith(name: 'B'));
      expect(affected, 1);
      expect((await repo.getById(stored.id)).name, 'B');
    }, skip: liveSkip);

    test('a column subset leaves the other columns alone', () async {
      final stored = await repo.insert(
        const CustomerRow(id: 0, name: 'A', note: 'keep'),
      );
      await repo.update(
        stored.copyWith(name: 'B', note: 'discarded'),
        columns: <String>{'Name'},
      );
      final read = await repo.getById(stored.id);
      expect(read.name, 'B');
      expect(read.note, 'keep');
    }, skip: liveSkip);

    test('delete removes the row', () async {
      final stored = await repo.insert(const CustomerRow(id: 0, name: 'A'));
      expect(await repo.delete(stored.id), 1);
      expect(await repo.findById(stored.id), isNull);
    }, skip: liveSkip);

    test('insertAll writes every row in one statement', () async {
      await repo.insertAll(<CustomerRow>[
        for (var i = 0; i < 25; i++) CustomerRow(id: 0, name: 'n$i'),
      ]);
      expect(await repo.count(), 25);
    }, skip: liveSkip);

    test('paging walks the table and hasMore is right at the end', () async {
      await repo.insertAll(<CustomerRow>[
        for (var i = 0; i < 7; i++) CustomerRow(id: 0, name: 'n$i'),
      ]);
      final order = <MssqlOrder>[Col('Id').asc()];

      final first = await repo.page(offset: 0, rows: 5, orderBy: order);
      expect(first.rows, hasLength(5));
      expect(first.hasMore, isTrue);

      final second = await repo.page(
        offset: 5,
        rows: 5,
        orderBy: order,
        includeTotal: true,
      );
      expect(second.rows, hasLength(2));
      expect(second.hasMore, isFalse);
      expect(second.total, 7);
    }, skip: liveSkip);

    test('the sql2008 paging path returns the same rows as sql2012', () async {
      await repo.insertAll(<CustomerRow>[
        for (var i = 0; i < 6; i++) CustomerRow(id: 0, name: 'n$i'),
      ]);
      final order = <MssqlOrder>[Col('Id').asc()];
      Future<MssqlPage<CustomerRow>> pageOf(
        MssqlRepository<CustomerRow, int> repository,
      ) => repository.page(offset: 2, rows: 3, orderBy: order);

      final modern = MssqlRepository<CustomerRow, int>(
        connection,
        binding: customers,
        dialect: MssqlDialect.sql2012,
      );
      final legacy = MssqlRepository<CustomerRow, int>(
        connection,
        binding: customers,
        dialect: MssqlDialect.sql2008,
      );

      final a = await pageOf(modern);
      final b = await pageOf(legacy);
      expect(a.rows.map((r) => r.name), b.rows.map((r) => r.name));
      expect(a.rows, hasLength(3));
      expect(a.hasMore, b.hasMore);
    }, skip: liveSkip);

    test('the two dialects agree on every page of a walk', () async {
      await repo.insertAll(<CustomerRow>[
        for (var i = 0; i < 23; i++) CustomerRow(id: 0, name: 'n$i'),
      ]);
      final order = <MssqlOrder>[Col('Id').asc()];
      final modern = MssqlRepository<CustomerRow, int>(
        connection,
        binding: customers,
        dialect: MssqlDialect.sql2012,
      );
      final legacy = MssqlRepository<CustomerRow, int>(
        connection,
        binding: customers,
        dialect: MssqlDialect.sql2008,
      );

      for (final rows in <int>[1, 3, 7, 23, 40]) {
        for (var offset = 0; offset <= 24; offset += 5) {
          final a = await modern.page(
            offset: offset,
            rows: rows,
            orderBy: order,
          );
          final b = await legacy.page(
            offset: offset,
            rows: rows,
            orderBy: order,
          );
          expect(
            b.rows.map((r) => r.name),
            a.rows.map((r) => r.name),
            reason: 'offset $offset, rows $rows',
          );
          expect(b.hasMore, a.hasMore, reason: 'offset $offset, rows $rows');
        }
      }
    }, skip: liveSkip);

    test(
      'the two dialects agree with a filter and a descending order',
      () async {
        await repo.insertAll(<CustomerRow>[
          for (var i = 0; i < 12; i++)
            CustomerRow(id: 0, name: 'n$i', note: i.isEven ? 'even' : 'odd'),
        ]);
        Future<MssqlPage<CustomerRow>> pageOf(MssqlDialect dialect) =>
            MssqlRepository<CustomerRow, int>(
              connection,
              binding: customers,
              dialect: dialect,
            ).page(
              offset: 2,
              rows: 3,
              orderBy: <MssqlOrder>[Col('Id').desc()],
              where: Col('Note').eq('even'),
              includeTotal: true,
            );
        final a = await pageOf(MssqlDialect.sql2012);
        final b = await pageOf(MssqlDialect.sql2008);
        expect(b.rows.map((r) => r.name), a.rows.map((r) => r.name));
        expect(b.total, a.total);
        expect(b.hasMore, a.hasMore);
      },
      skip: liveSkip,
    );

    test(
      'OUTPUT INSERTED is rejected on a table with an enabled trigger',
      () async {
        final wrong = MssqlRepository<TriggeredRow, int>(
          connection,
          binding: triggeredBinding(MssqlInsertStrategy.outputInserted),
        );
        await expectLater(
          wrong.insert(const TriggeredRow(id: 0, name: 'x')),
          throwsA(isA<MssqlException>()),
        );
      },
      skip: liveSkip,
    );

    test('SCOPE_IDENTITY() works where OUTPUT does not', () async {
      final right = MssqlRepository<TriggeredRow, int>(
        connection,
        binding: triggeredBinding(MssqlInsertStrategy.scopeIdentity),
      );
      final stored = await right.insert(const TriggeredRow(id: 0, name: 'x'));
      expect(stored.id, greaterThan(0));
      expect(stored.name, 'x');
    }, skip: liveSkip);

    test('a repository inside a transaction is rolled back with it', () async {
      await expectLater(
        pool.transaction((tx) async {
          final inTx = MssqlRepository<CustomerRow, int>(
            tx,
            binding: customers,
          );
          expect(inTx.session.inTransaction, isTrue);
          await inTx.insert(const CustomerRow(id: 0, name: 'rolled back'));
          expect(await inTx.count(), 1);
          throw StateError('roll this back');
        }),
        throwsStateError,
      );
      expect(await repo.count(), 0);
    }, skip: liveSkip);

    test('a committed transaction keeps its writes', () async {
      await pool.transaction((tx) async {
        final inTx = MssqlRepository<CustomerRow, int>(tx, binding: customers);
        await inTx.insert(const CustomerRow(id: 0, name: 'kept'));
      });
      expect(await repo.count(), 1);
    }, skip: liveSkip);

    test('a decimal mismatch is caught before any row is read', () async {
      final mismatched = MssqlTableBinding<CustomerRow>(
        schema: repositorySchema,
        table: 'Customers',
        primaryKey: const <String>['Id'],
        decimalMode: MssqlDecimalMode.doublePrecision,
        columns: <MssqlBoundColumn>[
          MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
          MssqlBoundColumn(name: 'Price', type: MssqlType.decimal),
        ],
        fromRow: CustomerRow.fromRow,
        toColumns: (r) => r.toColumns(),
        readColumn: (r, name) => r.toColumns()[name],
      );
      await expectLater(
        MssqlRepository<CustomerRow, int>(
          connection,
          binding: mismatched,
        ).findById(1),
        throwsA(isA<MssqlBindingMismatchException>()),
      );
    }, skip: liveSkip);
  });
}

