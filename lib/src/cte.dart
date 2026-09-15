import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'expression.dart';
import 'operators.dart';
import 'predicates.dart';
import 'query.dart';
import 'source_ref.dart';
import 'typed_column.dart';

/// One column a [MssqlTypedCte] exposes.
///
/// A name and a SQL type together, because a common table expression's column
/// list is the one place SQL Server takes the names on trust: it accepts
/// whatever the `WITH tree (a, b, c)` clause says and only finds out at run
/// time that the members project four columns, or that the second one is text
/// where the third member expects a number.
@immutable
class MssqlCteField {
  MssqlCteField(this.name, this.columnType) {
    MssqlSql.quoteIdentifier(name);
  }

  final String name;
  final MssqlColumnType columnType;

  /// Which of SQL Server's type families this field is in.
  MssqlTypeFamily get family => MssqlSqlType.familyOf(columnType.type);
}

/// A common table expression whose exposed fields are declared, and whose
/// members are checked against them before any SQL is written.
///
/// [MssqlCte] is the clause: a name, a query, and a list of column names it
/// takes at face value. This is the description of what comes out of it, and
/// it is what makes the difference between a mistake found here and error 8158
/// — "has more columns than were specified in the column list" — arriving from
/// the server with nothing but the expression's name attached. The recursive
/// case is where that matters most, since a recursive member is written
/// separately from its anchor and has to agree with it position by position.
///
/// Types are compared by family rather than exactly. `Depth + 1` widens an
/// `int` and SQL Server reconciles that happily; what it cannot reconcile is
/// one member projecting text where the other projects a number, and that is
/// what a family comparison catches without refusing the queries that work.
@immutable
class MssqlTypedCte {
  MssqlTypedCte._({
    required this.name,
    required this.fields,
    required this.members,
    required this.maxRecursion,
    required this.isRecursive,
  });

  /// A plain expression: one query, named fields.
  factory MssqlTypedCte({
    required String name,
    required Iterable<MssqlCteField> fields,
    required MssqlSelectQuery query,
  }) {
    final declared = List<MssqlCteField>.unmodifiable(fields);
    _validateShape(name, declared, null);
    _validateMember(name, declared, query, 'the query');
    return MssqlTypedCte._(
      name: name,
      fields: declared,
      members: List<MssqlSelectQuery>.unmodifiable(<MssqlSelectQuery>[query]),
      maxRecursion: null,
      isRecursive: false,
    );
  }

  /// A recursive expression: an anchor member, then the member that selects
  /// from [name] itself.
  ///
  /// [maxRecursion] becomes `OPTION (MAXRECURSION n)` on the statement. It is
  /// a ceiling on the server's recursion and nothing else — in particular it
  /// is not a depth filter, and 0 removes the ceiling, which turns a cycle in
  /// the data from an error into a query that never returns.
  factory MssqlTypedCte.recursive({
    required String name,
    required Iterable<MssqlCteField> fields,
    required MssqlSelectQuery anchor,
    required MssqlSelectQuery recursiveMember,
    int? maxRecursion,
  }) {
    final declared = List<MssqlCteField>.unmodifiable(fields);
    _validateShape(name, declared, maxRecursion);
    _validateMember(name, declared, anchor, 'the anchor member');
    _validateMember(name, declared, recursiveMember, 'the recursive member');
    return MssqlTypedCte._(
      name: name,
      fields: declared,
      members: List<MssqlSelectQuery>.unmodifiable(<MssqlSelectQuery>[
        anchor,
        recursiveMember,
      ]),
      maxRecursion: maxRecursion,
      isRecursive: true,
    );
  }

  final String name;

  /// The fields, in the order the members project them.
  final List<MssqlCteField> fields;

  /// One member for a plain expression, two for a recursive one.
  final List<MssqlSelectQuery> members;

  /// `OPTION (MAXRECURSION n)`, validated on the way in.
  final int? maxRecursion;

  final bool isRecursive;

  /// The field names, for the `WITH name (…)` column list.
  List<String> get columns =>
      fields.map((field) => field.name).toList(growable: false);

  /// This expression as a source, so its columns qualify themselves with
  /// whatever the query ends up calling it.
  MssqlSourceRef get ref => MssqlSourceRef.named(name);

  /// The field called [field], as a column that can be selected, compared and
  /// ordered by.
  ///
  /// Typed rather than an untyped `Col('tree.Depth')`: the field's SQL type is
  /// declared right here, so a value compared against it binds as that type
  /// instead of as whatever the driver infers.
  MssqlTypedColumn<Object?> column(String field) {
    for (final declared in fields) {
      if (declared.name.toLowerCase() == field.toLowerCase()) {
        return MssqlTypedColumn<Object?>.of(
          source: ref,
          name: declared.name,
          quotedName: MssqlSql.quoteIdentifier(declared.name),
          columnType: declared.columnType,
        );
      }
    }
    throw ArgumentError.value(
      field,
      'field',
      'the expression "$name" has no field called that. It declares: '
          '${columns.join(', ')}.',
    );
  }

  /// The clause this compiles to.
  MssqlCte toCte() => isRecursive
      ? MssqlCte.recursive(
          name,
          anchor: members.first,
          recursive: members.last,
          columns: columns,
        )
      : MssqlCte(name, members.single, columns: columns);

  /// A query that reads this expression, with the `WITH` clause already on it
  /// and every field projected by name.
  ///
  /// The outermost query, and it has to stay that way: SQL Server allows a
  /// `WITH` clause only at the start of a statement, so this cannot be nested
  /// as a derived table or a subquery. A join to the table the walk came from
  /// goes *onto* the query this returns.
  MssqlQuery read() => MssqlQuery.from(
    name,
    ref: ref,
  ).select(fields.map((field) => column(field.name))).withTypedCte(this);

  static void _validateShape(
    String name,
    List<MssqlCteField> fields,
    int? maxRecursion,
  ) {
    MssqlSql.quoteIdentifier(name);
    if (fields.isEmpty) {
      throw ArgumentError.value(
        fields,
        'fields',
        'the expression "$name" has to declare at least one field: a typed '
            'expression that names nothing is an untyped one.',
      );
    }
    final seen = <String>{};
    for (final field in fields) {
      if (!seen.add(field.name.toLowerCase())) {
        throw ArgumentError.value(
          field.name,
          'fields',
          'the expression "$name" declares "${field.name}" twice. SQL '
              'Server matches names without regard to case, and nothing '
              'could refer to either one.',
        );
      }
    }
    if (maxRecursion != null && (maxRecursion < 0 || maxRecursion > 32767)) {
      throw ArgumentError.value(
        maxRecursion,
        'maxRecursion',
        'SQL Server accepts 0 to 32767, where 0 means no ceiling. The '
            'expression is "$name".',
      );
    }
  }

  /// Checks one member's projection against the declared fields.
  ///
  /// A union member is checked in turn rather than as a whole: each of them
  /// projects the fields on its own, and the one that disagrees is the one
  /// worth naming.
  static void _validateMember(
    String name,
    List<MssqlCteField> fields,
    MssqlSelectQuery member,
    String role,
  ) {
    if (member is MssqlSetQuery) {
      for (final inner in member.members) {
        _validateMember(name, fields, inner, role);
      }
      return;
    }
    final count = member.projectionCount;
    if (count == null) {
      throw ArgumentError.value(
        member,
        role,
        '$role of the expression "$name" does not say what it projects, so '
        'nothing can be checked against the ${fields.length} declared '
        'fields. Call select() and name them rather than relying on *.',
      );
    }
    if (count != fields.length) {
      throw ArgumentError.value(
        member,
        role,
        '$role of the expression "$name" projects $count expressions, but it '
        'declares ${fields.length} fields (${fields.map((f) => f.name).join(', ')}). '
        'SQL Server reports this as error 8158 with nothing but the '
        'expression name attached.',
      );
    }
    if (member is! MssqlQuery) return;
    for (var i = 0; i < fields.length; i++) {
      final projected = MssqlSqlType.of(member.projection[i]);
      if (projected == null) continue;
      final actual = MssqlSqlType.familyOf(projected.type);
      final declared = fields[i].family;
      if (actual == declared) continue;
      throw ArgumentError.value(
        member,
        role,
        '$role of the expression "$name" projects a $actual '
        '(${projected.type}) in position ${i + 1}, where the field '
        '"${fields[i].name}" is declared a $declared '
        '(${fields[i].columnType.type}). Change the declaration or cast '
        'the projected expression.',
      );
    }
  }
}

/// Prefixes a query with a typed expression.
extension MssqlTypedCteClauses on MssqlQuery {
  /// Adds [cte] to the `WITH` clause, carrying its recursion ceiling with it.
  MssqlQuery withTypedCte(MssqlTypedCte cte) =>
      withExpression(cte.toCte(), maxRecursion: cte.maxRecursion);
}

/// What a hierarchy walk does when the data has a cycle.
///
/// A category that is its own ancestor is a data bug; the choice is to report
/// it or to stop walking.
enum MssqlCycleHandling {
  /// Let the recursion hit its ceiling and fail: SQL Server raises error 530
  /// naming `MAXRECURSION`.
  ///
  /// The default. A cycle in a category tree means the data is wrong, and a
  /// query that quietly returns a partial answer hides it — the report looks
  /// right and is short by a branch.
  error,

  /// Carry the path walked so far and refuse to re-enter a key already on it.
  ///
  /// Costs a growing `nvarchar(max)` per row and a `CHARINDEX` per candidate,
  /// which is real; it is the right trade only where a cycle is known to be
  /// possible and the rest of the tree still has to come back.
  skipVisited,
}

/// A table whose rows point at other rows of the same table: a category tree,
/// an organisation chart, a bill of materials.
///
/// Holds the two columns that make the walk possible, so the recursive query
/// is built once here rather than written out at every call site. Generated
/// code constructs one of these for a table with a single self-referencing
/// foreign key — or for the one a config file picked, when there are several —
/// and nothing about the walk itself lives in the generated file.
@immutable
class MssqlHierarchy<K extends Object> {
  MssqlHierarchy({
    required Iterable<String> tableParts,
    required this.key,
    required this.parentKey,
    this.name = 'descendants',
  }) : tableParts = List<String>.unmodifiable(tableParts) {
    if (this.tableParts.isEmpty) {
      throw ArgumentError.value(
        tableParts,
        'tableParts',
        'name the table the walk starts from, as its parts: '
            "['dbo', 'Categories'].",
      );
    }
    MssqlSql.quoteIdentifier(name);
    _requireBound(key, 'key');
    _requireBound(parentKey, 'parentKey');
    if (key.source != parentKey.source) {
      throw ArgumentError.value(
        parentKey,
        'parentKey',
        'a hierarchy walks one table: ${key.name} belongs to '
            '${key.source!.qualifiedName} and ${parentKey.name} to '
            '${parentKey.source!.qualifiedName}. A foreign key into another '
            'table is a join, not a walk.',
      );
    }
  }

  /// The identifier parts of the table, as [MssqlQuery.fromParts] takes them.
  final List<String> tableParts;

  /// The primary key each row is found by.
  final MssqlTypedColumn<K> key;

  /// The column holding the key of the parent row, null at a root.
  final MssqlTypedColumn<K> parentKey;

  /// What the expression is called inside the statement.
  final String name;

  /// The field the walked row's own key is exposed as.
  static const String keyField = 'Key';

  /// The field the walked row's parent key is exposed as.
  static const String parentField = 'ParentKey';

  /// The field holding the distance from the root, which is 0 at the root.
  static const String depthField = 'Depth';

  /// The field holding the keys walked through, present only for
  /// [MssqlCycleHandling.skipVisited].
  static const String pathField = 'Path';

  /// Every row reachable from [root] by following [parentKey] downwards.
  ///
  /// [maxDepth] limits the walk: the root is depth 0, so `maxDepth: 2` returns
  /// children and grandchildren. It is applied inside the recursive member so
  /// the server stops expanding rather than expanding and then filtering, and
  /// it is a bound value, not text.
  ///
  /// [maxRecursion] is a different limit and stays separate on purpose:
  /// `OPTION (MAXRECURSION n)` is SQL Server's guard against a runaway
  /// recursion and it fails the query, while [maxDepth] is part of the
  /// question being asked and returns rows. Left null, SQL Server's own
  /// default of 100 applies — which is the guard, and worth leaving in place.
  ///
  /// The returned query is the outermost one: a `WITH` clause is only legal at
  /// the start of a statement, so this cannot be nested. Join the table back
  /// on to it to read the rows themselves:
  ///
  /// ```dart
  /// hierarchy
  ///     .descendantsOf(rootId, maxDepth: 3)
  ///     .innerJoin('dbo.Categories', as: 'c',
  ///         on: Col('c.Id').eqCol('descendants.Key'))
  ///     .orderBy([Col('descendants.Depth').asc()]);
  /// ```
  MssqlQuery descendantsOf(
    K root, {
    int? maxDepth,
    bool includeRoot = true,
    MssqlCycleHandling cycles = MssqlCycleHandling.error,
    int? maxRecursion,
  }) {
    final cte = descendantsCte(
      root,
      maxDepth: maxDepth,
      cycles: cycles,
      maxRecursion: maxRecursion,
    );
    final walk = cte.read();
    // The root is walked either way, because the recursion has to start
    // somewhere; excluding it is a filter on the result rather than a
    // different anchor.
    return includeRoot ? walk : walk.where(cte.column(depthField).gt(0));
  }

  /// The recursive expression behind [descendantsOf], on its own.
  ///
  /// For a caller that owns the statement and needs the walk as one of its
  /// `WITH` members rather than as the whole query — a generated
  /// `descendantsOf` on an entity query, for instance, which filters the
  /// table by these keys and still has its own scopes, ordering and
  /// includes to apply. [includeRoot] is not a parameter here because it is
  /// a filter on the result, not part of the expression: read
  /// [depthField] `> 0` to drop the root.
  MssqlTypedCte descendantsCte(
    K root, {
    int? maxDepth,
    MssqlCycleHandling cycles = MssqlCycleHandling.error,
    int? maxRecursion,
  }) {
    if (maxDepth != null && maxDepth < 0) {
      throw ArgumentError.value(
        maxDepth,
        'maxDepth',
        'depth counts generations below the root, which starts at 0. Pass '
            'includeRoot: false with no maxDepth to walk the whole subtree '
            'without the root itself.',
      );
    }
    final tracksPath = cycles == MssqlCycleHandling.skipVisited;

    final anchorRef = MssqlSourceRef.named(_anchorAlias);
    final anchorKey = key.at(anchorRef);
    final anchorParent = parentKey.at(anchorRef);
    final anchor =
        MssqlQuery.fromParts(tableParts, as: _anchorAlias, ref: anchorRef)
            .select(<MssqlExpression>[
              anchorKey.as(keyField),
              anchorParent.as(parentField),
              // CAST rather than a bare parameter: a recursive expression's
              // two members have to agree on the type of every column, and an
              // inferred int meeting `Depth + 1` is a coincidence rather than
              // an agreement.
              MssqlCast(const MssqlLiteral(0), 'int').as(depthField),
              if (tracksPath) _pathFrom(_slash, anchorKey).as(pathField),
            ])
            .where(anchorKey.eq(root));

    final childRef = MssqlSourceRef.named(_childAlias);
    final childKey = key.at(childRef);
    final childParent = parentKey.at(childRef);
    final walkedKey = Col('$_walkedAlias.$keyField');
    final walkedDepth = Col('$_walkedAlias.$depthField');
    final walkedPath = Col('$_walkedAlias.$pathField');
    var recursive =
        MssqlQuery.fromParts(tableParts, as: _childAlias, ref: childRef)
            .innerJoin(
              name,
              as: _walkedAlias,
              on: MssqlComparison(childParent, '=', walkedKey),
            )
            .select(<MssqlExpression>[
              childKey.as(keyField),
              childParent.as(parentField),
              MssqlArithmetic(
                walkedDepth,
                MssqlArithmeticOperator.add,
                1,
              ).as(depthField),
              if (tracksPath) _pathFrom(walkedPath, childKey).as(pathField),
            ]);
    if (maxDepth != null) {
      recursive = recursive.where(walkedDepth.lt(maxDepth));
    }
    if (tracksPath) {
      recursive = recursive.where(_notVisited(walkedPath, childKey));
    }

    final cte = MssqlTypedCte.recursive(
      name: name,
      fields: <MssqlCteField>[
        MssqlCteField(keyField, key.columnType!),
        MssqlCteField(parentField, parentKey.columnType!),
        MssqlCteField(
          depthField,
          const MssqlColumnType(type: MssqlType.int32, nullable: false),
        ),
        if (tracksPath)
          MssqlCteField(
            pathField,
            const MssqlColumnType(type: MssqlType.nvarchar, nullable: false),
          ),
      ],
      anchor: anchor,
      recursiveMember: recursive,
      maxRecursion: maxRecursion,
    );
    return cte;
  }

  static const String _anchorAlias = 'hierarchy_root';
  static const String _childAlias = 'hierarchy_child';
  static const String _walkedAlias = 'hierarchy_walked';
  static const MssqlLiteral _slash = MssqlLiteral('/');

  /// `prefix + CAST(key AS nvarchar(max)) + '/'`.
  ///
  /// Delimited on both sides so a search for `/12/` cannot match the key 112.
  /// `nvarchar(max)` because the two members of a recursive expression must
  /// agree on type exactly, and a declared length would truncate a deep path.
  static MssqlExpression _pathFrom(
    MssqlExpression prefix,
    MssqlExpression id,
  ) => MssqlCast(
    MssqlArithmetic(
      MssqlArithmetic(
        prefix,
        MssqlArithmeticOperator.add,
        MssqlCast(id, 'nvarchar(max)'),
      ),
      MssqlArithmeticOperator.add,
      _slash,
    ),
    'nvarchar(max)',
  );

  static MssqlCondition _notVisited(MssqlExpression path, MssqlExpression id) =>
      MssqlComparison(
        MssqlFunction('CHARINDEX', <MssqlExpression>[
          MssqlArithmetic(
            MssqlArithmetic(
              _slash,
              MssqlArithmeticOperator.add,
              MssqlCast(id, 'nvarchar(max)'),
            ),
            MssqlArithmeticOperator.add,
            _slash,
          ),
          path,
        ]),
        '=',
        const MssqlLiteral(0),
      );

  static void _requireBound(MssqlTypedColumn<Object?> column, String argument) {
    if (column.source == null || column.columnType == null) {
      throw ArgumentError.value(
        column,
        argument,
        'a hierarchy needs a generated column: the walk aliases the table '
        'twice and joins it to the expression, so a column written out in '
        'full would go on naming the unaliased table in all three places. '
        'It also needs the column\'s SQL type, to declare the field the '
        'expression exposes.',
      );
    }
  }
}
