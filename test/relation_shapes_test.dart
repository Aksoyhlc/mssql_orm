import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_executor.dart';

class Row {
  const Row(this.values, [this.relations = const <String, Object?>{}]);
  final Map<String, Object?> values;
  final Map<String, Object?> relations;
  Row withRelations(Map<String, Object?> more) =>
      Row(values, <String, Object?>{...relations, ...more});
  @override
  String toString() => 'Row($values)';
}

MssqlTableBinding<Row> bindingFor(
  String table,
  List<String> columns, {
  List<String> primaryKey = const <String>['Id'],
}) => MssqlTableBinding<Row>(
  schema: 'dbo',
  table: table,
  primaryKey: primaryKey,
  columns: <MssqlBoundColumn>[
    for (final c in columns)
      MssqlBoundColumn(name: c, type: MssqlType.varchar, nullable: true),
  ],
  fromRow: (row) => Row(row.toMap()),
  toColumns: (row) => row.values,
  readColumn: (row, name) => row.values[name],
  applyRelations: (row, relations) => row.withRelations(relations),
);

final users = bindingFor('Users', <String>['Id', 'Name']);
final roles = bindingFor('Roles', <String>['Id', 'Title']);
final userRoles = bindingFor(
  'UserRoles',
  <String>['UserId', 'RoleId'],
  primaryKey: <String>['UserId', 'RoleId'],
);
final posts = bindingFor('Posts', <String>['Id', 'UserId']);
final comments = bindingFor('Comments', <String>[
  'Id',
  'PostId',
  'CommentableType',
  'CommentableId',
]);
final videos = bindingFor('Videos', <String>['Id', 'Title']);

MssqlRepository<Row, String> repo(
  FakeExecutor fake,
  MssqlTableBinding<Row> b,
) => MssqlRepository<Row, String>(
  fake,
  binding: b,
  dialect: MssqlDialect.sql2012,
);

void main() {
  group('belongsToMany, through a pivot', () {
    MssqlRelation<Row, Row> relation() => MssqlRelation<Row, Row>(
      name: 'roles',
      kind: MssqlRelationKind.belongsToMany,
      targetBinding: roles,
      localColumns: const <String>['Id'],
      foreignColumns: const <String>['Id'],
      through: MssqlRelationThrough(
        binding: userRoles,
        nearColumns: const <String>['UserId'],
        farColumns: const <String>['RoleId'],
      ),
    );

    test('costs two queries, whatever the number of parents', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          for (var i = 1; i <= 200; i++)
            <String, Object?>{'Id': '$i', 'Name': 'u$i'},
        ])
        ..replies.add(<Map<String, Object?>>[
          for (var i = 1; i <= 200; i++)
            <String, Object?>{'UserId': '$i', 'RoleId': 'admin'},
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 'admin', 'Title': 'Administrator'},
        ]);

      final rows = await repo(
        fake,
        users,
      ).findAll(include: <MssqlRelation<Row, Object?>>[relation()]);
      expect(fake.calls, hasLength(3));
      expect(rows, hasLength(200));
      final loaded = (rows.first.relations['roles']! as List<Object?>)
          .cast<Row>();
      expect(loaded.single.values['Title'], 'Administrator');
    });

    test(
      'the pivot is read by the near column, the target by the far one',
      () async {
        final fake = FakeExecutor()
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{'Id': '1', 'Name': 'a'},
          ])
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{'UserId': '1', 'RoleId': 'r1'},
          ])
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{'Id': 'r1', 'Title': 't'},
          ]);
        await repo(
          fake,
          users,
        ).findAll(include: <MssqlRelation<Row, Object?>>[relation()]);
        expect(fake.calls[1].sql, contains('FROM [dbo].[UserRoles]'));
        expect(fake.calls[1].sql, contains('WHERE [UserId] IN'));
        expect(fake.calls[2].sql, contains('FROM [dbo].[Roles]'));
        expect(fake.calls[2].sql, contains('WHERE [Id] IN'));
      },
    );

    test('two users sharing a role each get it', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': '1', 'Name': 'a'},
          <String, Object?>{'Id': '2', 'Name': 'b'},
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'UserId': '1', 'RoleId': 'r1'},
          <String, Object?>{'UserId': '2', 'RoleId': 'r1'},
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 'r1', 'Title': 't'},
        ]);
      final rows = await repo(
        fake,
        users,
      ).findAll(include: <MssqlRelation<Row, Object?>>[relation()]);
      for (final row in rows) {
        expect((row.relations['roles']! as List<Object?>), hasLength(1));
      }
      expect(fake.calls, hasLength(3));
    });

    test('an empty pivot means the target is never queried', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': '1', 'Name': 'a'},
        ])
        ..replies.add(<Map<String, Object?>>[]);
      await repo(
        fake,
        users,
      ).findAll(include: <MssqlRelation<Row, Object?>>[relation()]);
      expect(fake.calls, hasLength(2));
    });

    test('a through relation without a through table is refused', () {
      expect(
        () => MssqlRelation<Row, Row>(
          name: 'roles',
          kind: MssqlRelationKind.belongsToMany,
          targetBinding: roles,
          localColumns: const <String>['Id'],
          foreignColumns: const <String>['Id'],
        ),
        throwsArgumentError,
      );
    });
  });

  group('hasManyThrough', () {
    test('reaches the far table through the middle one', () async {
      final relation = MssqlRelation<Row, Row>(
        name: 'comments',
        kind: MssqlRelationKind.hasManyThrough,
        targetBinding: comments,
        localColumns: const <String>['Id'],
        foreignColumns: const <String>['PostId'],
        through: MssqlRelationThrough(
          binding: posts,
          nearColumns: const <String>['UserId'],
          farColumns: const <String>['Id'],
        ),
      );
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 'u1', 'Name': 'a'},
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 'p1', 'UserId': 'u1'},
          <String, Object?>{'Id': 'p2', 'UserId': 'u1'},
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 'c1', 'PostId': 'p1'},
          <String, Object?>{'Id': 'c2', 'PostId': 'p2'},
        ]);
      final rows = await repo(
        fake,
        users,
      ).findAll(include: <MssqlRelation<Row, Object?>>[relation]);
      expect(fake.calls, hasLength(3));
      expect(
        (rows.single.relations['comments']! as List<Object?>),
        hasLength(2),
      );
    });
  });

  group('morphTo', () {
    MssqlRelation<Row, Row> relation({
      MssqlMorphUnknown unknown = MssqlMorphUnknown.error,
    }) => MssqlRelation<Row, Row>(
      name: 'commentable',
      kind: MssqlRelationKind.morphTo,
      targetBinding: posts,
      localColumns: const <String>['CommentableId'],
      foreignColumns: const <String>['Id'],
      morph: MssqlMorph(
        typeColumn: 'CommentableType',
        idColumn: 'CommentableId',
        unknown: unknown,
        targets: <String, MssqlTableBinding<Object?>>{
          'post': posts,
          'video': videos,
        },
      ),
    );

    test('costs one query per distinct type, not one per row', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          for (var i = 1; i <= 50; i++)
            <String, Object?>{
              'Id': 'c$i',
              'PostId': null,
              'CommentableType': i.isEven ? 'post' : 'video',
              'CommentableId': 'x${i % 5}',
            },
        ])
        ..replies.add(<Map<String, Object?>>[
          for (var i = 0; i < 5; i++)
            <String, Object?>{'Id': 'x$i', 'UserId': 'u'},
        ])
        ..replies.add(<Map<String, Object?>>[
          for (var i = 0; i < 5; i++)
            <String, Object?>{'Id': 'x$i', 'Title': 't'},
        ]);
      final rows = await repo(
        fake,
        comments,
      ).findAll(include: <MssqlRelation<Row, Object?>>[relation()]);
      expect(fake.calls, hasLength(3));
      expect(rows, hasLength(50));
      expect(rows.first.relations['commentable'], isNotNull);
    });

    test('each group is read from its own table', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{
            'Id': 'c1',
            'PostId': null,
            'CommentableType': 'post',
            'CommentableId': 'p1',
          },
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 'p1', 'UserId': 'u'},
        ]);
      await repo(
        fake,
        comments,
      ).findAll(include: <MssqlRelation<Row, Object?>>[relation()]);
      expect(fake.calls.last.sql, contains('FROM [dbo].[Posts]'));
    });

    test(
      'same id in different morph types attaches the matching row',
      () async {
        final fake = FakeExecutor()
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{
              'Id': 'c1',
              'PostId': null,
              'CommentableType': 'post',
              'CommentableId': '1',
            },
            <String, Object?>{
              'Id': 'c2',
              'PostId': null,
              'CommentableType': 'video',
              'CommentableId': '1',
            },
          ])
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{'Id': '1', 'UserId': 'post-owner'},
          ])
          ..replies.add(<Map<String, Object?>>[
            <String, Object?>{'Id': '1', 'Title': 'video-title'},
          ]);

        final rows = await repo(
          fake,
          comments,
        ).findAll(include: <MssqlRelation<Row, Object?>>[relation()]);

        final post = rows[0].relations['commentable']! as Row;
        final video = rows[1].relations['commentable']! as Row;
        expect(post.values['UserId'], 'post-owner');
        expect(video.values['Title'], 'video-title');
      },
    );

    test('an unmapped type is refused, not guessed at', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{
            'Id': 'c1',
            'PostId': null,
            'CommentableType': 'podcast',
            'CommentableId': 'x1',
          },
        ]);
      await expectLater(
        repo(
          fake,
          comments,
        ).findAll(include: <MssqlRelation<Row, Object?>>[relation()]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('podcast'), contains('morph map')),
          ),
        ),
      );
    });

    test('an unmapped type is a warning when ignore says so', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{
            'Id': 'c1',
            'PostId': null,
            'CommentableType': 'podcast',
            'CommentableId': 'x1',
          },
        ]);
      final repository = repo(fake, comments);
      final rows = await repository.findAll(
        include: <MssqlRelation<Row, Object?>>[
          relation(unknown: MssqlMorphUnknown.ignore),
        ],
      );
      expect(fake.calls, hasLength(1));
      expect(repository.warnings.single, contains('podcast'));
      expect(rows.single.relations['commentable'], isNull);
    });

    test('a row with no type or id is skipped', () async {
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{
            'Id': 'c1',
            'PostId': null,
            'CommentableType': null,
            'CommentableId': null,
          },
        ]);
      final repository = repo(fake, comments);
      await repository.findAll(
        include: <MssqlRelation<Row, Object?>>[relation()],
      );
      expect(fake.calls, hasLength(1));
      expect(repository.warnings, isEmpty);
    });

    test('a morph relation without a morph declaration is refused', () {
      expect(
        () => MssqlRelation<Row, Row>(
          name: 'commentable',
          kind: MssqlRelationKind.morphTo,
          targetBinding: posts,
          localColumns: const <String>['CommentableId'],
          foreignColumns: const <String>['Id'],
        ),
        throwsArgumentError,
      );
    });
  });

  group('morphMany', () {
    test('filters the shared child table by the type column', () async {
      final relation = MssqlRelation<Row, Row>(
        name: 'comments',
        kind: MssqlRelationKind.morphMany,
        targetBinding: comments,
        localColumns: const <String>['Id'],
        foreignColumns: const <String>['CommentableId'],
        morph: MssqlMorph(
          typeColumn: 'CommentableType',
          idColumn: 'CommentableId',
          typeValue: 'post',
        ),
      );
      final fake = FakeExecutor()
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{'Id': 'p1', 'UserId': 'u'},
        ])
        ..replies.add(<Map<String, Object?>>[
          <String, Object?>{
            'Id': 'c1',
            'PostId': null,
            'CommentableType': 'post',
            'CommentableId': 'p1',
          },
        ]);
      final rows = await repo(
        fake,
        posts,
      ).findAll(include: <MssqlRelation<Row, Object?>>[relation]);
      expect(fake.calls, hasLength(2));
      expect(fake.calls.last.sql, contains('[CommentableType] = @'));
      expect(
        (rows.single.relations['comments']! as List<Object?>),
        hasLength(1),
      );
    });
  });

  group('cardinality', () {
    test('the to-one shapes are exactly the ones that yield a single row', () {
      const toOne = <MssqlRelationKind>{
        MssqlRelationKind.belongsTo,
        MssqlRelationKind.hasOne,
        MssqlRelationKind.hasOneThrough,
        MssqlRelationKind.morphTo,
        MssqlRelationKind.morphOne,
      };
      for (final kind in MssqlRelationKind.values) {
        final relation = MssqlRelation<Row, Row>(
          name: 'r',
          kind: kind,
          targetBinding: roles,
          localColumns: const <String>['Id'],
          foreignColumns: const <String>['Id'],
          through: MssqlRelationThrough(
            binding: userRoles,
            nearColumns: const <String>['UserId'],
            farColumns: const <String>['RoleId'],
          ),
          morph: MssqlMorph(typeColumn: 'T', idColumn: 'I'),
        );
        expect(relation.isToOne, toOne.contains(kind), reason: kind.name);
      }
    });

    test('hasOne and hasMany differ only in cardinality', () {
      MssqlRelation<Row, Row> of(MssqlRelationKind kind) =>
          MssqlRelation<Row, Row>(
            name: 'r',
            kind: kind,
            targetBinding: posts,
            localColumns: const <String>['Id'],
            foreignColumns: const <String>['UserId'],
          );
      expect(
        of(MssqlRelationKind.hasOne).localColumns,
        of(MssqlRelationKind.hasMany).localColumns,
      );
      expect(
        of(MssqlRelationKind.hasOne).foreignColumns,
        of(MssqlRelationKind.hasMany).foreignColumns,
      );
      expect(of(MssqlRelationKind.hasOne).isToOne, isTrue);
      expect(of(MssqlRelationKind.hasMany).isToOne, isFalse);
    });
  });
}

