import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../expression.dart';
import '../statement.dart';
import 'binding.dart';
import 'exception.dart';
import 'query_context.dart';
import 'transaction_support.dart';
import 'watch.dart';
import 'write_commands.dart';

/// How [MssqlBulkWriter.createMany] sends rows.
///
/// Chosen by the caller. VALUES and BCP disagree about triggers, CHECKs,
/// defaults, nulls and identity readback; silently switching would hide
/// that.
enum MssqlCreateManyStrategy {
  /// Multi-row `INSERT … VALUES` / `MERGE`, batched under the 1000-row and
  /// 2100-parameter ceilings. Defaults stay `DEFAULT`; identity can come
  /// back mapped to the input order.
  ///
  /// Named `insertValues` rather than `values` because Dart enums already
  /// expose `.values`.
  insertValues,

  /// Native BCP. No OUTPUT, no `DEFAULT` keyword, trigger/CHECK behaviour
  /// from [MssqlBulkOptions]. Mapped readback is refused.
  bulkCopy,
}

/// What [MssqlBulkWriter.createMany] stored, and how well input lines up
/// with what came back.
@immutable
class MssqlCreateManyResult<TRow> {
  const MssqlCreateManyResult({
    required this.strategy,
    required this.insertedRows,
    this.rows = const [],
    this.mappedToInput = false,
    this.bulkOptions,
    this.bulkResult,
  });

  final MssqlCreateManyStrategy strategy;
  final int insertedRows;

  /// Stored rows, in input order when [mappedToInput] is true.
  ///
  /// Empty when readback was not requested or not possible. That is not
  /// "nothing was inserted" — see [insertedRows].
  final List<TRow> rows;

  /// Whether [rows][i] is the stored form of input i.
  ///
  /// False when OUTPUT order cannot be trusted and there is no ordinal to
  /// join on. Callers that need the pairing must not guess.
  final bool mappedToInput;

  /// The BCP hints that actually ran, when [strategy] is bulkCopy.
  final MssqlBulkOptions? bulkOptions;

  /// The driver's BCP summary, when [strategy] is bulkCopy.
  final MssqlBulkResult? bulkResult;
}

/// One row of a set-based update: the key that finds it, and the patch.
@immutable
class MssqlKeyedPatch {
  const MssqlKeyedPatch({required this.key, required this.patch});

  /// Column name to value. Names are matched case-insensitively to the
  /// binding. Null key values are refused: they cannot identify a row.
  final Map<String, Object?> key;
  final MssqlWriteAssignments patch;
}

/// Batched insert, keyed staging update, and quantity decrement.
///
/// Separate from [MssqlWriteEngine] because a multi-row write has a
/// different contract: VALUES vs BCP is a caller choice, OUTPUT order is
/// never trusted, and a failed batch rolls the whole call back by default.
@immutable
class MssqlBulkWriter<TRow> {
  MssqlBulkWriter(
    this.session, {
    required this.binding,
    required this.dialect,
    this.clock = MssqlClock.serverUtc,
    this.changes,
    this.scopes = const <MssqlCondition>[],
  });

  final MssqlSession session;
  final MssqlTableBinding<TRow> binding;
  final MssqlDialect dialect;
  final MssqlClock clock;
  final MssqlChangeHub? changes;

  /// The query's resolved scope predicates — tenant, soft delete, any other
  /// global scope — that every row this writer touches has to satisfy.
  ///
  /// A set-based `UPDATE … JOIN #staging` is still a filtered write: without
  /// these it would reach across tenants and into soft-deleted rows, which
  /// the single-row `update()` on the same query cannot do. Empty only for a
  /// table that declares no scopes, or a query that switched them off.
  ///
  /// Insert paths take no scope predicate: an `INSERT` has no `WHERE` to
  /// apply one to. A scope that has to be *written* onto new rows belongs in
  /// the Create values, where the caller can see it.
  final List<MssqlCondition> scopes;

  MssqlWriteEngine<TRow> get _engine => MssqlWriteEngine<TRow>(
    session,
    binding: binding,
    dialect: dialect,
    changes: changes,
  );

  /// Inserts [rows], batched under SQL Server's ceilings.
  ///
  /// [atomic] defaults true: more than one statement runs in one
  /// transaction so a later batch cannot land after an earlier one
  /// committed. A session that cannot open a transaction is refused
  /// rather than half-writing.
  Future<MssqlCreateManyResult<TRow>> createMany(
    List<MssqlWriteAssignments> rows, {
    MssqlCreateManyStrategy strategy = MssqlCreateManyStrategy.insertValues,
    MssqlBulkOptions bulk = const MssqlBulkOptions(),
    bool atomic = true,
    bool returnRows = true,
  }) async {
    if (rows.isEmpty) {
      return MssqlCreateManyResult<TRow>(
        strategy: strategy,
        insertedRows: 0,
        mappedToInput: true,
        bulkOptions: strategy == MssqlCreateManyStrategy.bulkCopy ? bulk : null,
      );
    }
    if (strategy == MssqlCreateManyStrategy.bulkCopy && returnRows) {
      throw StateError(
        'createMany(strategy: bulkCopy) cannot return stored rows: BCP '
        'has no OUTPUT, and a later SELECT cannot pair them with the '
        'input without an ordinal this path does not write. Pass '
        'returnRows: false, or use strategy: values.',
      );
    }
    final stamped = <MssqlWriteAssignments>[
      for (final row in rows) _stampInsert(row),
    ];
    Future<MssqlCreateManyResult<TRow>> run(MssqlSession s) {
      final writer = MssqlBulkWriter<TRow>(
        s,
        binding: binding,
        dialect: dialect,
        clock: clock,
        changes: changes,
        scopes: scopes,
      );
      return switch (strategy) {
        MssqlCreateManyStrategy.insertValues => writer._createManyValues(
          stamped,
          returnRows: returnRows,
        ),
        MssqlCreateManyStrategy.bulkCopy => writer._createManyBulk(
          stamped,
          bulk,
        ),
      };
    }

    final multiStatement =
        strategy == MssqlCreateManyStrategy.bulkCopy || stamped.length > 1;
    if (!atomic || !multiStatement) {
      return run(session);
    }
    return _transact(run);
  }

  /// Staging JOIN update of [patches] by their keys.
  ///
  /// Temp table + INSERT + UPDATE on this session, dropped in `finally`.
  /// [expectAffected] wraps the UPDATE in a guard that rolls back on
  /// mismatch.
  Future<int> updateMany(
    List<MssqlKeyedPatch> patches, {
    int? expectAffected,
  }) async {
    if (patches.isEmpty) return 0;
    final stamped = <MssqlKeyedPatch>[
      for (final patch in patches)
        MssqlKeyedPatch(key: patch.key, patch: _stampUpdate(patch.patch)),
    ];
    Future<int> run(MssqlSession s) => MssqlBulkWriter<TRow>(
      s,
      binding: binding,
      dialect: dialect,
      clock: clock,
      changes: changes,
      scopes: scopes,
    )._updateMany(stamped);

    if (expectAffected != null) {
      final outcome = await _engine.guard(
        operation: 'updateMany',
        expected: expectAffected,
        write: (engine) async {
          final inner = await run(engine.session);
          return MssqlWriteOutcome(
            affectedRows: inner,
            affectedRowsSource: MssqlAffectedRowsSource.outputRows,
          );
        },
      );
      return outcome.affectedRows;
    }
    return _transact(run);
  }

  /// Groups [requests] by [keyColumn], refuses non-positive amounts, then
  /// one `UPDATE … JOIN` that subtracts only when the stored quantity
  /// still covers the request.
  ///
  /// Affected unique-key count must equal the grouped request count;
  /// otherwise the write is rolled back. Two requests for the same product
  /// become one subtraction of their sum, so stock cannot be decremented
  /// twice for one line of input that the caller meant as one product.
  Future<int> decrementQuantities({
    required String keyColumn,
    required String quantityColumn,
    required Iterable<({Object key, num amount})> requests,
  }) async {
    final key = binding.column(keyColumn);
    final qty = binding.column(quantityColumn);
    if (key == null) {
      throw ArgumentError.value(
        keyColumn,
        'keyColumn',
        'Not a column of ${binding.qualifiedName}.',
      );
    }
    if (qty == null) {
      throw ArgumentError.value(
        quantityColumn,
        'quantityColumn',
        'Not a column of ${binding.qualifiedName}.',
      );
    }
    if (!qty.writable) {
      throw ArgumentError.value(
        quantityColumn,
        'quantityColumn',
        'Is written by the server or marked read-only.',
      );
    }
    final grouped = <Object, ({Object key, num amount})>{};
    for (final request in requests) {
      if (request.amount <= 0) {
        throw ArgumentError.value(
          request.amount,
          'amount',
          'decrementQuantities on ${binding.qualifiedName}.$quantityColumn '
              'needs a positive amount for key ${request.key}.',
        );
      }
      final token = key.keyValue(request.key);
      final existing = grouped[token];
      grouped[token] = (
        key: request.key,
        amount: (existing?.amount ?? 0) + request.amount,
      );
    }
    if (grouped.isEmpty) return 0;
    final expected = grouped.length;
    Future<int> run(MssqlSession s) async {
      final actual = await MssqlBulkWriter<TRow>(
        s,
        binding: binding,
        dialect: dialect,
        clock: clock,
        changes: changes,
        scopes: scopes,
      )._decrement(key, qty, grouped);
      if (actual != expected) {
        throw MssqlAffectedRowsException(
          table: binding.qualifiedName,
          operation: 'decrementQuantities',
          expected: expected,
          actual: actual,
          rolledBack: !session.inTransaction,
        );
      }
      if (actual > 0) changes?.note(s, binding.qualifiedName);
      return actual;
    }

    return _transact(run);
  }

  Future<MssqlCreateManyResult<TRow>> _createManyValues(
    List<MssqlWriteAssignments> rows, {
    required bool returnRows,
  }) async {
    if (returnRows) {
      _requireMappedReadback();
    }
    final placed = returnRows ? List<TRow?>.filled(rows.length, null) : null;
    var inserted = 0;
    final groups = <String, List<({int index, MssqlWriteAssignments row})>>{};
    for (var i = 0; i < rows.length; i++) {
      final key = _maskKey(rows[i]);
      (groups[key] ??= <({int index, MssqlWriteAssignments row})>[]).add((
        index: i,
        row: rows[i],
      ));
    }
    for (final group in groups.values) {
      final per = _maxValuesRows(group.first.row);
      for (var start = 0; start < group.length; start += per) {
        final end = (start + per).clamp(0, group.length);
        final batch = group.sublist(start, end);
        if (returnRows) {
          inserted += await _mergeMapped(batch, placed!);
        } else {
          inserted += await _insertValues(batch.map((e) => e.row).toList());
        }
      }
    }
    if (inserted > 0) changes?.note(session, binding.qualifiedName);
    return MssqlCreateManyResult<TRow>(
      strategy: MssqlCreateManyStrategy.insertValues,
      insertedRows: inserted,
      rows: placed == null ? const [] : List<TRow>.of(placed.whereType<TRow>()),
      mappedToInput: placed != null,
    );
  }

  Future<MssqlCreateManyResult<TRow>> _createManyBulk(
    List<MssqlWriteAssignments> rows,
    MssqlBulkOptions options,
  ) async {
    options.validate();
    var inserted = 0;
    MssqlBulkResult? last;
    final groups = <String, List<MssqlWriteAssignments>>{};
    for (final row in rows) {
      _rejectServerValues(row);
      final key = _maskKey(row);
      (groups[key] ??= <MssqlWriteAssignments>[]).add(row);
    }
    for (final group in groups.values) {
      final columns = <MssqlBoundColumn>[
        for (final entry in group.first.entries)
          if (entry.value is MssqlBoundValue) binding.column(entry.key)!,
      ];
      if (columns.isEmpty) {
        throw StateError(
          'createMany(strategy: bulkCopy) on ${binding.qualifiedName} '
          'has a row that names no bound columns. BCP cannot send DEFAULT. '
          'Use strategy: values, or supply values for every column.',
        );
      }
      final bulkColumns = <MssqlBulkColumn>[
        for (var i = 0; i < columns.length; i++) _bulkColumn(columns[i], i + 1),
      ];
      final payload = <List<Object?>>[
        for (final row in group)
          <Object?>[
            for (final column in columns)
              (row[column.name]! as MssqlBoundValue).value,
          ],
      ];
      last = await session.bulkInsert(
        tableName: binding.quoted,
        columns: bulkColumns,
        rows: payload,
        options: options,
      );
      inserted += last.insertedRows;
    }
    if (inserted > 0) changes?.note(session, binding.qualifiedName);
    return MssqlCreateManyResult<TRow>(
      strategy: MssqlCreateManyStrategy.bulkCopy,
      insertedRows: inserted,
      bulkOptions: options,
      bulkResult: last,
    );
  }

  void _rejectServerValues(MssqlWriteAssignments row) {
    for (final entry in row.entries) {
      if (entry.value is MssqlServerValue) {
        throw StateError(
          'createMany(strategy: bulkCopy) cannot send '
          '${binding.qualifiedName}.${entry.key} as a SQL expression. BCP '
          'binds values, not SYSUTCDATETIME(). Pass a DateTime, omit the '
          'column so a table default applies, or use strategy: values.',
        );
      }
    }
  }

  void _requireMappedReadback() {
    if (_engine.triggers == MssqlTriggerKind.insteadOf) {
      throw MssqlReadbackUnavailableException(
        table: binding.qualifiedName,
        operation: 'createMany',
        reason:
            'the table has an INSTEAD OF trigger, so the INSERT never '
            'runs and OUTPUT cannot describe it',
      );
    }
    if (!binding.hasPrimaryKey && binding.identityColumn == null) {
      throw StateError(
        'createMany(returnRows: true) on ${binding.qualifiedName} has no '
        'primary key and no identity, so OUTPUT rows cannot be paired with '
        'the input. Pass returnRows: false, or add a key.',
      );
    }
  }

  Future<int> _mergeMapped(
    List<({int index, MssqlWriteAssignments row})> batch,
    List<TRow?> placed,
  ) async {
    final sample = batch.first.row;
    final bound = <MssqlBoundColumn>[
      for (final entry in sample.entries)
        if (entry.value is MssqlBoundValue) binding.column(entry.key)!,
    ];
    final server = <MapEntry<String, MssqlServerValue>>[
      for (final entry in sample.entries)
        if (entry.value is MssqlServerValue)
          MapEntry(entry.key, entry.value as MssqlServerValue),
    ];
    final insertNames = <String>[
      ...bound.map((c) => c.name),
      ...server.map((e) => e.key),
    ];
    if (insertNames.isEmpty) {
      for (final item in batch) {
        final outcome = await _engine.insertRow(item.row);
        if (outcome.rows.isEmpty) {
          throw StateError(
            'createMany on ${binding.qualifiedName} stored a row but '
            'read none back.',
          );
        }
        placed[item.index] = binding.fromRow(outcome.rows.first);
      }
      return batch.length;
    }
    final parameters = MssqlParameterAllocator();
    final tuples = <String>[];
    for (var i = 0; i < batch.length; i++) {
      final cells = <String>['$i'];
      for (final column in bound) {
        final value = batch[i].row[column.name]! as MssqlBoundValue;
        cells.add(parameters.bind(value.value));
      }
      tuples.add('(${cells.join(', ')})');
    }
    final usingCols = <String>[
      MssqlSql.quoteIdentifier('__mssql_ord'),
      ...bound.map((c) => MssqlSql.quoteIdentifier(c.name)),
    ];
    final insertList = insertNames.map(MssqlSql.quoteIdentifier).join(', ');
    final insertValues = <String>[
      for (final column in bound)
        '[s].${MssqlSql.quoteIdentifier(column.name)}',
      for (final entry in server)
        entry.value.expression.compile(parameters, dialect),
    ];
    final capture = _captureColumns();
    final outputInto = _engine.triggers == MssqlTriggerKind.after;
    final outCols = outputInto
        ? <String>[
            '[s].${MssqlSql.quoteIdentifier('__mssql_ord')}',
            ...capture.map(
              (c) => 'INSERTED.${MssqlSql.quoteIdentifier(c.name)}',
            ),
          ]
        : <String>[
            '[s].${MssqlSql.quoteIdentifier('__mssql_ord')}',
            ...binding.columns.map(
              (c) => 'INSERTED.${MssqlSql.quoteIdentifier(c.name)}',
            ),
          ];
    final merge = StringBuffer()
      ..write('MERGE ${binding.quoted} AS [t] USING (VALUES ')
      ..write(tuples.join(', '))
      ..write(') AS [s] (${usingCols.join(', ')}) ON 1 = 0 ')
      ..write('WHEN NOT MATCHED THEN INSERT ($insertList) ')
      ..write('VALUES (${insertValues.join(', ')}) ')
      ..write('OUTPUT ${outCols.join(', ')}');
    late final List<MssqlRow> rows;
    if (outputInto) {
      final declared = <String>[
        '${MssqlSql.quoteIdentifier('__mssql_ord')} int NOT NULL',
        for (final column in capture)
          '${MssqlSql.quoteIdentifier(column.name)} '
              '${mssqlSqlTypeDeclaration(column)} NULL',
      ];
      final join = capture
          .map(
            (c) =>
                '[k].${MssqlSql.quoteIdentifier(c.name)} = '
                '[t].${MssqlSql.quoteIdentifier(c.name)}',
          )
          .join(' AND ');
      final projection = binding.columns
          .map((c) => '[t].${MssqlSql.quoteIdentifier(c.name)}')
          .join(', ');
      rows = await session.queryTypedRows(
        'DECLARE @mssql_map TABLE (${declared.join(', ')}); '
        '$merge INTO @mssql_map; '
        'SELECT [k].${MssqlSql.quoteIdentifier('__mssql_ord')}, '
        '$projection FROM ${binding.quoted} AS [t] '
        'INNER JOIN @mssql_map AS [k] ON $join;',
        parameters: parameters.values,
      );
    } else {
      rows = await session.queryTypedRows(
        '$merge;',
        parameters: parameters.values,
      );
    }
    for (final row in rows) {
      final ordinal = (row.at(0)! as num).toInt();
      placed[batch[ordinal].index] = binding.fromRow(row);
    }
    return batch.length;
  }

  Future<int> _insertValues(List<MssqlWriteAssignments> rows) async {
    final sample = rows.first;
    final names = sample.columns.toList();
    if (names.isEmpty) {
      for (final row in rows) {
        await _engine.insertRow(row, readRow: false);
      }
      return rows.length;
    }
    final parameters = MssqlParameterAllocator();
    final quoted = names.map(MssqlSql.quoteIdentifier).join(', ');
    final tuples = <String>[];
    for (final row in rows) {
      final cells = <String>[];
      for (final name in names) {
        cells.add(switch (row[name]) {
          null => 'DEFAULT',
          MssqlBoundValue(:final value) => parameters.bind(value),
          MssqlServerValue(:final expression) => expression.compile(
            parameters,
            dialect,
          ),
          MssqlDefaultValue() => 'DEFAULT',
        });
      }
      tuples.add('(${cells.join(', ')})');
    }
    await session.execute(
      'INSERT INTO ${binding.quoted} ($quoted) VALUES ${tuples.join(', ')}',
      parameters: parameters.values,
    );
    return rows.length;
  }

  Future<int> _updateMany(List<MssqlKeyedPatch> patches) async {
    final keyNames = patches.first.key.keys.toList();
    _checkKeys(keyNames);
    final seen = <String>{};
    // Rows are grouped by which columns they write, so a patch that leaves a
    // column absent is never sent as NULL for it. Grouping by the *mask*
    // rather than by the union of every caller's columns is the whole
    // difference between "don't touch City" and "set City to NULL".
    final groups = <String, List<MssqlKeyedPatch>>{};
    for (final patch in patches) {
      if (patch.key.length != keyNames.length) {
        throw ArgumentError.value(
          patch.key,
          'key',
          'updateMany rows must name the same key columns.',
        );
      }
      final identity = <String>[];
      for (final name in keyNames) {
        final value = _lookup(patch.key, name);
        if (value == null && !_contains(patch.key, name)) {
          throw ArgumentError.value(
            patch.key,
            'key',
            'updateMany is missing key column "$name".',
          );
        }
        if (value == null) {
          throw ArgumentError.value(
            value,
            'key.$name',
            'updateMany cannot identify a row with a null key.',
          );
        }
        identity.add('${binding.column(name)!.keyValue(value)}');
      }
      // Two patches for one row would both apply, in an order the staging
      // join does not define, so the caller's second intention could win or
      // lose at random. Merge them before calling instead.
      if (!seen.add(identity.join(_keyJoin))) {
        throw ArgumentError.value(
          patch.key,
          'key',
          'updateMany was given two patches for the same row of '
              '${binding.qualifiedName}. A staging join applies both in no '
              'defined order; merge them into one patch.',
        );
      }
      if (patch.patch.isEmpty) {
        throw ArgumentError.value(
          patch.patch,
          'patch',
          'updateMany needs at least one column to write.',
        );
      }
      (groups[_maskKey(patch.patch)] ??= <MssqlKeyedPatch>[]).add(patch);
    }
    var affected = 0;
    for (final group in groups.values) {
      affected += await _updateManyGroup(keyNames, group);
    }
    if (affected > 0) changes?.note(session, binding.qualifiedName);
    return affected;
  }

  /// One staging cycle for rows that write exactly the same columns.
  ///
  /// Only [MssqlBoundValue] columns need a staging column: every row of the
  /// group agrees on the DEFAULT and server-expression columns — that is what
  /// the mask means — so those are written straight into the `SET` list. That
  /// keeps `DEFAULT` meaning the target's own default rather than the NULL a
  /// temp table with no defaults would have handed back.
  Future<int> _updateManyGroup(
    List<String> keyNames,
    List<MssqlKeyedPatch> group,
  ) async {
    final sample = group.first.patch;
    final keyCols = <MssqlBoundColumn>[
      for (final name in keyNames) binding.column(name)!,
    ];
    final boundCols = <MssqlBoundColumn>[
      for (final entry in sample.entries)
        if (entry.value is MssqlBoundValue) binding.column(entry.key)!,
    ];
    final staging = '#mssql_upd_${_stagingSeq++}';
    // Staging columns are named by position, not after the target's columns:
    // an unqualified scope predicate compiled into the joined statement must
    // not be able to resolve against the staging table, and a prefixed copy
    // of a 128-character column name would not fit an identifier anyway.
    final declared = <String>[
      for (var i = 0; i < keyCols.length; i++)
        '[k$i] ${mssqlSqlTypeDeclaration(keyCols[i])} NOT NULL',
      for (var i = 0; i < boundCols.length; i++)
        '[v$i] ${mssqlSqlTypeDeclaration(boundCols[i])} NULL',
    ];
    await session.execute('CREATE TABLE $staging (${declared.join(', ')});');
    try {
      final columnCount = keyCols.length + boundCols.length;
      final per = (MssqlParameterAllocator.maximumParameters ~/ columnCount)
          .clamp(1, 1000);
      for (var start = 0; start < group.length; start += per) {
        final end = (start + per).clamp(0, group.length);
        await _insertStaging(
          staging,
          keyCols,
          boundCols,
          group.sublist(start, end),
        );
      }
      final parameters = MssqlParameterAllocator();
      // Bind the target's alias so a generated, source-bound scope column
      // compiles to `[t].[Col]` rather than to the table it was generated
      // from, which is not what this statement calls it.
      parameters.sources.bind(binding.sourceRef, '[t]');
      final inlineSets = <String>[];
      for (final entry in sample.entries) {
        final quoted = MssqlSql.quoteIdentifier(
          binding.column(entry.key)!.name,
        );
        switch (entry.value) {
          case MssqlBoundValue():
            break;
          case MssqlDefaultValue():
            inlineSets.add('[t].$quoted = DEFAULT');
          case MssqlServerValue(:final expression):
            inlineSets.add(
              '[t].$quoted = ${expression.compile(parameters, dialect)}',
            );
        }
      }
      final setList = <String>[
        for (var i = 0; i < boundCols.length; i++)
          '[t].${MssqlSql.quoteIdentifier(boundCols[i].name)} = [s].[v$i]',
        ...inlineSets,
      ].join(', ');
      final join = <String>[
        for (var i = 0; i < keyCols.length; i++)
          '[t].${MssqlSql.quoteIdentifier(keyCols[i].name)} = [s].[k$i]',
      ].join(' AND ');
      final where = <String>[
        for (final condition in scopes) condition.compile(parameters, dialect),
      ];
      final guard = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';
      final result = await session.query(
        'DECLARE @mssql_upd_keys TABLE ('
        '${MssqlSql.quoteIdentifier(keyCols.first.name)} '
        '${mssqlSqlTypeDeclaration(keyCols.first)} NOT NULL); '
        'UPDATE [t] SET $setList OUTPUT INSERTED.'
        '${MssqlSql.quoteIdentifier(keyCols.first.name)} '
        'INTO @mssql_upd_keys '
        'FROM ${binding.quoted} AS [t] INNER JOIN $staging AS [s] ON $join'
        '$guard; '
        'SELECT COUNT(*) FROM @mssql_upd_keys;',
        parameters: parameters.values,
      );
      return (result.resultSets.last.typedRows.first.at(0)! as num).toInt();
    } finally {
      try {
        await session.execute('DROP TABLE $staging;');
      } catch (_) {}
    }
  }

  Future<void> _insertStaging(
    String staging,
    List<MssqlBoundColumn> keyCols,
    List<MssqlBoundColumn> boundCols,
    List<MssqlKeyedPatch> rows,
  ) async {
    final parameters = MssqlParameterAllocator();
    final names = <String>[
      for (var i = 0; i < keyCols.length; i++) '[k$i]',
      for (var i = 0; i < boundCols.length; i++) '[v$i]',
    ];
    final tuples = <String>[];
    for (final row in rows) {
      final cells = <String>[
        for (final column in keyCols)
          parameters.bind(column.bind(_lookup(row.key, column.name))),
        for (final column in boundCols)
          // The group's mask guarantees a bound value for each of these
          // columns in every row of the group, so there is no absent case
          // here to invent a NULL for.
          parameters.bind((row.patch[column.name]! as MssqlBoundValue).value),
      ];
      tuples.add('(${cells.join(', ')})');
    }
    await session.execute(
      'INSERT INTO $staging (${names.join(', ')}) VALUES ${tuples.join(', ')}',
      parameters: parameters.values,
    );
  }

  Future<int> _decrement(
    MssqlBoundColumn key,
    MssqlBoundColumn qty,
    Map<Object, ({Object key, num amount})> grouped,
  ) async {
    final staging = '#mssql_qty_${_stagingSeq++}';
    // `[k0]` / `[rq]` rather than the target's own column names, so an
    // unqualified scope predicate in the joined UPDATE cannot resolve
    // against the staging table.
    await session.execute(
      'CREATE TABLE $staging ('
      '[k0] ${mssqlSqlTypeDeclaration(key)} NOT NULL PRIMARY KEY, '
      '[rq] ${mssqlSqlTypeDeclaration(qty)} NOT NULL);',
    );
    try {
      final entries = grouped.entries.toList();
      final per = (MssqlParameterAllocator.maximumParameters ~/ 2).clamp(
        1,
        1000,
      );
      for (var start = 0; start < entries.length; start += per) {
        final end = (start + per).clamp(0, entries.length);
        final parameters = MssqlParameterAllocator();
        final tuples = <String>[];
        for (final entry in entries.sublist(start, end)) {
          tuples.add(
            '(${parameters.bind(key.bind(entry.value.key))}, '
            '${parameters.bind(qty.bind(entry.value.amount))})',
          );
        }
        await session.execute(
          'INSERT INTO $staging ([k0], [rq]) VALUES ${tuples.join(', ')}',
          parameters: parameters.values,
        );
      }
      final parameters = MssqlParameterAllocator();
      parameters.sources.bind(binding.sourceRef, '[t]');
      final quotedQty = MssqlSql.quoteIdentifier(qty.name);
      final quotedKey = MssqlSql.quoteIdentifier(key.name);
      // The stock guard and the query's scopes are both filters on the same
      // write: a decrement must not reach another tenant's row or a
      // soft-deleted one just because it went through a staging join.
      final guards = <String>[
        '[t].$quotedQty >= [s].[rq]',
        for (final condition in scopes) condition.compile(parameters, dialect),
      ];
      final result = await session.query(
        'DECLARE @mssql_qty_done TABLE ('
        '$quotedKey ${mssqlSqlTypeDeclaration(key)} NOT NULL); '
        'UPDATE [t] SET [t].$quotedQty = [t].$quotedQty - [s].[rq] '
        'OUTPUT INSERTED.$quotedKey INTO @mssql_qty_done '
        'FROM ${binding.quoted} AS [t] INNER JOIN $staging AS [s] ON '
        '[t].$quotedKey = [s].[k0] '
        'WHERE ${guards.join(' AND ')}; '
        'SELECT COUNT(*) FROM @mssql_qty_done;',
        parameters: parameters.values,
      );
      return (result.resultSets.last.typedRows.first.at(0)! as num).toInt();
    } finally {
      try {
        await session.execute('DROP TABLE $staging;');
      } catch (_) {}
    }
  }

  List<MssqlBoundColumn> _captureColumns() {
    if (binding.hasPrimaryKey) {
      return <MssqlBoundColumn>[
        for (final name in binding.primaryKey) binding.column(name)!,
      ];
    }
    return <MssqlBoundColumn>[binding.column(binding.identityColumn!)!];
  }

  void _checkKeys(List<String> names) {
    if (names.isEmpty) {
      throw ArgumentError('updateMany needs at least one key column.');
    }
    for (final name in names) {
      if (binding.column(name) == null) {
        throw ArgumentError.value(
          name,
          'key',
          'Not a column of ${binding.qualifiedName}.',
        );
      }
    }
  }

  int _maxValuesRows(MssqlWriteAssignments sample) {
    var bound = 0;
    for (final entry in sample.entries) {
      if (entry.value is MssqlBoundValue) bound++;
    }
    if (bound == 0) return 1;
    return (MssqlParameterAllocator.maximumParameters ~/ bound).clamp(1, 1000);
  }

  String _maskKey(MssqlWriteAssignments row) {
    final parts = <String>[
      for (final entry in row.entries)
        '${entry.key.toLowerCase()}=${switch (entry.value) {
          MssqlBoundValue() => 'b',
          MssqlDefaultValue() => 'd',
          MssqlServerValue(:final expression) => 's:${expression.compile(MssqlParameterAllocator(), dialect)}',
        }}',
    ]..sort();
    return parts.join(';');
  }

  MssqlWriteAssignments _stampInsert(MssqlWriteAssignments values) {
    var out = values;
    final stamps = binding.timestamps;
    for (final name in <String?>[stamps.createdColumn, stamps.updatedColumn]) {
      if (name == null) continue;
      final column = binding.column(name);
      if (column == null || !column.writable) continue;
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
    if (name == null || values.isEmpty) return values;
    final column = binding.column(name);
    if (column == null || !column.writable) return values;
    return values.withValue(name, MssqlServerValue(clock.expression));
  }

  MssqlBulkColumn _bulkColumn(MssqlBoundColumn column, int ordinal) {
    final bytes = column.maxLength < 0 ? 0 : column.maxLength;
    final wide =
        column.type == MssqlType.nchar || column.type == MssqlType.nvarchar;
    return MssqlBulkColumn(
      ordinal: ordinal,
      name: column.name,
      type: column.type,
      size: wide ? bytes ~/ 2 : bytes,
      precision: column.precision,
      scale: column.scale,
      nullable: column.nullable,
    );
  }

  Future<R> _transact<R>(Future<R> Function(MssqlSession session) body) async {
    return mssqlRunAtomic<R>(
      session: session,
      body: body,
      changes: changes,
      unavailableMessage:
          'createMany/updateMany on ${binding.qualifiedName} needs a '
          'transaction for a multi-statement write, and this session cannot '
          'open one (a pooled handle is the usual case). Open a connection '
          'or an explicit transaction, then retry.',
    );
  }
}

int _stagingSeq = 0;

/// Separator for the composite-key identity a keyed batch dedupes on.
///
/// NUL rather than a space or a comma: `keyValue` can return text, so a
/// two-column key of `('a b', 'c')` would otherwise collide with
/// `('a', 'b c')` and one of the two patches would be dropped as a
/// duplicate.
const String _keyJoin = '\u0000';

Object? _lookup(Map<String, Object?> columns, String name) {
  if (columns.containsKey(name)) return columns[name];
  final lower = name.toLowerCase();
  for (final entry in columns.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

bool _contains(Map<String, Object?> columns, String name) {
  if (columns.containsKey(name)) return true;
  final lower = name.toLowerCase();
  return columns.keys.any((key) => key.toLowerCase() == lower);
}
