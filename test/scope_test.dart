import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_executor.dart';

class R {
  const R(this.values, [this.relations = const <String, Object?>{}]);
  final Map<String, Object?> values;
  final Map<String, Object?> relations;

  R withRelations(Map<String, Object?> more) =>
      R(values, <String, Object?>{...relations, ...more});
}

class RFields {}

class RQuery extends MssqlEntityQuery<R, RFields, RQuery> {
  RQuery(
    super.context, [
    super.state = const MssqlQueryState.empty(),
    super.included = const <MssqlRelation<R, Object?>>[],
  ]);

  @override
  RFields get fields => RFields();

  @override
  RQuery recreate(
    MssqlQueryState state,
    List<MssqlRelation<R, Object?>> included,
  ) => RQuery(context, state, included);

  @override
  RQuery recreateAt(
    MssqlQueryContext<R> context,
    MssqlQueryState state,
    List<MssqlRelation<R, Object?>> included,
  ) => RQuery(context, state, included);
}

MssqlTableBinding<R> bindingWith({
  MssqlSoftDelete? softDelete,
  MssqlTimestamps timestamps = const MssqlTimestamps(),
  List<MssqlScope> scopes = const <MssqlScope>[],
}) => MssqlTableBinding<R>(
  schema: 'dbo',
  table: 'Users',
  primaryKey: const <String>['Id'],
  softDelete: softDelete,
  timestamps: timestamps,
  scopes: scopes,
  columns: <MssqlBoundColumn>[
    MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
    MssqlBoundColumn(name: 'Name', type: MssqlType.nvarchar, nullable: true),
    MssqlBoundColumn(name: 'TenantId', type: MssqlType.int32, nullable: true),
    MssqlBoundColumn(
      name: 'DeletedAt',
      type: MssqlType.dateTime2,
      nullable: true,
    ),
    MssqlBoundColumn(
      name: 'CreatedAt',
      type: MssqlType.dateTime2,
      nullable: true,
    ),
    MssqlBoundColumn(
      name: 'UpdatedAt',
      type: MssqlType.dateTime2,
      nullable: true,
    ),
    MssqlBoundColumn(name: 'Hits', type: MssqlType.int32, nullable: true),
    MssqlBoundColumn(name: 'IsDeleted', type: MssqlType.bit),
  ],
  fromRow: (row) => R(row.toMap()),
  toColumns: (row) => row.values,
  readColumn: (row, name) => row.values[name],
  applyRelations: (row, relations) => row.withRelations(relations),
);

MssqlRepository<R, int> repo(
  FakeExecutor fake, {
  MssqlSoftDelete? softDelete,
  MssqlTimestamps timestamps = const MssqlTimestamps(),
  List<MssqlScope> scopes = const <MssqlScope>[],
}) => MssqlRepository<R, int>(
  fake,
  binding: bindingWith(
    softDelete: softDelete,
    timestamps: timestamps,
    scopes: scopes,
  ),
  dialect: MssqlDialect.sql2012,
);

const softDelete = MssqlSoftDelete(column: 'DeletedAt');

R row(int id) => R(<String, Object?>{'Id': id, 'Name': 'n$id'});

void main() {
  group('immutable query state', () {
    test('scope selection owns an unmodifiable copy of caller sets', () {
      final source = <String>{'tenant'};
      final selection = MssqlScopeSelection(withoutScopes: source);
      final originalHash = selection.hashCode;

      source.add('region');

      expect(selection.withoutScopes, <String>{'tenant'});
      expect(selection.hashCode, originalHash);
      expect(
        () => selection.withoutScopes.add('other'),
        throwsUnsupportedError,
      );
    });

    test('query state owns unmodifiable copies of caller lists', () {
      final conditions = <MssqlCondition>[Col('TenantId').eq(1)];
      final ordering = <MssqlOrder>[Col('Id').asc()];
      final state = MssqlQueryState(where: conditions, orderBy: ordering);
      final originalHash = state.hashCode;

      conditions.add(Col('TenantId').eq(2));
      ordering.add(Col('Name').asc());

      expect(state.where, hasLength(1));
      expect(state.orderBy, hasLength(1));
      expect(state.hashCode, originalHash);
      expect(() => state.where.clear(), throwsUnsupportedError);
      expect(() => state.orderBy.clear(), throwsUnsupportedError);
    });
  });

  group('soft deletes', () {
    test('supports an explicit live/deleted flag convention', () async {
      const flag = MssqlSoftDelete(
        column: 'IsDeleted',
        aliveValue: false,
        deletedValue: true,
      );
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[])
        ..affected.addAll(<int>[1, 1]);
      final repository = repo(fake, softDelete: flag);

      await repository.findAll();
      await repository.delete(3);
      await repository.restore(3);

      expect(fake.calls[0].sql, contains('WHERE [IsDeleted] = @q0'));
      expect(fake.calls[0].parameters['q0'], false);
      expect(fake.calls[1].sql, contains('SET [IsDeleted] = @q0'));
      expect(fake.calls[1].parameters['q0'], true);
      expect(fake.calls[2].sql, contains('SET [IsDeleted] = @q0'));
      expect(fake.calls[2].parameters['q0'], false);
    });

    test('soft-delete convention names are canonicalized for SQL', () async {
      final fake = FakeExecutor()..affected.add(1);
      final repository = repo(
        fake,
        softDelete: const MssqlSoftDelete(column: 'deletedat'),
      );

      await repository.findAll();
      await repository.delete(1);

      for (final call in fake.calls) {
        expect(call.sql, contains('[DeletedAt]'));
        expect(call.sql, isNot(contains('[deletedat]')));
      }
    });

    test('canonicalization reaches every soft-delete path', () async {
      final fake = FakeExecutor()..affected.addAll(<int>[1, 1]);
      final repository = repo(
        fake,
        softDelete: const MssqlSoftDelete(column: 'DELETEDAT'),
      );

      await repository.delete(1);
      await repository.restore(1);
      await repository.onlyTrashed().findAll();

      for (final call in fake.calls) {
        expect(call.sql, isNot(contains('[DELETEDAT]')), reason: call.sql);
        expect(call.sql, contains('[DeletedAt]'), reason: call.sql);
      }
    });

    test('the binding reports the canonical name, not the configured one', () {
      final binding = bindingWith(
        softDelete: const MssqlSoftDelete(column: 'deletedAT'),
      );
      expect(binding.softDelete!.column, 'DeletedAt');
    });

    test('timestamp columns are canonicalized on the binding too', () {
      final binding = bindingWith(
        timestamps: const MssqlTimestamps(
          createdColumn: 'createdat',
          updatedColumn: 'UPDATEDAT',
        ),
      );
      expect(binding.timestamps.createdColumn, 'CreatedAt');
      expect(binding.timestamps.updatedColumn, 'UpdatedAt');
    });

    test('a convention column the table lacks is still refused', () {
      expect(
        () => bindingWith(
          softDelete: const MssqlSoftDelete(column: 'NoSuchColumn'),
        ),
        throwsArgumentError,
      );
    });

    test('every read hides deleted rows', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake, softDelete: softDelete).findAll();
      expect(fake.onlyCall.sql, contains('WHERE [DeletedAt] IS NULL'));
    });

    test('findById is filtered too', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake, softDelete: softDelete).findById(1);
      expect(
        fake.onlyCall.sql,
        contains('WHERE ([DeletedAt] IS NULL AND [Id] = @q0)'),
      );
    });

    test('withTrashed drops the filter', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake, softDelete: softDelete).withTrashed().findAll();
      expect(fake.onlyCall.sql, isNot(contains('WHERE [DeletedAt]')));
    });

    test('onlyTrashed inverts it', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake, softDelete: softDelete).onlyTrashed().findAll();
      expect(fake.onlyCall.sql, contains('WHERE [DeletedAt] IS NOT NULL'));
    });

    test('withoutTrashed puts it back', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      final r = repo(fake, softDelete: softDelete);
      await r.withTrashed().withoutTrashed().findAll();
      expect(fake.onlyCall.sql, contains('IS NULL'));
    });

    test('the count is filtered too, or a page total lies', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'': 0},
        ]);
      await repo(fake, softDelete: softDelete).count();
      expect(fake.onlyCall.sql, contains('WHERE [DeletedAt] IS NULL'));
    });

    test('delete writes the column instead of removing the row', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake, softDelete: softDelete).delete(5);
      expect(fake.onlyCall.sql, startsWith('UPDATE [dbo].[Users] SET'));
      expect(fake.onlyCall.sql, contains('[DeletedAt] = SYSUTCDATETIME()'));
    });

    test('the stamp is the server clock, not a bound value', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake, softDelete: softDelete).delete(5);
      expect(fake.onlyCall.sql, contains('SYSUTCDATETIME()'));
      expect(fake.onlyCall.parameters.values, isNot(contains(isA<DateTime>())));
    });

    test('deleting an already-deleted row reports zero', () async {
      final fake = FakeExecutor()..affected.add(0);
      await repo(fake, softDelete: softDelete).delete(5);
      expect(fake.onlyCall.sql, contains('[DeletedAt] IS NULL'));
    });

    test('a custom deleted value is written instead of a timestamp', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(
        fake,
        softDelete: const MssqlSoftDelete(
          column: 'IsDeleted',
          aliveValue: false,
          deletedValue: true,
        ),
      ).delete(5);
      expect(fake.onlyCall.parameters.values, contains(true));
    });

    test('forceDelete removes the row for real', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake, softDelete: softDelete).forceDelete(5);
      expect(fake.onlyCall.sql, startsWith('DELETE FROM [dbo].[Users]'));
      expect(fake.onlyCall.sql, isNot(contains('[DeletedAt] IS NULL')));
    });

    test('restore clears the column', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake, softDelete: softDelete).restore(5);
      expect(fake.onlyCall.sql, contains('SET [DeletedAt] = @q0'));
      expect((fake.onlyCall.bound['q0']! as MssqlValue).value, isNull);
    });

    test('restore on a table that does not soft-delete is refused', () async {
      await expectLater(
        repo(FakeExecutor()).restore(5),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('does not soft-delete'),
          ),
        ),
      );
    });

    test('without soft deletes, delete is a real DELETE', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake).delete(5);
      expect(fake.onlyCall.sql, startsWith('DELETE FROM'));
    });
  });

  group('the table override', () {
    test('points every read and write at the named table', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[])
        ..affected.add(1);
      final archive = MssqlRepository<R, int>(
        fake,
        binding: bindingWith(),
        table: 'Users_2024',
        dialect: MssqlDialect.sql2012,
      );
      await archive.findAll();
      await archive.delete(1);
      for (final call in fake.calls) {
        expect(call.sql, contains('[dbo].[Users_2024]'), reason: call.sql);
        expect(call.sql, isNot(contains('[dbo].[Users]')), reason: call.sql);
      }
    });

    test('the schema can be overridden on its own', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await MssqlRepository<R, int>(
        fake,
        binding: bindingWith(),
        schema: 'archive',
        dialect: MssqlDialect.sql2012,
      ).findAll();
      expect(fake.onlyCall.sql, contains('[archive].[Users]'));
    });

    test('the columns, key and conventions come along unchanged', () async {
      final fake = FakeExecutor()..affected.add(1);
      await MssqlRepository<R, int>(
        fake,
        binding: bindingWith(softDelete: softDelete),
        table: 'Users_2024',
        dialect: MssqlDialect.sql2012,
      ).delete(1);
      expect(fake.onlyCall.sql, contains('[dbo].[Users_2024]'));
      expect(fake.onlyCall.sql, contains('[DeletedAt]'));
      expect(fake.onlyCall.sql, contains('[Id] = @'));
    });

    test(
      'a name that needs quoting works, rather than being refused',
      () async {
        final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
        await MssqlRepository<R, int>(
          fake,
          binding: bindingWith(),
          table: 'Order Lines',
          dialect: MssqlDialect.sql2012,
        ).findAll();
        expect(fake.onlyCall.sql, contains('[dbo].[Order Lines]'));
      },
    );

    test('a hostile name is quoted inert, not spliced into the SQL', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await MssqlRepository<R, int>(
        fake,
        binding: bindingWith(),
        table: 'Users]; DROP TABLE Users; --',
        dialect: MssqlDialect.sql2012,
      ).findAll();
      final bare = fake.onlyCall.sql.replaceAll(
        RegExp(r'\[(?:[^\]]|\]\])*\]'),
        '',
      );
      expect(bare, isNot(contains('DROP')));
      expect(bare, isNot(contains('--')));
    });

    test('an empty name is still refused, where it is written', () {
      expect(() => bindingWith().forTable(table: ''), throwsArgumentError);
    });

    test('no override leaves the binding alone', () {
      final binding = bindingWith();
      expect(identical(binding.forTable(), binding), isTrue);
    });

    test('the fingerprint is dropped, not carried onto another table', () {
      final binding = MssqlTableBinding<R>(
        schema: 'dbo',
        table: 'Users',
        primaryKey: const <String>['Id'],
        schemaFingerprint: 'abc123',
        columns: <MssqlBoundColumn>[
          MssqlBoundColumn(name: 'Id', type: MssqlType.int32),
        ],
        fromRow: (row) => R(row.toMap()),
        toColumns: (row) => row.values,
        readColumn: (row, name) => row.values[name],
      );
      expect(binding.schemaFingerprint, 'abc123');
      expect(binding.forTable(table: 'Other').schemaFingerprint, isEmpty);
    });
  });

  group('timestamps', () {
    test(
      'insertAll stamps every tuple without binding the server clock',
      () async {
        final fake = FakeExecutor();
        await repo(
          fake,
          timestamps: const MssqlTimestamps(
            createdColumn: 'createdat',
            updatedColumn: 'updatedat',
          ),
        ).insertAll(<R>[row(1), row(2)]);

        expect(
          RegExp(r'SYSUTCDATETIME\(\)').allMatches(fake.onlyCall.sql),
          hasLength(4),
        );
        expect(
          fake.onlyCall.parameters.values,
          isNot(contains(isA<DateTime>())),
        );
      },
    );

    const stamps = MssqlTimestamps(
      createdColumn: 'CreatedAt',
      updatedColumn: 'UpdatedAt',
    );

    test('explicit nullable row fields are stamped when null', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1},
        ]);
      await repo(fake, timestamps: stamps).insert(
        R(<String, Object?>{
          'Id': 1,
          'Name': 'A',
          'CreatedAt': null,
          'UpdatedAt': null,
        }),
      );

      expect(
        RegExp(r'SYSUTCDATETIME\(\)').allMatches(fake.onlyCall.sql),
        hasLength(2),
      );
    });

    test(
      'timestamp convention names are case-insensitive when writing',
      () async {
        final fake = FakeExecutor()
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{'Id': 1},
          ]);
        await repo(
          fake,
          timestamps: const MssqlTimestamps(
            createdColumn: 'createdat',
            updatedColumn: 'updatedat',
          ),
        ).insert(
          R(<String, Object?>{
            'Id': 1,
            'Name': 'A',
            'CreatedAt': null,
            'UpdatedAt': null,
          }),
        );

        expect(
          RegExp(r'\[CreatedAt\]').allMatches(fake.onlyCall.sql),
          hasLength(2),
        );
        expect(
          RegExp(r'\[UpdatedAt\]').allMatches(fake.onlyCall.sql),
          hasLength(2),
        );
        expect(fake.onlyCall.sql, isNot(contains('[createdat]')));
        expect(fake.onlyCall.sql, isNot(contains('[updatedat]')));
        expect(
          RegExp(r'SYSUTCDATETIME\(\)').allMatches(fake.onlyCall.sql),
          hasLength(2),
        );
      },
    );

    test('an insert stamps both columns from the server clock', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1},
        ]);
      await repo(fake, timestamps: stamps).insert(row(0));
      expect(fake.onlyCall.sql, contains('SYSUTCDATETIME()'));
      expect(RegExp('SYSUTCDATETIME').allMatches(fake.onlyCall.sql).length, 2);
    });

    test('an update stamps only the updated column', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake, timestamps: stamps).update(row(5));
      expect(fake.onlyCall.sql, contains('[UpdatedAt] = SYSUTCDATETIME()'));
      expect(
        fake.onlyCall.sql,
        isNot(contains('[CreatedAt] = SYSUTCDATETIME()')),
      );
    });

    test('a stamp the caller already set is left alone', () async {
      final imported = DateTime.utc(2020, 1, 2, 3, 4, 5);
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 1},
        ]);
      await repo(
        fake,
        timestamps: stamps,
      ).insert(R(<String, Object?>{'Id': 0, 'CreatedAt': imported}));
      expect(
        fake.onlyCall.parameters.values
            .whereType<MssqlDateTimeValue>()
            .single
            .toDateTime()
            .toIso8601String(),
        imported.toIso8601String().replaceAll('Z', ''),
      );
      expect(RegExp('SYSUTCDATETIME').allMatches(fake.onlyCall.sql).length, 1);
    });

    test('no timestamps configured means none written', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake).update(row(5));
      expect(fake.onlyCall.sql, isNot(contains('DATETIME')));
    });

    test('soft delete and restore both maintain updated-at', () async {
      final fake = FakeExecutor()..affected.addAll(<int>[1, 1]);
      final repository = repo(
        fake,
        softDelete: softDelete,
        timestamps: const MssqlTimestamps(updatedColumn: 'UpdatedAt'),
      );

      await repository.delete(5);
      await repository.restore(5);

      for (final call in fake.calls) {
        expect(call.sql, contains('[UpdatedAt] = SYSUTCDATETIME()'));
      }
    });
  });

  group('global scopes', () {
    MssqlScope tenant(int? id) =>
        MssqlScope('tenant', () => id == null ? null : Col('TenantId').eq(id));

    test('a scope is applied to every read', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake, scopes: <MssqlScope>[tenant(7)]).findAll();
      expect(fake.onlyCall.sql, contains('WHERE [TenantId] = @q0'));
    });

    test(
      'parent and include resolve ambient scopes before the first await',
      () async {
        var tenantId = 7;
        final parentBinding = bindingWith(
          scopes: <MssqlScope>[
            MssqlScope('tenant', () => Col('TenantId').eq(tenantId)),
          ],
        );
        final childBinding = bindingWith(
          scopes: <MssqlScope>[
            MssqlScope('tenant', () => Col('TenantId').eq(tenantId)),
          ],
        ).forTable(table: 'Children');
        final relation = MssqlRelation<R, R>(
          name: 'children',
          kind: MssqlRelationKind.hasMany,
          targetBinding: childBinding,
          localColumns: const <String>['Id'],
          foreignColumns: const <String>['Id'],
        );
        final fake = FakeExecutor()
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{
              'Id': 1,
              'Name': 'parent',
              'TenantId': 7,
              'DeletedAt': null,
              'CreatedAt': null,
              'UpdatedAt': null,
              'Hits': null,
              'IsDeleted': false,
            },
          ])
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{
              'Id': 1,
              'Name': 'child',
              'TenantId': 7,
              'DeletedAt': null,
              'CreatedAt': null,
              'UpdatedAt': null,
              'Hits': null,
              'IsDeleted': false,
            },
          ]);
        fake.afterCall = (_) {
          if (fake.calls.length == 1) tenantId = 9;
        };
        final query = RQuery(
          MssqlQueryContext<R>(
            session: fake,
            binding: parentBinding,
            dialect: MssqlDialect.sql2012,
          ),
        ).include((_) => <MssqlRelation<R, Object?>>[relation]);

        await query.get();

        expect(fake.calls, hasLength(2));
        expect(fake.calls[0].parameters.values, contains(7));
        expect(fake.calls[1].parameters.values, contains(7));
        expect(fake.calls[1].parameters.values, isNot(contains(9)));
      },
    );

    test('repository includes share the parent scope snapshot', () async {
      var tenantId = 7;
      final parentBinding = bindingWith(
        scopes: <MssqlScope>[
          MssqlScope('tenant', () => Col('TenantId').eq(tenantId)),
        ],
      );
      final childBinding = bindingWith(
        scopes: <MssqlScope>[
          MssqlScope('tenant', () => Col('TenantId').eq(tenantId)),
        ],
      ).forTable(table: 'Children');
      final relation = MssqlRelation<R, R>(
        name: 'children',
        kind: MssqlRelationKind.hasMany,
        targetBinding: childBinding,
        localColumns: const <String>['Id'],
        foreignColumns: const <String>['Id'],
      );
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{
            'Id': 1,
            'Name': 'parent',
            'TenantId': 7,
            'DeletedAt': null,
            'CreatedAt': null,
            'UpdatedAt': null,
            'Hits': null,
            'IsDeleted': false,
          },
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{
            'Id': 1,
            'Name': 'child',
            'TenantId': 7,
            'DeletedAt': null,
            'CreatedAt': null,
            'UpdatedAt': null,
            'Hits': null,
            'IsDeleted': false,
          },
        ]);
      fake.afterCall = (_) {
        if (fake.calls.length == 1) tenantId = 9;
      };
      final repository = MssqlRepository<R, int>(
        fake,
        binding: parentBinding,
        dialect: MssqlDialect.sql2012,
      );

      await repository.findAll(include: <MssqlRelation<R, Object?>>[relation]);

      expect(fake.calls, hasLength(2));
      expect(fake.calls[0].parameters.values, contains(7));
      expect(fake.calls[1].parameters.values, contains(7));
      expect(fake.calls[1].parameters.values, isNot(contains(9)));
    });

    test('a scope returning null adds nothing', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake, scopes: <MssqlScope>[tenant(null)]).findAll();
      expect(fake.onlyCall.sql, isNot(contains('WHERE')));
    });

    test('withoutScope switches one off by name', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(
        fake,
        scopes: <MssqlScope>[tenant(7)],
      ).withoutScope('tenant').findAll();
      expect(fake.onlyCall.sql, isNot(contains('WHERE [TenantId]')));
    });

    test('withoutGlobalScopes switches all of them off', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(
        fake,
        scopes: <MssqlScope>[
          tenant(7),
          MssqlScope('live', () => Col('Name').isNotNull()),
        ],
      ).withoutGlobalScopes().findAll();
      expect(fake.onlyCall.sql, isNot(contains('WHERE')));
    });

    test('it does not switch off the soft-delete filter', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(
        fake,
        softDelete: softDelete,
        scopes: <MssqlScope>[tenant(7)],
      ).withoutGlobalScopes().findAll();
      expect(fake.onlyCall.sql, contains('[DeletedAt] IS NULL'));
      expect(fake.onlyCall.sql, isNot(contains('WHERE [TenantId]')));
    });

    test('scopes and the caller\'s own condition are ANDed', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(
        fake,
        scopes: <MssqlScope>[tenant(7)],
      ).findWhere(Col('Name').eq('ali'));
      expect(
        fake.onlyCall.sql,
        contains('WHERE ([TenantId] = @q0 AND [Name] = @q1)'),
      );
    });

    test('scopes constrain update, delete and increment writes', () async {
      final fake = FakeExecutor()..affected.addAll(<int>[1, 1, 1]);
      final repository = repo(fake, scopes: <MssqlScope>[tenant(7)]);

      await repository.update(row(1), columns: <String>{'Name'});
      await repository.delete(1);
      await repository.increment(1, 'Hits');

      for (final call in fake.calls) {
        expect(call.sql, contains('[TenantId] ='));
        expect(call.parameters.values, contains(7));
      }
    });
  });

  group('binding convention validation', () {
    test('rejects missing, read-only and invalid soft-delete columns', () {
      expect(
        () => bindingWith(softDelete: const MssqlSoftDelete(column: 'Missing')),
        throwsArgumentError,
      );
      expect(
        () => MssqlTableBinding<R>(
          schema: 'dbo',
          table: 'T',
          columns: <MssqlBoundColumn>[
            MssqlBoundColumn(
              name: 'DeletedAt',
              type: MssqlType.dateTime2,
              isReadOnly: true,
              nullable: true,
            ),
          ],
          fromRow: (row) => R(row.toMap()),
          toColumns: (row) => row.values,
          readColumn: (row, name) => row.values[name],
          softDelete: const MssqlSoftDelete(column: 'DeletedAt'),
        ),
        throwsArgumentError,
      );
      expect(
        () => MssqlTableBinding<R>(
          schema: 'dbo',
          table: 'T',
          columns: <MssqlBoundColumn>[
            MssqlBoundColumn(name: 'DeletedAt', type: MssqlType.dateTime2),
          ],
          fromRow: (row) => R(row.toMap()),
          toColumns: (row) => row.values,
          readColumn: (row, name) => row.values[name],
          softDelete: const MssqlSoftDelete(column: 'DeletedAt'),
        ),
        throwsArgumentError,
      );
      expect(
        () => bindingWith(
          softDelete: const MssqlSoftDelete(
            column: 'IsDeleted',
            aliveValue: false,
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => bindingWith(softDelete: const MssqlSoftDelete(column: 'Hits')),
        throwsArgumentError,
      );
    });

    test(
      'rejects duplicate scope names and one column used for two stamps',
      () {
        expect(
          () => bindingWith(
            scopes: <MssqlScope>[
              MssqlScope('tenant', () => null),
              MssqlScope('tenant', () => null),
            ],
          ),
          throwsArgumentError,
        );
        expect(
          () => bindingWith(
            timestamps: const MssqlTimestamps(
              createdColumn: 'CreatedAt',
              updatedColumn: 'createdat',
            ),
          ),
          throwsArgumentError,
        );
        expect(
          () => bindingWith(
            softDelete: softDelete,
            timestamps: const MssqlTimestamps(updatedColumn: 'deletedat'),
          ),
          throwsArgumentError,
        );
      },
    );

    test('rejects non-temporal timestamp columns', () {
      expect(
        () => bindingWith(
          timestamps: const MssqlTimestamps(updatedColumn: 'Hits'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('increment and decrement', () {
    test('add in place rather than read-modify-write', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake).increment(5, 'Hits');
      expect(
        fake.onlyCall.sql,
        'UPDATE [dbo].[Users] SET [Hits] = ([Hits] + @q0) WHERE [Id] = @q1; '
        'SELECT @@ROWCOUNT AS [mssql_affected];',
      );
      expect(fake.onlyCall.parameters['q0'], 1);
    });

    test('by an amount, and downward', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(fake).decrement(5, 'Hits', by: 3);
      expect(fake.onlyCall.sql, contains('[Hits] = ([Hits] - @q0)'));
      expect(fake.onlyCall.parameters['q0'], 3);
    });

    test('a column the table does not have is refused', () async {
      await expectLater(
        repo(FakeExecutor()).increment(5, 'NoSuch'),
        throwsArgumentError,
      );
    });

    test('an updated-at stamp still travels with it', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(
        fake,
        timestamps: const MssqlTimestamps(updatedColumn: 'UpdatedAt'),
      ).increment(5, 'Hits');
      expect(fake.onlyCall.sql, contains('[UpdatedAt] = SYSUTCDATETIME()'));
    });
  });

  group('firstOrCreate and friends', () {
    test('an existing row is returned without an insert', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 5, 'Name': 'ali'},
        ]);
      final r = await repo(
        fake,
      ).firstOrCreate(Col('Name').eq('ali'), () => row(0));
      expect(r.values['Id'], 5);
      expect(fake.calls, hasLength(1));
    });

    test('a missing row is inserted', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 9},
        ]);
      await repo(fake).firstOrCreate(Col('Name').eq('ali'), () => row(0));
      expect(fake.calls, hasLength(2));
      expect(fake.calls.last.sql, startsWith('INSERT INTO'));
    });

    test('the lookup asks for one row only', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake).firstWhere(Col('Name').eq('ali'));
      expect(fake.onlyCall.sql, contains('TOP (@q0)'));
    });

    test('firstOrNew never writes', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      final r = await repo(fake).firstOrNew(Col('Name').eq('x'), () => row(0));
      expect(r.values['Id'], 0);
      expect(fake.calls, hasLength(1));
    });

    test('updateOrCreate updates when the row is there', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 5, 'Name': 'old'},
        ])
        ..affected.add(1);
      await repo(
        fake,
      ).updateOrCreate(Col('Name').eq('old'), (existing) => row(5));
      expect(fake.calls, hasLength(2));
      expect(fake.calls.last.sql, startsWith('UPDATE'));
    });

    test('and inserts when it is not', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 9},
        ]);
      await repo(
        fake,
      ).updateOrCreate(Col('Name').eq('x'), (existing) => row(0));
      expect(fake.calls.last.sql, startsWith('INSERT INTO'));
    });

    test(
      'createOrFirst reads the winner after SQL Server unique errors',
      () async {
        for (final code in <int>[2601, 2627]) {
          final fake = FakeExecutor()
            ..executeErrors.add(
              MssqlException(
                type: MssqlErrorType.constraint,
                code: code,
                message: 'duplicate',
              ),
            )
            ..replies.add(<Map<String, Object?>>[
              <String, Object?>{'Id': 9, 'Name': 'winner'},
            ]);

          final found = await repo(
            fake,
          ).createOrFirst(Col('Name').eq('winner'), () => row(0));

          expect(found.values['Id'], 9);
          expect(fake.calls, hasLength(2));
          expect(fake.calls.last.sql, contains('TOP'));
        }
      },
    );

    test('createOrFirst does not swallow other database errors', () async {
      final error = MssqlException(
        type: MssqlErrorType.querySyntax,
        code: 102,
        message: 'syntax',
      );
      final fake = FakeExecutor()..executeErrors.add(error);
      await expectLater(
        repo(fake).createOrFirst(Col('Name').eq('x'), () => row(0)),
        throwsA(same(error)),
      );
      expect(fake.calls, hasLength(1));
    });

    test(
      'createOrFirst rethrows a duplicate when no winner can be found',
      () async {
        final error = MssqlException(
          type: MssqlErrorType.constraint,
          code: 2627,
          message: 'duplicate',
        );
        final fake = FakeExecutor()
          ..executeErrors.add(error)
          ..replies.add(<Map<String, Object?>>[]);
        await expectLater(
          repo(fake).createOrFirst(Col('Name').eq('gone'), () => row(0)),
          throwsA(same(error)),
        );
        expect(fake.calls, hasLength(2));
      },
    );
  });

  group('locking hints', () {
    test('lockForUpdate and sharedLock render their hints', () {
      expect(
        MssqlQuery.from('dbo.Users').lockForUpdate().compile().sql,
        'SELECT * FROM [dbo].[Users] WITH (UPDLOCK, ROWLOCK)',
      );
      expect(
        MssqlQuery.from('dbo.Users').sharedLock().compile().sql,
        'SELECT * FROM [dbo].[Users] WITH (HOLDLOCK, ROWLOCK)',
      );
    });

    test('an arbitrary hint passes through', () {
      expect(
        MssqlQuery.from('T').withHint('NOLOCK').compile().sql,
        'SELECT * FROM [T] WITH (NOLOCK)',
      );
    });

    test('the hint sits on the source, before any join', () {
      final sql = MssqlQuery.from('A')
          .lockForUpdate()
          .innerJoin('B', on: Col('A.x').eqCol('B.x'))
          .compile()
          .sql;
      expect(sql, contains('FROM [A] WITH (UPDLOCK, ROWLOCK) INNER JOIN [B]'));
    });
  });

  group('updateWhere', () {
    test(
      'writes the values it is given, bound rather than interpolated',
      () async {
        final fake = FakeExecutor()..affected.add(4);
        final changed = await repo(
          fake,
        ).updateWhere(Col('Name').eq('Ali'), <String, Object?>{'Hits': 0});
        expect(changed, 4);
        expect(fake.onlyCall.sql, startsWith('UPDATE [dbo].[Users] SET'));
        expect(fake.onlyCall.sql, contains('[Hits] = @'));
        expect(fake.onlyCall.parameters.values, contains(0));
        expect(fake.onlyCall.sql, isNot(contains("'Ali'")));
      },
    );

    test('stamps the updated column, which the raw builder would not', () async {
      final fake = FakeExecutor()..affected.add(2);
      await repo(
        fake,
        timestamps: const MssqlTimestamps(updatedColumn: 'UpdatedAt'),
      ).updateWhere(Col('TenantId').eq(1), <String, Object?>{'Name': 'x'});
      expect(fake.onlyCall.sql, contains('[UpdatedAt] = SYSUTCDATETIME()'));
    });

    test('does not touch the created column', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(
        fake,
        timestamps: const MssqlTimestamps(
          createdColumn: 'CreatedAt',
          updatedColumn: 'UpdatedAt',
        ),
      ).updateWhere(Col('Id').eq(1), <String, Object?>{'Name': 'x'});
      expect(fake.onlyCall.sql, isNot(contains('CreatedAt')));
    });

    test('skips the trashed rows on a soft-deleting table', () async {
      final fake = FakeExecutor()..affected.add(3);
      await repo(
        fake,
        softDelete: softDelete,
      ).updateWhere(Col('Name').eq('Ali'), <String, Object?>{'Hits': 1});
      expect(fake.onlyCall.sql, contains('[DeletedAt] IS NULL'));
    });

    test('reaches the trashed rows when withTrashed asked for them', () async {
      final fake = FakeExecutor()..affected.add(3);
      await repo(fake, softDelete: softDelete).withTrashed().updateWhere(
        Col('Name').eq('Ali'),
        <String, Object?>{'Hits': 1},
      );
      expect(fake.onlyCall.sql, isNot(contains('DeletedAt')));
    });

    test('applies the global scopes too', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(
        fake,
        scopes: <MssqlScope>[MssqlScope('tenant', () => Col('TenantId').eq(7))],
      ).updateWhere(Col('Name').eq('Ali'), <String, Object?>{'Hits': 1});
      expect(fake.onlyCall.sql, contains('[TenantId] ='));
      expect(fake.onlyCall.parameters.values, contains(7));
    });

    test(
      'an expression passes through as SQL rather than being bound',
      () async {
        final fake = FakeExecutor()..affected.add(9);
        await repo(fake).updateWhere(Col('TenantId').eq(1), <String, Object?>{
          'Hits': MssqlArithmetic(Col('Hits'), MssqlArithmeticOperator.add, 1),
        });
        expect(fake.onlyCall.sql, contains('[Hits] = ([Hits] +'));
      },
    );

    test('binds a null with the column type rather than a bare null', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(
        fake,
      ).updateWhere(Col('Id').eq(1), <String, Object?>{'Name': null});
      final value = fake.onlyCall.bound.values.first;
      expect(value, isA<MssqlValue>());
      expect((value! as MssqlValue).type, MssqlType.nvarchar);
    });

    test('refuses to write nothing', () async {
      await expectLater(
        repo(
          FakeExecutor(),
        ).updateWhere(Col('Id').eq(1), const <String, Object?>{}),
        throwsArgumentError,
      );
    });

    test('refuses a column the table does not have', () async {
      await expectLater(
        repo(FakeExecutor()).updateWhere(
          Col('Id').eq(1),
          const <String, Object?>{'NoSuchColumn': 1},
        ),
        throwsArgumentError,
      );
    });

    test('refuses to rewrite the primary key in bulk', () async {
      await expectLater(
        repo(
          FakeExecutor(),
        ).updateWhere(Col('Name').eq('Ali'), const <String, Object?>{'Id': 2}),
        throwsArgumentError,
      );
    });

    test('costs one round trip', () async {
      final fake = FakeExecutor()..affected.add(1);
      await repo(
        fake,
      ).updateWhere(Col('Id').eq(1), <String, Object?>{'Name': 'x'});
      expect(fake.calls, hasLength(1));
    });
  });

  group('existsWhere', () {
    test('asks for one row rather than counting them all', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'': 1},
        ]);
      expect(await repo(fake).existsWhere(Col('Name').eq('Ali')), isTrue);
      expect(fake.onlyCall.sql, startsWith('SELECT TOP (@'));
      expect(fake.onlyCall.parameters.values, contains(1));
      expect(fake.onlyCall.sql, isNot(contains('COUNT')));
    });

    test('no rows back means no', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      expect(await repo(fake).existsWhere(Col('Name').eq('Yok')), isFalse);
    });

    test('a soft-deleted row does not exist', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(
        fake,
        softDelete: softDelete,
      ).existsWhere(Col('Name').eq('Ali'));
      expect(fake.onlyCall.sql, contains('[DeletedAt] IS NULL'));
    });

    test('unless withTrashed said to look', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(
        fake,
        softDelete: softDelete,
      ).withTrashed().existsWhere(Col('Name').eq('Ali'));
      expect(fake.onlyCall.sql, isNot(contains('DeletedAt')));
    });

    test('the global scopes apply', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(
        fake,
        scopes: <MssqlScope>[MssqlScope('tenant', () => Col('TenantId').eq(7))],
      ).existsWhere(Col('Name').eq('Ali'));
      expect(fake.onlyCall.sql, contains('[TenantId] ='));
    });

    test('is idempotent, so a dropped connection can be retried', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake).existsWhere(Col('Id').eq(1));
      expect(fake.onlyCall.idempotent, isTrue);
    });

    test('exists(key) goes the same way', () async {
      final fake = FakeExecutor()..replies.add(<Map<String, Object?>>[]);
      await repo(fake).exists(1);
      expect(fake.onlyCall.sql, startsWith('SELECT TOP (@'));
      expect(fake.onlyCall.sql, contains('[Id] ='));
    });
  });
}

