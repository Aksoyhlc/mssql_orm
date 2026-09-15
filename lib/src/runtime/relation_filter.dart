import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../expression.dart';
import '../operators.dart';
import '../query.dart';
import '../subquery.dart';
import 'binding.dart';
import 'query_context.dart';
import 'relation.dart';

/// Builds a correlated `EXISTS` / `NOT EXISTS` subquery for [relation].
///
/// The parent table is not joined, so a matching child cannot multiply
/// parent rows. The same scopes, filters and through/morph shape the
/// include loader uses are applied here, so `whereHas` and `include` of
/// one handle mean the same set of children.
MssqlQuery relationExistsQuery<TParent, TChild>(
  MssqlRelation<TParent, TChild> relation, {
  required MssqlTableBinding<TParent> parent,
  required MssqlSession session,
  required MssqlDialect dialect,
  MssqlExpression? projection,
}) {
  final selected = projection ?? raw('1');
  if (relation.through != null) {
    return _throughExists(relation, parent, session, dialect, selected);
  }
  if (relation.kind == MssqlRelationKind.morphTo) {
    throw StateError(
      'whereHas("${relation.name}") cannot use morphTo: the counterpart '
      'table depends on a per-row discriminator, so a single EXISTS has '
      'no table to name. Filter the type column yourself, then whereHas '
      'each concrete target.',
    );
  }
  final child = relation.targetBinding;
  final context = MssqlQueryContext<TChild>(
    session: session,
    binding: child,
    dialect: dialect,
  );
  var query = context.scopedQuery(relation.scope).select(<MssqlExpression>[
    selected,
  ]);
  query = query.where(_correlate(parent, relation));
  final extra = _extra(relation);
  if (extra != null) query = query.where(extra);
  return _withNested(query, relation, session, dialect);
}

MssqlCondition _correlate<TParent, TChild>(
  MssqlTableBinding<TParent> parent,
  MssqlRelation<TParent, TChild> relation,
) {
  final parts = <MssqlCondition>[
    for (var i = 0; i < relation.localColumns.length; i++)
      Col(relation.foreignColumns[i]).eqExpr(
        MssqlColumnRef.inSource(
          source: parent.sourceRef,
          name: relation.localColumns[i],
          quotedName: MssqlSql.quoteIdentifier(relation.localColumns[i]),
        ),
      ),
  ];
  return parts.length == 1 ? parts.first : and(parts);
}

MssqlCondition? _extra<TParent, TChild>(
  MssqlRelation<TParent, TChild> relation,
) {
  final parts = <MssqlCondition>[...relation.where];
  final morph = relation.morph;
  if (morph?.typeValue != null) {
    parts.add(Col(morph!.typeColumn).eq(morph.typeValue));
  }
  if (parts.isEmpty) return null;
  if (parts.length == 1) return parts.first;
  return and(parts);
}

MssqlQuery _throughExists<TParent, TChild>(
  MssqlRelation<TParent, TChild> relation,
  MssqlTableBinding<TParent> parent,
  MssqlSession session,
  MssqlDialect dialect,
  MssqlExpression selected,
) {
  final through = relation.through!;
  final pivotCtx = MssqlQueryContext<Object?>(
    session: session,
    binding: through.binding,
    dialect: dialect,
  );
  var query = pivotCtx.scopedQuery(relation.scope).select(<MssqlExpression>[
    selected,
  ]);
  query = query.where(
    and(<MssqlCondition>[
      for (var i = 0; i < through.nearColumns.length; i++)
        Col(through.nearColumns[i]).eqExpr(
          MssqlColumnRef.inSource(
            source: parent.sourceRef,
            name: relation.localColumns[i],
            quotedName: MssqlSql.quoteIdentifier(relation.localColumns[i]),
          ),
        ),
    ]),
  );
  if (through.typeValue != null) {
    query = query.where(Col(through.typeColumn!).eq(through.typeValue));
  }
  final targetCtx = MssqlQueryContext<TChild>(
    session: session,
    binding: relation.targetBinding,
    dialect: dialect,
  );
  final target = targetCtx.scopedQuery(relation.scope).select(<MssqlExpression>[
    raw('1'),
  ]);
  var targetWhere = and(<MssqlCondition>[
    for (var i = 0; i < through.farColumns.length; i++)
      Col(relation.foreignColumns[i]).eqExpr(Col(through.farColumns[i])),
  ]);
  final extra = _extra(relation);
  if (extra != null) targetWhere = targetWhere & extra;
  var matched = target.where(targetWhere);
  matched = _withNested(matched, relation, session, dialect);
  query = query.whereExists(matched);
  return query;
}

/// Nested `then` / `include` filters as further correlated EXISTS.
///
/// Counting `orders.then(lines)` still counts orders that have matching
/// lines, not the lines themselves. A join of both tables would make an
/// order-count equal a line-count; a nested EXISTS does not.
MssqlQuery _withNested<TParent, TChild>(
  MssqlQuery query,
  MssqlRelation<TParent, TChild> relation,
  MssqlSession session,
  MssqlDialect dialect,
) {
  for (final nested in relation.nested) {
    query = query.whereExists(
      relationExistsQuery(
        nested,
        parent: relation.targetBinding,
        session: session,
        dialect: dialect,
      ),
    );
  }
  return query;
}

/// One correlated aggregate to project beside the parent row.
///
/// Each spec compiles to its own scalar subquery. Two to-many paths
/// therefore cannot share a join that would make one count a product of
/// the other.
@immutable
class MssqlRelationAggregate<TParent> {
  /// [expression] is typically `COUNT_BIG(*)` or `SUM(column)`.
  ///
  /// Prefer [MssqlRelationAggregate.of] so a typed relation handle does
  /// not have to be erased at the call site.
  MssqlRelationAggregate({
    required this.relation,
    required this.alias,
    required this.expression,
  }) {
    if (alias.trim().isEmpty) {
      throw ArgumentError.value(
        alias,
        'alias',
        'A relation aggregate needs a result-set name.',
      );
    }
  }

  /// Typed handle → erased child, for mixed aggregate lists.
  static MssqlRelationAggregate<TParent> of<TParent, TChild>({
    required MssqlRelation<TParent, TChild> relation,
    required String alias,
    required MssqlExpression expression,
  }) => MssqlRelationAggregate<TParent>(
    relation: relation.asInclude,
    alias: alias,
    expression: expression,
  );

  /// The same handle `include` / `whereHas` would use.
  final MssqlRelation<TParent, Object?> relation;

  /// Result-set column name.
  final String alias;

  /// Aggregate expression evaluated in the correlated subquery.
  final MssqlExpression expression;
}
