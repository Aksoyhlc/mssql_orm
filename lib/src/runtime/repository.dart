import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../dml.dart';
import '../expression.dart';
import '../operators.dart';
import '../predicates.dart';
import '../query.dart';
import '../statement.dart';
import 'binding.dart';
import 'capability_cache.dart';
import 'concurrency.dart';
import 'exception.dart';
import 'page.dart';
import 'query_context.dart';
import 'relation.dart';
import 'relation_loader.dart';
import 'retry.dart';
import 'scope.dart';
import 'watch.dart';
import 'write_commands.dart';

/// Reads and writes a table described by [MssqlTableBinding].
///
/// [TKey] is a scalar key, generated composite key, or `Never` for keyless
/// tables.
class MssqlRepository<TRow, TKey> {
  MssqlRepository(
    this.session, {
    required MssqlTableBinding<TRow> binding,
    String? schema,
    String? table,
    this.dialect,
    this.scope = const MssqlScopeSelection.empty(),
    this.clock = MssqlClock.serverUtc,
    this.changes,
    this.capabilities,
    this.options = MssqlQueryOptions.defaults,
  }) : binding = binding.forTable(schema: schema, table: table),
       _keyValues = _defaultKeyValues<TKey>(binding);

  /// A repository over a table with a composite key needs to know how to take
  /// that key apart, which only generated code can say.
  MssqlRepository.withKeyValues(
    this.session, {
    required MssqlTableBinding<TRow> binding,
    required Map<String, Object?> Function(TKey key) keyValues,
    String? schema,
    String? table,
    this.dialect,
    this.scope = const MssqlScopeSelection.empty(),
    this.clock = MssqlClock.serverUtc,
    this.changes,
    this.capabilities,
    this.options = MssqlQueryOptions.defaults,
  }) : binding = binding.forTable(schema: schema, table: table),
       _keyValues = keyValues;

  final MssqlSession session;
  final MssqlTableBinding<TRow> binding;

  /// Null means "ask the server once, then remember".
  final MssqlDialect? dialect;

  /// Immutable selection of soft-delete and global scopes.
  final MssqlScopeSelection scope;

  /// Which server clock timestamp columns use.
  final MssqlClock clock;

  /// Committed-write hub, or null when this repository is not from an
  /// AppDatabase.
  final MssqlChangeHub? changes;

  /// Shared dialect cache. Null uses [MssqlCapabilityCache.shared].
  final MssqlCapabilityCache? capabilities;

  /// Execution settings propagated to reads and relation includes.
  final MssqlQueryOptions options;

  final Map<String, Object?> Function(TKey key) _keyValues;

  bool _checkedDecimal = false;

  /// Resolves engine capabilities and database compatibility once per session.
  ///
  /// Both values matter because a newer engine can host a database at an older
  /// compatibility level.
  Future<MssqlDialect> _dialect() async {
    if (dialect != null) return dialect!;
    return (capabilities ?? MssqlCapabilityCache.shared).resolve(session);
  }

  /// Verifies generated decimal fields match the connection's decoding mode.
  void _checkDecimalAgreement() {
    if (_checkedDecimal) return;
    final hasExactNumeric = binding.columns.any(
      (c) => const <MssqlType>{
        MssqlType.decimal,
        MssqlType.numeric,
        MssqlType.money,
        MssqlType.smallMoney,
      }.contains(c.type),
    );
    if (hasExactNumeric && binding.decimalMode != session.config.decimalMode) {
      throw MssqlBindingMismatchException(
        '${binding.qualifiedName} was generated for '
        'MssqlDecimalMode.${binding.decimalMode.name}, but the connection '
        'uses MssqlDecimalMode.${session.config.decimalMode.name}. Its '
        'DECIMAL and MONEY columns would arrive as '
        '${_decimalDartType(session.config.decimalMode)} where the generated '
        'row expects ${_decimalDartType(binding.decimalMode)}. Match the '
        'connection configuration, or regenerate for the other mode.',
      );
    }
    _checkedDecimal = true;
  }

  static String _decimalDartType(MssqlDecimalMode mode) => switch (mode) {
    MssqlDecimalMode.exact => 'MssqlDecimal',
    MssqlDecimalMode.text => 'String',
    MssqlDecimalMode.doublePrecision => 'double',
  };

  void _requireKey(String method) {
    if (!binding.hasPrimaryKey) {
      throw StateError(
        '$method needs a primary key and ${binding.qualifiedName} has none. '
        'Targeting a single row of a keyless table is not defined; query it '
        'with findWhere instead.',
      );
    }
  }

  MssqlCondition _keyCondition(TKey key) {
    final values = _keyValues(key);
    final terms = <MssqlCondition>[];
    for (final name in binding.primaryKey) {
      if (!values.containsKey(name)) {
        throw ArgumentError.value(
          key,
          'key',
          'Does not carry a value for key column "$name".',
        );
      }
      final column = binding.column(name)!;
      terms.add(Col(name).eq(column.bind(values[name])));
    }
    return and(terms);
  }

  /// Returns a repository that also sees soft-deleted rows.
  MssqlRepository<TRow, TKey> withTrashed() => _withScope(scope.withTrashed());

  /// Only soft-deleted rows.
  MssqlRepository<TRow, TKey> onlyTrashed() => _withScope(scope.onlyTrashed());

  /// Back to the default: deleted rows hidden.
  MssqlRepository<TRow, TKey> withoutTrashed() =>
      _withScope(scope.withoutTrashed());

  /// Switches a global scope off by name.
  MssqlRepository<TRow, TKey> withoutScope(String name) =>
      _withScope(scope.withoutScope(name));

  /// Switches every global scope off without changing soft-delete visibility.
  MssqlRepository<TRow, TKey> withoutGlobalScopes() =>
      _withScope(scope.withoutGlobalScopes(binding.scopes));

  MssqlRepository<TRow, TKey> _withScope(MssqlScopeSelection next) =>
      MssqlRepository<TRow, TKey>.withKeyValues(
        session,
        binding: binding,
        keyValues: _keyValues,
        dialect: dialect,
        scope: next,
        clock: clock,
        changes: changes,
        capabilities: capabilities,
        options: options,
      );

  /// Scope snapshot shared by all statements in this repository operation.
  late final MssqlScopeCompiler _scopes = MssqlScopeCompiler(binding, scope);

  /// Every predicate that applies to a read: the soft-delete filter and the
  /// scopes that are still on.
  List<MssqlCondition> get _scopeConditions => _scopes.readConditions;

  List<MssqlCondition> get _globalScopeConditions => _scopes.globalConditions;

  MssqlQuery get _base {
    var query = MssqlQuery.fromParts(
      binding.nameParts,
      ref: binding.sourceRef,
    ).select(binding.columns.map<MssqlExpression>((c) => Col(c.name)).toList());
    for (final condition in _scopeConditions) {
      query = query.where(condition);
    }
    return query;
  }

  Future<List<TRow>> _run(
    MssqlQuery query, {
    List<MssqlRelation<TRow, Object?>> include = const [],
  }) async {
    _checkDecimalAgreement();
    final dialect = await _dialect();
    final loader = include.isEmpty ? null : _loader(dialect);
    loader?.snapshotScopes(include);
    final statement = query.compile(dialect: dialect);
    final rows = await session.queryTypedRows(
      statement.sql,
      parameters: statement.parameters,
      options: options,
      timeout: options.timeout,
      cancellationToken: options.cancellationToken,
      // Compiled reads are retryable unless raw SQL changes classification.
      retry: statement.readRetry,
    );
    final parents = rows.map(binding.fromRow).toList(growable: false);
    if (include.isEmpty) return parents;
    return loader!.attach(binding, parents, include, onWarning: warnings.add);
  }

  /// Creates a relation loader using this operation's scope snapshot.
  MssqlRelationLoader _loader(MssqlDialect dialect) =>
      MssqlRelationLoader(session, dialect: dialect, options: options);

  /// Non-fatal warnings raised while loading relations.
  final List<String> warnings = <String>[];

  // Reading

  /// The row with this key, or null.
  Future<TRow?> findById(
    TKey key, {
    List<MssqlRelation<TRow, Object?>> include = const [],
  }) async {
    _requireKey('findById');
    final rows = await _run(_base.where(_keyCondition(key)), include: include);
    return rows.isEmpty ? null : rows.first;
  }

  /// The row with this key, or throws [MssqlRowNotFoundException].
  Future<TRow> getById(
    TKey key, {
    List<MssqlRelation<TRow, Object?>> include = const [],
  }) async {
    final row = await findById(key, include: include);
    if (row == null) {
      throw MssqlRowNotFoundException(binding.qualifiedName, key);
    }
    return row;
  }

  Future<bool> exists(TKey key) {
    _requireKey('exists');
    return existsWhere(_keyCondition(key));
  }

  /// Whether any scoped row matches [where], using `SELECT TOP 1`.
  Future<bool> existsWhere(MssqlCondition where) async {
    _checkDecimalAgreement();
    var query = MssqlQuery.fromParts(binding.nameParts, ref: binding.sourceRef);
    for (final condition in _scopeConditions) {
      query = query.where(condition);
    }
    final statement = query
        .where(where)
        .top(1)
        .select(<MssqlExpression>[const MssqlProbeLiteral()])
        .compile(dialect: await _dialect());
    final rows = await session.queryTypedRows(
      statement.sql,
      parameters: statement.parameters,
      options: options,
      timeout: options.timeout,
      cancellationToken: options.cancellationToken,
      // Compiled reads are retryable unless raw SQL changes classification.
      retry: statement.readRetry,
    );
    return rows.isNotEmpty;
  }

  Future<List<TRow>> findWhere(
    MssqlCondition where, {
    List<MssqlOrder> orderBy = const <MssqlOrder>[],
    List<MssqlRelation<TRow, Object?>> include = const [],
  }) {
    var query = _base.where(where);
    if (orderBy.isNotEmpty) query = query.orderBy(orderBy);
    return _run(query, include: include);
  }

  Future<List<TRow>> findAll({
    List<MssqlOrder> orderBy = const <MssqlOrder>[],
    List<MssqlRelation<TRow, Object?>> include = const [],
  }) {
    var query = _base;
    if (orderBy.isNotEmpty) query = query.orderBy(orderBy);
    return _run(query, include: include);
  }

  Future<int> count([MssqlCondition? where]) => _count(where);

  Future<int> _count(MssqlCondition? where) async {
    _checkDecimalAgreement();
    var query = MssqlQuery.fromParts(binding.nameParts, ref: binding.sourceRef);
    // The same scopes as a read, or a page's total would count rows the page
    // itself cannot return.
    for (final condition in _scopeConditions) {
      query = query.where(condition);
    }
    if (where != null) query = query.where(where);
    final statement = query.countRows().compile(dialect: await _dialect());
    final rows = await session.queryTypedRows(
      statement.sql,
      parameters: statement.parameters,
      options: options,
      timeout: options.timeout,
      cancellationToken: options.cancellationToken,
      // A SELECT this class compiled from its own AST is safe to repeat, so
      // a dropped connection is recovered by the driver instead of
      // surfacing here. A user predicate carrying `raw(...)` takes the
      // classification back to never — see MssqlStatementRetry.
      retry: statement.readRetry,
    );
    if (rows.isEmpty) return 0;
    return (rows.first.at(0)! as num).toInt();
  }

  /// One page, and whether another follows.
  ///
  /// One row beyond the page is fetched and discarded, which answers
  /// [MssqlPage.hasMore] without a `COUNT(*)`. The count runs only when
  /// [includeTotal] asks for it.
  Future<MssqlPage<TRow>> page({
    required int rows,
    int offset = 0,
    required List<MssqlOrder> orderBy,
    MssqlCondition? where,
    bool includeTotal = false,
    List<MssqlRelation<TRow, Object?>> include = const [],
  }) async {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'Cannot be negative.');
    }
    if (rows <= 0) {
      throw ArgumentError.value(rows, 'rows', 'Must be positive.');
    }
    if (orderBy.isEmpty) {
      throw ArgumentError.value(
        orderBy,
        'orderBy',
        'A page needs an ordering: SQL Server rejects OFFSET without ORDER BY, '
            'and an unordered page is not repeatable between calls.',
      );
    }
    var query = _base;
    if (where != null) query = query.where(where);
    query = query.orderBy(orderBy).paged(offset: offset, rows: rows + 1);

    // Include after dropping the sentinel: loading relations for a parent
    // that is not on the page is wasted work and would attach children to a
    // row the caller never sees.
    final loader = include.isEmpty ? null : _loader(await _dialect());
    loader?.snapshotScopes(include);
    final fetched = await _run(query);
    final hasMore = fetched.length > rows;
    final slice = hasMore ? fetched.sublist(0, rows) : fetched;
    final parents = include.isEmpty
        ? slice
        : await loader!.attach(
            binding,
            slice,
            include,
            onWarning: warnings.add,
          );

    return MssqlPage<TRow>(
      rows: parents,
      offset: offset,
      requestedRows: rows,
      hasMore: hasMore,
      total: includeTotal ? await _count(where) : null,
    );
  }

  // Writing

  /// The write engine for this repository, bound to the resolved dialect.
  ///
  /// Built per call rather than cached: it is immutable and holds nothing but
  /// three references, and caching it would mean invalidating it whenever the
  /// repository is pointed somewhere else.
  Future<MssqlWriteEngine<TRow>> _engine() async => MssqlWriteEngine<TRow>(
    session,
    binding: binding,
    dialect: await _dialect(),
    changes: changes,
  );

  MssqlWriteAssignments _writableValues(
    TRow row, {
    Set<String>? only,
    bool excludeKey = false,
  }) {
    final source = binding.toColumns(row);
    final values = <String, MssqlWriteValue>{};
    for (final column in binding.writableColumns) {
      final lower = column.name.toLowerCase();
      // An UPDATE's WHERE clause targets the key, so its SET must not carry
      // it: writing it back is a no-op at best, and at worst renames the key
      // of the row the WHERE just selected. An INSERT is the opposite case —
      // a natural, non-identity key has to be written — so this is asked for
      // rather than always applied.
      if (excludeKey &&
          binding.primaryKey.any((k) => k.toLowerCase() == lower)) {
        continue;
      }
      if (only != null && !only.any((n) => n.toLowerCase() == lower)) continue;
      // Absent from the row map means absent from the statement, which is not
      // the same as null: an omitted column keeps its value, or takes its
      // default on insert.
      if (!source.containsKey(column.name)) continue;
      values[column.name] = MssqlBoundValue(column.bind(source[column.name]));
    }
    return MssqlWriteAssignments(values);
  }

  void _checkColumnSubset(Set<String> columns) {
    if (columns.isEmpty) {
      throw ArgumentError.value(
        columns,
        'columns',
        'An empty column set would write nothing. Omit the argument to write '
            'every writable column.',
      );
    }
    for (final name in columns) {
      final column = binding.column(name);
      if (column == null) {
        throw ArgumentError.value(
          name,
          'columns',
          'Names a column ${binding.qualifiedName} does not have.',
        );
      }
      if (binding.primaryKey.any(
        (k) => k.toLowerCase() == name.toLowerCase(),
      )) {
        throw ArgumentError.value(
          name,
          'columns',
          'Is part of the primary key. update() addresses a row by its key, '
              'and updateWhere() would rewrite the identity of every row it '
              'matches; neither is something to do by accident.',
        );
      }
      if (!column.writable) {
        throw ArgumentError.value(
          name,
          'columns',
          column.isReadOnly
              ? 'Is marked read-only by the generator configuration.'
              : 'Is written by the server (identity, computed or rowversion).',
        );
      }
    }
  }

  /// Inserts [row] and applies the table's configured readback strategy.
  ///
  /// Rows with only server-generated columns use `DEFAULT VALUES`.
  Future<TRow> insert(TRow row) async {
    _checkDecimalAgreement();
    final values = _stampInsert(_writableValues(row));
    final engine = await _engine();
    final readback = engine.insertReadback;
    final outcome = await engine.insertRow(values);

    switch (readback) {
      case MssqlWriteReadback.storedRow:
      case MssqlWriteReadback.keyCapture:
        if (outcome.rows.isEmpty) {
          throw StateError(
            'INSERT into ${binding.qualifiedName} stored a row but reported '
            'none back. A trigger or an updatable view that discards the row '
            'is the usual cause; declare a readback strategy that matches it.',
          );
        }
        return binding.fromRow(outcome.rows.first);

      case MssqlWriteReadback.identityOnly:
        if (outcome.rows.isEmpty) return row;
        final apply = binding.applyIdentity;
        if (apply == null) {
          throw StateError(
            '${binding.qualifiedName} reads its key back through '
            'SCOPE_IDENTITY() but its binding carries no applyIdentity, so '
            'the generated key cannot be put back into the row. Regenerate '
            'the table.',
          );
        }
        return apply(row, outcome.rows.first.at(0));

      case MssqlWriteReadback.none:
        return row;
    }
  }

  /// Inserts [values] and returns the stored row, including defaults.
  ///
  /// The query-layer `create(OrderCreate)` is the usual call. This is the
  /// assignment form the generated method compiles into.
  Future<TRow> insertAssignments(MssqlWriteAssignments values) async {
    _checkDecimalAgreement();
    final stamped = _stampInsert(values);
    final engine = await _engine();
    final readback = engine.insertReadback;
    final outcome = await engine.insertRow(stamped);
    switch (readback) {
      case MssqlWriteReadback.storedRow:
      case MssqlWriteReadback.keyCapture:
        if (outcome.rows.isEmpty) {
          throw StateError(
            'INSERT into ${binding.qualifiedName} stored a row but reported '
            'none back. A trigger or an updatable view that discards the row '
            'is the usual cause; declare a readback strategy that matches it.',
          );
        }
        return binding.fromRow(outcome.rows.first);
      case MssqlWriteReadback.identityOnly:
        if (outcome.rows.isEmpty) {
          throw MssqlReadbackUnavailableException(
            table: binding.qualifiedName,
            operation: 'insert',
            reason: 'SCOPE_IDENTITY() returned no value',
          );
        }
        final identity = binding.column(binding.identityColumn!)!;
        final id = outcome.rows.first.at(0);
        final found = await session.queryTypedRows(
          'SELECT * FROM ${binding.quoted} WHERE '
          '${MssqlSql.quoteIdentifier(identity.name)} = @id',
          parameters: <String, Object?>{'id': identity.bind(id)},
        );
        if (found.isEmpty) {
          throw StateError(
            'INSERT into ${binding.qualifiedName} inserted identity $id '
            'but could not read the stored row back.',
          );
        }
        return binding.fromRow(found.first);
      case MssqlWriteReadback.none:
        throw MssqlReadbackUnavailableException(
          table: binding.qualifiedName,
          operation: 'insert',
          reason:
              'the table has no identity readback, so a Create cannot be '
              'turned into a stored row. Insert a full row, or add a key.',
        );
    }
  }

  /// Inserts rows in batches within SQL Server's row and parameter limits.
  Future<void> insertAll(List<TRow> rows) async {
    if (rows.isEmpty) return;
    _checkDecimalAgreement();
    final resolved = await _dialect();
    final writable = binding.writableColumns;
    if (writable.isEmpty) {
      throw StateError(
        'Inserting into ${binding.qualifiedName} would write no columns.',
      );
    }
    // 2100 is the server's ceiling; 2000 leaves room and keeps the arithmetic
    // obvious. 1000 is the VALUES row limit.
    final perStatement = (2000 ~/ writable.length).clamp(1, 1000);
    for (var start = 0; start < rows.length; start += perStatement) {
      final end = (start + perStatement).clamp(0, rows.length);
      await _insertBatch(rows.sublist(start, end), writable, resolved);
    }
  }

  Future<void> _insertBatch(
    List<TRow> rows,
    List<MssqlBoundColumn> writable,
    MssqlDialect resolved,
  ) async {
    final names = writable
        .map((c) => MssqlSql.quoteIdentifier(c.name))
        .join(', ');
    final parameters = MssqlParameterAllocator();
    final tuples = <String>[];
    for (final row in rows) {
      final source = _stampInsert(_writableValues(row));
      final bound = <String>[];
      for (final column in writable) {
        // Omitted tuple values use DEFAULT; null would overwrite the default.
        bound.add(switch (source[column.name]) {
          null => 'DEFAULT',
          MssqlBoundValue(:final value) => parameters.bind(value),
          MssqlServerValue(:final expression) => expression.compile(
            parameters,
            resolved,
          ),
          MssqlDefaultValue() => 'DEFAULT',
        });
      }
      tuples.add('(${bound.join(', ')})');
    }
    await session.execute(
      'INSERT INTO ${binding.quoted} ($names) VALUES ${tuples.join(', ')}',
      parameters: parameters.values,
    );
  }

  /// Updates the identified row, optionally limited to [columns].
  ///
  /// Without [columns], every writable field is sent; rows do not track
  /// changes locally.
  Future<int> update(TRow row, {Set<String>? columns}) async {
    _requireKey('update');
    _checkDecimalAgreement();
    if (columns != null) _checkColumnSubset(columns);

    final source = binding.toColumns(row);
    for (final name in binding.primaryKey) {
      if (!source.containsKey(name)) {
        throw ArgumentError.value(
          row,
          'row',
          'Carries no value for key column "$name".',
        );
      }
    }

    final values = _stampUpdate(
      _writableValues(row, only: columns, excludeKey: true),
    );
    if (values.isEmpty) {
      throw StateError(
        'Updating ${binding.qualifiedName} would write no columns.',
      );
    }

    final outcome = await _updateKeyed(row, values);
    return outcome.affectedRows;
  }

  /// Applies [patch], optionally guarded by the last-read [expectedVersion].
  ///
  /// A guarded write matching no rows throws [MssqlConcurrencyException]. The
  /// argument is rejected when the table has no rowversion column.
  Future<TRow> updatePatch(
    TKey key,
    MssqlWriteAssignments patch, {
    Object? expectedVersion,
  }) async {
    _requireKey('updatePatch');
    _checkDecimalAgreement();
    final values = _stampUpdate(patch);
    if (values.isEmpty) {
      throw StateError(
        'Updating ${binding.qualifiedName} would write no columns.',
      );
    }
    final where = <MssqlCondition>[_keyCondition(key)];
    final version = expectedVersion;
    if (version != null) {
      final rv = binding.rowVersionColumn;
      if (rv == null) {
        throw StateError(
          '${binding.qualifiedName} has no rowversion column, so '
          'expectedVersion cannot guard the write. Use update() for an '
          'unguarded full-row write.',
        );
      }
      where.add(Col(rv.name).eq(rv.bind(version)));
    }
    final engine = await _engine();
    final outcome = await engine.updateWhere(
      operation: 'updatePatch',
      values: values,
      where: where,
      scopes: _scopeConditions,
      readRows: true,
    );
    if (version != null && outcome.affectedRows == 0) {
      throw MssqlConcurrencyException(
        table: binding.qualifiedName,
        operation: 'updatePatch',
        key: key,
      );
    }
    if (outcome.rows.isNotEmpty) {
      return binding.fromRow(outcome.rows.first);
    }
    final row = await findById(key);
    if (row != null) return row;
    throw MssqlRowNotFoundException(binding.qualifiedName, key);
  }

  /// Writes [patch] to every row matching [where].
  ///
  /// [expectedVersion] adds the rowversion token to the WHERE. Zero rows
  /// with a token is [MssqlConcurrencyException]. [expectAffected] runs
  /// the write through [MssqlWriteEngine.guard].
  Future<int> updateMatching(
    List<MssqlCondition> where,
    MssqlWriteAssignments patch, {
    Object? expectedVersion,
    int? expectAffected,
  }) async {
    _checkDecimalAgreement();
    if (where.isEmpty) {
      throw MssqlUnsafeWriteException(binding.qualifiedName, 'update');
    }
    final values = _stampUpdate(patch);
    if (values.isEmpty) {
      throw StateError(
        'Updating ${binding.qualifiedName} would write no columns.',
      );
    }
    final filters = <MssqlCondition>[...where];
    final version = expectedVersion;
    if (version != null) {
      final rv = binding.rowVersionColumn;
      if (rv == null) {
        throw StateError(
          '${binding.qualifiedName} has no rowversion column, so '
          'expectedVersion cannot guard the write.',
        );
      }
      filters.add(Col(rv.name).eq(rv.bind(version)));
    }
    final engine = await _engine();
    Future<MssqlWriteOutcome> write(MssqlWriteEngine<TRow> e) => e.updateWhere(
      operation: 'update',
      values: values,
      where: filters,
      scopes: _scopeConditions,
    );
    final outcome = expectAffected == null
        ? await write(engine)
        : await engine.guard(
            operation: 'update',
            expected: expectAffected,
            write: write,
          );
    if (version != null && outcome.affectedRows == 0) {
      throw MssqlConcurrencyException(
        table: binding.qualifiedName,
        operation: 'update',
      );
    }
    return outcome.affectedRows;
  }

  /// The keyed update both [update] and [updateOne] run.
  Future<MssqlWriteOutcome> _updateKeyed(
    TRow row,
    MssqlWriteAssignments values, {
    MssqlWriteEngine<TRow>? engine,
  }) async {
    final source = binding.toColumns(row);
    final resolved = engine ?? await _engine();
    return resolved.updateWhere(
      operation: 'update',
      values: values,
      where: <MssqlCondition>[
        for (final name in binding.primaryKey)
          Col(name).eq(binding.column(name)!.bind(source[name])),
      ],
      scopes: _scopeConditions,
    );
  }

  /// Writes [values] to every row matching [where], and returns how many
  /// changed.
  ///
  /// The counterpart to [deleteWhere], and it exists for the same reason that
  /// one does. Dropping to [MssqlUpdate] to write a set of rows works, but it
  /// leaves the repository's two obligations behind: the updated-at column is
  /// not stamped, and the scopes are not applied — so a soft-deleting table
  /// would have its trashed rows quietly updated along with the live ones.
  ///
  /// [values] are column names to values, bound through the binding, so a null
  /// is typed and a converter is applied. An expression passes through as SQL:
  /// `{'Hits': MssqlArithmetic(Col('Hits'), MssqlArithmeticOperator.add, 1)}`
  /// compiles to
  /// `[Hits] = [Hits] + @p0`.
  Future<int> updateWhere(
    MssqlCondition where,
    Map<String, Object?> values,
  ) async {
    _checkDecimalAgreement();
    if (values.isEmpty) {
      throw ArgumentError.value(
        values,
        'values',
        'Updating ${binding.qualifiedName} would write no columns.',
      );
    }
    _checkColumnSubset(values.keys.toSet());

    final bound = _stampUpdate(
      MssqlWriteAssignments(<String, MssqlWriteValue>{
        for (final entry in values.entries)
          // An expression is SQL the caller wrote; only a plain value is
          // bound through the column's own codec.
          entry.key: entry.value is MssqlExpression
              ? MssqlServerValue(entry.value! as MssqlExpression)
              : MssqlBoundValue(binding.column(entry.key)!.bind(entry.value)),
      }),
    );

    final engine = await _engine();
    final outcome = await engine.updateWhere(
      operation: 'updateWhere',
      values: bound,
      where: <MssqlCondition>[where],
      scopes: _scopeConditions,
    );
    return outcome.affectedRows;
  }

  /// [update], but insisting that exactly one row changed.
  ///
  /// The write runs inside a transaction, so a count that turns out wrong
  /// leaves nothing behind.
  ///
  /// The three outcomes get three different exceptions, because they mean
  /// three different things to whoever has to fix them:
  ///
  /// * No row — [MssqlRowNotFoundException]. The write targets one row by
  ///   its primary key, so zero means that row is not there, or a scope
  ///   hides it; the same conclusion `getById` reports.
  /// * More than one row — [StateError] naming the key. A primary key cannot
  ///   match twice, so this says the declared key does not identify a row:
  ///   a schema or binding problem, not a data one. Reporting it as an
  ///   affected-row count would point at the wrong thing.
  /// * Exactly one — the write stands.
  ///
  /// Either failure rolls the write back before the exception leaves.
  Future<void> updateOne(TRow row, {Set<String>? columns}) async {
    _requireKey('updateOne');
    _checkDecimalAgreement();
    if (columns != null) _checkColumnSubset(columns);
    final values = _stampUpdate(
      _writableValues(row, only: columns, excludeKey: true),
    );
    if (values.isEmpty) {
      throw StateError(
        'Updating ${binding.qualifiedName} would write no columns.',
      );
    }
    final engine = await _engine();
    try {
      await engine.guard(
        operation: 'updateOne',
        expected: 1,
        write: (scoped) => _updateKeyed(row, values, engine: scoped),
      );
    } on MssqlAffectedRowsException catch (error) {
      final source = binding.toColumns(row);
      final key = <String, Object?>{
        for (final name in binding.primaryKey) name: source[name],
      };
      if (error.actual == 0) {
        throw MssqlRowNotFoundException(binding.qualifiedName, key);
      }
      throw StateError(
        'updateOne on ${binding.qualifiedName} changed ${error.actual} rows '
        'for key $key, so the declared primary key '
        '(${binding.primaryKey.join(', ')}) does not identify a single row '
        'in this table. That is a schema or a binding problem rather than a '
        'data one, which is why it is not reported as an affected-row count. '
        'The write was rolled back.',
      );
    }
  }

  /// Deletes the row with this key.
  ///
  /// A soft-deleting table writes its deleted-at column instead. [forceDelete]
  /// removes the row for real, and is named rather than implied so a caller
  /// does not erase a row while believing they hid it.
  Future<int> delete(TKey key) async {
    _requireKey('delete');
    final soft = binding.softDelete;
    if (soft != null) {
      return _softDelete(_keyCondition(key), soft);
    }
    final engine = await _engine();
    final outcome = await engine.deleteWhere(
      operation: 'delete',
      where: <MssqlCondition>[_keyCondition(key)],
      scopes: _scopeConditions,
    );
    return outcome.affectedRows;
  }

  Future<int> deleteWhere(MssqlCondition where) async {
    final soft = binding.softDelete;
    if (soft != null) return _softDelete(where, soft);
    final engine = await _engine();
    final outcome = await engine.deleteWhere(
      operation: 'deleteWhere',
      where: <MssqlCondition>[where],
      scopes: _scopeConditions,
    );
    return outcome.affectedRows;
  }

  /// Removes the row from the table, soft deletes or not.
  Future<int> forceDelete(TKey key) async {
    _requireKey('forceDelete');
    final engine = await _engine();
    // A force delete must be able to remove a row that is already trashed.
    // Tenant and other global scopes still constrain it; only the implicit
    // alive-row predicate is omitted.
    final outcome = await engine.deleteWhere(
      operation: 'forceDelete',
      where: <MssqlCondition>[_keyCondition(key)],
      scopes: _globalScopeConditions,
    );
    return outcome.affectedRows;
  }

  /// Clears the deleted-at column, bringing a soft-deleted row back.
  Future<int> restore(TKey key) async {
    _requireKey('restore');
    final soft = binding.softDelete;
    if (soft == null) {
      throw StateError(
        '${binding.qualifiedName} does not soft-delete, so there is nothing '
        'to restore.',
      );
    }
    final column = binding.column(soft.column)!;
    final values = _stampUpdate(
      MssqlWriteAssignments(<String, MssqlWriteValue>{
        soft.column: MssqlBoundValue(
          soft.aliveValue == null
              ? column.nullValue
              : column.bind(soft.aliveValue),
        ),
      }),
    );
    final engine = await _engine();
    final outcome = await engine.updateWhere(
      operation: 'restore',
      values: values,
      where: <MssqlCondition>[_keyCondition(key), soft.deleted],
      scopes: _globalScopeConditions,
    );
    return outcome.affectedRows;
  }

  Future<int> _softDelete(MssqlCondition where, MssqlSoftDelete soft) async {
    final column = binding.column(soft.column);
    if (column == null) {
      throw StateError(
        '${binding.qualifiedName} declares a soft-delete column '
        '"${soft.column}" it does not have.',
      );
    }
    final value = soft.deletedValue;
    final values = _stampUpdate(
      MssqlWriteAssignments(<String, MssqlWriteValue>{
        // The server's clock, not the application's: a deleted-at stamp is
        // compared against other server timestamps, and two clocks make that
        // comparison meaningless.
        soft.column: value == null
            ? MssqlServerValue(clock.expression)
            : MssqlBoundValue(column.bind(value)),
      }),
    );
    final engine = await _engine();
    final outcome = await engine.updateWhere(
      operation: 'delete',
      values: values,
      // Deleting an already-deleted row should report zero, not one.
      where: <MssqlCondition>[where, soft.alive],
      scopes: _globalScopeConditions,
    );
    return outcome.affectedRows;
  }

  /// The first row matching [where], or null.
  Future<TRow?> firstWhere(
    MssqlCondition where, {
    List<MssqlOrder> orderBy = const <MssqlOrder>[],
  }) async {
    var query = _base.where(where);
    if (orderBy.isNotEmpty) query = query.orderBy(orderBy);
    final rows = await _run(query.top(1));
    return rows.isEmpty ? null : rows.first;
  }

  /// Returns the first match or inserts [build]'s row.
  ///
  /// This two-round-trip operation needs a unique index or transaction when
  /// concurrent inserts must not race.
  Future<TRow> firstOrCreate(
    MssqlCondition where,
    TRow Function() build,
  ) async {
    final existing = await firstWhere(where);
    if (existing != null) return existing;
    return insert(build());
  }

  /// Tries the insert first, then reads the winner after error 2601 or 2627.
  ///
  /// The conflicting unique index cannot be identified reliably; prefer
  /// [getOrCreate] when the expected index is known.
  Future<TRow> createOrFirst(
    MssqlCondition where,
    TRow Function() build,
  ) async {
    try {
      return await insert(build());
    } on MssqlException catch (error) {
      if (error.code != 2601 && error.code != 2627) rethrow;
      if (sessionIsDoomed(session)) {
        throw MssqlUniqueConflictException(
          table: binding.qualifiedName,
          indexName: duplicateKeyName(error.message) ?? '(unknown)',
          reason:
              'the insert collided and the transaction is doomed, so the '
              'winning row cannot be read back. Roll it back and retry.',
        );
      }
      final existing = await firstWhere(where);
      if (existing != null) return existing;
      rethrow;
    }
  }

  /// Inserts [create], or returns the row already owning [key].
  ///
  /// Only conflicts from [MssqlUniqueMatch.indexName] are recovered. Deleted
  /// matches follow [restoreExisting] and [includeDeleted].
  Future<TRow> getOrCreate({
    required MssqlUniqueMatch key,
    required MssqlWriteAssignments create,
    bool restoreExisting = false,
    bool includeDeleted = false,
  }) async {
    _checkDecimalAgreement();
    var values = create;
    for (final entry in key.values.entries) {
      final column = binding.column(entry.key);
      if (column == null) {
        throw ArgumentError.value(
          entry.key,
          'key',
          '${binding.qualifiedName} has no column "${entry.key}".',
        );
      }
      final bound = MssqlBoundValue(column.bind(entry.value));
      final existing = values[entry.key];
      if (existing is MssqlBoundValue &&
          existing.value.value != bound.value.value) {
        throw ArgumentError.value(
          entry.value,
          'create',
          'getOrCreate unique "${key.indexName}" is ${entry.key}='
              '${entry.value}, but create sets it to ${existing.value.value}.',
        );
      }
      values = values.withValue(column.name, bound);
    }
    try {
      return await _insertAssignments(values, key);
    } on MssqlException catch (error) {
      if (!duplicateKeyIs(error, key.indexName)) rethrow;
      if (sessionIsDoomed(session)) {
        throw MssqlUniqueConflictException(
          table: binding.qualifiedName,
          indexName: key.indexName,
          reason:
              'the insert collided and the transaction is doomed, so the '
              'winning row cannot be read back. Roll it back and retry.',
        );
      }
      return _readUniqueWinner(
        key,
        restoreExisting: restoreExisting,
        includeDeleted: includeDeleted,
      );
    }
  }

  Future<TRow> _readUniqueWinner(
    MssqlUniqueMatch key, {
    required bool restoreExisting,
    required bool includeDeleted,
  }) async {
    final predicate = _uniquePredicate(key);
    final live = await firstWhere(predicate);
    if (live != null) return live;
    final any = await withTrashed().firstWhere(predicate);
    if (any == null) {
      throw MssqlUniqueConflictException(
        table: binding.qualifiedName,
        indexName: key.indexName,
        reason:
            'SQL Server reported a duplicate on this key but no matching '
            'row is visible under the current tenant scopes.',
      );
    }
    if (includeDeleted) return any;
    if (restoreExisting) {
      final soft = binding.softDelete;
      if (soft == null) return any;
      final column = binding.column(soft.column)!;
      final engine = await _engine();
      await engine.updateWhere(
        operation: 'restoreExisting',
        values: _stampUpdate(
          MssqlWriteAssignments(<String, MssqlWriteValue>{
            soft.column: MssqlBoundValue(
              soft.aliveValue == null
                  ? column.nullValue
                  : column.bind(soft.aliveValue),
            ),
          }),
        ),
        where: <MssqlCondition>[predicate, soft.deleted],
        scopes: _globalScopeConditions,
      );
      final restored = await firstWhere(predicate);
      if (restored == null) {
        throw MssqlUniqueConflictException(
          table: binding.qualifiedName,
          indexName: key.indexName,
          reason: 'restoreExisting wrote but the live row is still hidden.',
        );
      }
      return restored;
    }
    throw MssqlUniqueConflictException(
      table: binding.qualifiedName,
      indexName: key.indexName,
      reason:
          'a soft-deleted row already owns this key. Pass restoreExisting '
          'to bring it back, or includeDeleted to return it as-is.',
    );
  }

  MssqlCondition _uniquePredicate(MssqlUniqueMatch key) {
    final parts = <MssqlCondition>[
      for (final entry in key.values.entries)
        Col(entry.key).eq(binding.column(entry.key)!.bind(entry.value)),
    ];
    return parts.length == 1 ? parts.first : and(parts);
  }

  Future<TRow> _insertAssignments(
    MssqlWriteAssignments values,
    MssqlUniqueMatch key,
  ) async {
    final stamped = _stampInsert(values);
    final engine = await _engine();
    final readback = engine.insertReadback;
    final outcome = await engine.insertRow(stamped);
    if (readback == MssqlWriteReadback.storedRow ||
        readback == MssqlWriteReadback.keyCapture) {
      if (outcome.rows.isNotEmpty) {
        return binding.fromRow(outcome.rows.first);
      }
    }
    final stored = await firstWhere(_uniquePredicate(key));
    if (stored != null) return stored;
    throw StateError(
      'INSERT into ${binding.qualifiedName} succeeded but unique '
      '"${key.indexName}" did not find the stored row under current scopes.',
    );
  }

  /// [firstOrCreate] without the insert: the row, or [build]'s unsaved one.
  Future<TRow> firstOrNew(MssqlCondition where, TRow Function() build) async =>
      await firstWhere(where) ?? build();

  /// Whether the row exists and carries the configured deleted value.
  Future<bool> trashed(TKey key) async {
    _requireKey('trashed');
    final soft = binding.softDelete;
    if (soft == null) return false;
    var query = MssqlQuery.fromParts(binding.nameParts, ref: binding.sourceRef)
        .select(<MssqlExpression>[const MssqlProbeLiteral()])
        .where(_keyCondition(key))
        .where(soft.deleted)
        .top(1);
    for (final condition in _globalScopeConditions) {
      query = query.where(condition);
    }
    final statement = query.compile(dialect: await _dialect());
    final rows = await session.queryTypedRows(
      statement.sql,
      parameters: statement.parameters,
      options: options,
      timeout: options.timeout,
      cancellationToken: options.cancellationToken,
      // A SELECT this class compiled from its own AST is safe to repeat, so
      // a dropped connection is recovered by the driver instead of
      // surfacing here. A user predicate carrying `raw(...)` takes the
      // classification back to never — see MssqlStatementRetry.
      retry: statement.readRetry,
    );
    return rows.isNotEmpty;
  }

  /// Updates the row matching [where] to [build]'s, or inserts it.
  ///
  /// The same two-round-trip caveat as [firstOrCreate].
  Future<TRow> updateOrCreate(
    MssqlCondition where,
    TRow Function(TRow? existing) build, {
    Set<String>? columns,
  }) async {
    final existing = await firstWhere(where);
    final row = build(existing);
    if (existing == null) return insert(row);
    await update(row, columns: columns);
    return row;
  }

  /// Adds [by] to a column in place, without reading it first.
  ///
  /// `SET [Hits] = [Hits] + @n` rather than read-modify-write: two callers
  /// incrementing at once both count, which a read-modify-write loses.
  Future<int> increment(TKey key, String column, {num by = 1}) =>
      _step(key, column, by);

  Future<int> decrement(TKey key, String column, {num by = 1}) =>
      _step(key, column, -by);

  Future<int> _step(TKey key, String column, num by) async {
    _requireKey('increment');
    final bound = binding.column(column);
    if (bound == null) {
      throw ArgumentError.value(
        column,
        'column',
        'Not a column of ${binding.qualifiedName}.',
      );
    }
    if (!bound.writable) {
      throw ArgumentError.value(
        column,
        'column',
        'Is written by the server or marked read-only.',
      );
    }
    final values = _stampUpdate(
      MssqlWriteAssignments(<String, MssqlWriteValue>{
        column: MssqlServerValue(
          MssqlArithmetic(
            Col(column),
            by.isNegative
                ? MssqlArithmeticOperator.subtract
                : MssqlArithmeticOperator.add,
            by.abs(),
          ),
        ),
      }),
    );
    final engine = await _engine();
    final outcome = await engine.updateWhere(
      operation: by.isNegative ? 'decrement' : 'increment',
      values: values,
      where: <MssqlCondition>[_keyCondition(key)],
      scopes: _scopeConditions,
    );
    return outcome.affectedRows;
  }

  MssqlWriteAssignments _stampInsert(MssqlWriteAssignments values) {
    var out = values;
    final stamps = binding.timestamps;
    for (final name in <String?>[stamps.createdColumn, stamps.updatedColumn]) {
      if (name == null) continue;
      // The binding already resolved the name to the schema's spelling, so
      // this lookup cannot miss on case alone.
      final column = binding.column(name);
      if (column == null || !column.writable) continue;
      // A stamp column the caller already set is left alone: importing rows
      // with their original timestamps is a legitimate thing to do. An absent
      // column and a null one are both "not set" here, because a row type
      // whose DateTime field is null is the shape a fresh row arrives in.
      final current = out[name];
      final unset =
          current == null ||
          (current is MssqlBoundValue && current.value.value == null);
      if (!unset) continue;
      out = out.withValue(name, MssqlServerValue(clock.expression));
    }
    return out;
  }

  MssqlWriteAssignments _stampUpdate(MssqlWriteAssignments values) {
    final name = binding.timestamps.updatedColumn;
    // Empty patch produces no timestamp-only side effect: if there is nothing
    // to write, there is nothing to stamp.
    if (name == null || values.isEmpty) return values;
    final column = binding.column(name);
    if (column == null || !column.writable) return values;
    return values.withValue(name, MssqlServerValue(clock.expression));
  }
}

/// A single-column key needs no help being taken apart; a composite one does,
/// and its generated repository passes a function that knows how.
Map<String, Object?> Function(TKey) _defaultKeyValues<TKey>(
  MssqlTableBinding<Object?> binding,
) {
  return (TKey key) {
    if (binding.primaryKey.length != 1) {
      throw StateError(
        '${binding.qualifiedName} has a composite primary key '
        '(${binding.primaryKey.join(', ')}). Construct the repository with '
        'MssqlRepository.withKeyValues so it can take the key apart.',
      );
    }
    return <String, Object?>{binding.primaryKey.single: key};
  };
}
