import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../dml.dart';
import '../expression.dart';
import '../operators.dart';
import '../query.dart';
import '../statement.dart';
import 'cursor.dart';
import 'observer.dart';
import 'retry.dart';

/// Runs any built select, including a union.
///
/// The builder itself never touches a connection — that is what makes its
/// output testable and loggable — so this is the seam where the two meet. It
/// stays an extension rather than a method on [MssqlSelectQuery] so the separation
/// survives: a query does not gain the ability to run itself.
extension MssqlSelectQueryExecution on MssqlSelectQuery {
  /// Every row, as the driver's own typed rows.
  Future<List<MssqlRow>> get(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
  }) async {
    final compileWatch = Stopwatch()..start();
    final statement = compile(dialect: dialect);
    compileWatch.stop();
    mssqlNoteCompileElapsed(session, compileWatch.elapsed);
    return session.queryTypedRows(
      statement.sql,
      parameters: statement.parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      // A SELECT the builder wrote is safe to repeat, so a lost connection is
      // recovered by the driver rather than surfacing here. A SELECT with a
      // raw fragment in it is not: see MssqlStatementRetry.
      retry: statement.readRetry,
    );
  }

  /// Every row, mapped by [map].
  Future<List<T>> getAs<T>(
    MssqlSession session,
    T Function(MssqlRow row) map, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) async {
    final rows = await get(session, dialect: dialect, timeout: timeout);
    return rows.map(map).toList(growable: false);
  }
}

/// Terminal helpers that also reshape an ordinary query before running it.
extension MssqlQueryExecution on MssqlQuery {
  /// The first row, or null.
  ///
  /// Narrowed to one row so that the server stops early rather than
  /// materialising a result the caller discards. Which clause does the
  /// narrowing depends on what the query already carries: a page keeps its
  /// offset and asks for one row of it, and everything else — including a
  /// `top()` wider than one — becomes `TOP (1)`. The two are never combined,
  /// which SQL Server rejects anyway.
  Future<MssqlRow?> first(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
  }) async {
    final start = offset;
    final limited = start == null ? top(1) : paged(offset: start, rows: 1);
    final rows = await limited.get(
      session,
      dialect: dialect,
      timeout: timeout,
      cancellationToken: cancellationToken,
      options: options,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Maps the native row stream without buffering the whole result.
  Stream<MssqlRow> stream(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
  }) async* {
    final statement = compile(dialect: dialect);
    await for (final event in session.stream(
      statement.sql,
      parameters: statement.parameters,
      options: options,
      timeout: timeout,
      cancellationToken: cancellationToken,
      batchRows: options.batchRows,
    )) {
      if (event is MssqlRowBatch) {
        for (final row in event.rows) {
          yield row;
        }
      }
    }
  }

  /// The first row, or [StateError].
  Future<MssqlRow> firstOrFail(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) async {
    final row = await first(session, dialect: dialect, timeout: timeout);
    if (row == null) {
      throw StateError('No row matched ${compile(dialect: dialect).sql}.');
    }
    return row;
  }

  /// One column of the first row.
  Future<T?> value<T>(
    MssqlSession session,
    String column, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) async {
    final row = await select(<MssqlExpression>[
      Col(column),
    ]).first(session, dialect: dialect, timeout: timeout);
    return row?.get<T>(column);
  }

  /// One column of every row.
  Future<List<T?>> pluck<T>(
    MssqlSession session,
    String column, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) async {
    final rows = await select(<MssqlExpression>[
      Col(column),
    ]).get(session, dialect: dialect, timeout: timeout);
    return rows.map((r) => r.get<T>(column)).toList(growable: false);
  }

  /// Whether the query matches anything.
  ///
  /// `SELECT TOP (1) 1` rather than a count: the server can stop at the first
  /// match instead of counting every one of them. The `1` is bound as a
  /// parameter rather than written into the SQL so that the statement stays
  /// one the builder wrote from end to end, and therefore one whose lost
  /// connection the driver may retry.
  ///
  /// An unpaged query loses its ordering here: sorting rows that are not read
  /// costs the server work and changes no answer. A paged one keeps it, since
  /// "does a hundred-and-first row exist" is a question about the ordering.
  /// Grouping is left alone either way: one row out of `GROUP BY` still means
  /// the query matched something.
  Future<bool> exists(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) async {
    final probe = select(<MssqlExpression>[const MssqlProbeLiteral()]);
    final start = offset;
    final limited = start == null
        ? probe.orderBy(const <MssqlOrder>[]).top(1)
        : probe.paged(offset: start, rows: 1);
    final rows = await limited.get(session, dialect: dialect, timeout: timeout);
    return rows.isNotEmpty;
  }

  Future<bool> doesntExist(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) async => !await exists(session, dialect: dialect, timeout: timeout);

  /// How many rows this query returns.
  ///
  /// See [MssqlQuery.countRows] for what that means when the query has a
  /// `DISTINCT`, a `GROUP BY` or a page: the count follows the query's shape
  /// rather than discarding it.
  Future<int> count(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
  }) async {
    final rows = await countRows().get(
      session,
      dialect: dialect,
      timeout: timeout,
      cancellationToken: cancellationToken,
      options: options,
    );
    return rows.isEmpty ? 0 : (rows.first.at(0)! as num).toInt();
  }

  /// How many distinct values of [columns] the matched rows hold.
  ///
  /// A count of parents rather than of join result rows: a query joined to a
  /// child table returns one row per child, and `countDistinct(['Id'])` is
  /// what asks the other question.
  Future<int> countDistinctColumns(
    MssqlSession session,
    Iterable<String> columns, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) async {
    final rows = await countDistinct(
      columns.map<MssqlExpression>(Col).toList(growable: false),
    ).get(session, dialect: dialect, timeout: timeout);
    return rows.isEmpty ? 0 : (rows.first.at(0)! as num).toInt();
  }

  /// `SUM` of [column] over the rows this query returns, or null for none.
  ///
  /// [T] is unbounded on purpose. `T extends num` would read as the safe
  /// choice and would be the lossy one: `MssqlDecimal` is not a `num`, so a
  /// bound would force the sum of a `decimal` or `money` column through
  /// `double` and drop digits past about the fifteenth — the one thing exact
  /// decimal exists to prevent. Ask for `sum<MssqlDecimal>` on an exact
  /// column and `sum<int>` / `sum<double>` on the others; a [T] the value
  /// cannot become is a cast error naming the column, not a rounded answer.
  Future<T?> sum<T>(
    MssqlSession session,
    String column, {
    MssqlDialect dialect = MssqlDialect.sql2012,
  }) => _aggregate<T>(session, 'SUM', column, dialect);

  /// `AVG` of [column] over the rows this query returns, or null for none.
  ///
  /// Unbounded [T] for the same reason as [sum]. Note that SQL Server's
  /// `AVG` of an integer column is integer division; cast the column, or use
  /// the typed builder's `avg(integers: …)`, if the fraction matters.
  Future<T?> avg<T>(
    MssqlSession session,
    String column, {
    MssqlDialect dialect = MssqlDialect.sql2012,
  }) => _aggregate<T>(session, 'AVG', column, dialect);

  Future<T?> min<T>(
    MssqlSession session,
    String column, {
    MssqlDialect dialect = MssqlDialect.sql2012,
  }) => _aggregate<T>(session, 'MIN', column, dialect);

  Future<T?> max<T>(
    MssqlSession session,
    String column, {
    MssqlDialect dialect = MssqlDialect.sql2012,
  }) => _aggregate<T>(session, 'MAX', column, dialect);

  Future<T?> _aggregate<T>(
    MssqlSession session,
    String function,
    String column,
    MssqlDialect dialect,
  ) async {
    // Over the rows this query *returns*, not over the rows it reads: a
    // DISTINCT or a page is part of the question, and reprojecting in place
    // would throw it away. See MssqlQuery.aggregateRows.
    final rows = await aggregateRows(
      MssqlFunction(function, <MssqlExpression>[Col(column)]),
    ).get(session, dialect: dialect);
    if (rows.isEmpty) return null;
    final value = rows.first.at(0);
    // An aggregate over no rows is NULL, which is a real answer rather than a
    // zero: "the average of nothing" has no value.
    if (value == null) return null;
    if (value is T) return value as T;
    if (value is num && T == int) return value.toInt() as T;
    if (value is num && T == double) return value.toDouble() as T;
    throw StateError(
      '$function($column) on ${source.quoted} came back as '
      '${value.runtimeType}, which is not $T. An exact column arrives as '
      'MssqlDecimal under MssqlDecimalMode.exact and as String under '
      'MssqlDecimalMode.text; ask for the type the connection actually '
      'decodes rather than one it would have to round to.',
    );
  }

  /// Walks the whole result in keyset pages of [size], without holding it
  /// all in memory.
  ///
  /// OFFSET is not used: deleting a processed row would otherwise skip the
  /// next one. Requires `orderBy` on named columns so each page can bind
  /// the last row's keys. A mutable order column is still not a snapshot.
  ///
  /// The callback returning `false` stops the walk, so a search can give up
  /// early without reading the rest.
  Future<void> chunk(
    MssqlSession session,
    int size,
    Future<bool> Function(List<MssqlRow> rows) handle, {
    MssqlDialect dialect = MssqlDialect.sql2012,
  }) async {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive.');
    }
    if (ordering.isEmpty) {
      throw StateError(
        'chunk() needs orderBy(): without one, two pages can return the same '
        'row and never return another. Source: ${source.quoted}.',
      );
    }
    MssqlKeyset.requireNamedColumns(ordering, 'chunk()');
    List<Object?>? after;
    while (true) {
      var query = this;
      if (after != null) {
        query = query.where(MssqlKeyset.after(ordering, after));
      }
      final page = await query.top(size).get(session, dialect: dialect);
      if (page.isEmpty) return;
      if (!await handle(page)) return;
      if (page.length < size) return;
      after = MssqlKeyset.keysFromRow(page.last, ordering);
    }
  }

  /// [chunk] as a stream, for a caller that would rather iterate than pass a
  /// callback.
  Stream<MssqlRow> lazy(
    MssqlSession session, {
    int size = 500,
    MssqlDialect dialect = MssqlDialect.sql2012,
  }) async* {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive.');
    }
    if (ordering.isEmpty) {
      throw StateError(
        'lazy() needs orderBy(); see chunk(). Source: ${source.quoted}.',
      );
    }
    MssqlKeyset.requireNamedColumns(ordering, 'lazy()');
    List<Object?>? after;
    while (true) {
      var query = this;
      if (after != null) {
        query = query.where(MssqlKeyset.after(ordering, after));
      }
      final page = await query.top(size).get(session, dialect: dialect);
      for (final row in page) {
        yield row;
      }
      if (page.length < size) return;
      after = MssqlKeyset.keysFromRow(page.last, ordering);
    }
  }
}

/// Runs a built statement.
extension MssqlStatementExecution on MssqlStatement {
  Future<int> run(MssqlSession session, {Duration? timeout}) =>
      session.execute(sql, parameters: parameters, timeout: timeout);
}

extension MssqlInsertExecution on MssqlInsert {
  Future<int> run(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) => compile(dialect: dialect).run(session, timeout: timeout);

  /// Runs the statement and returns the rows its `OUTPUT` clause produced.
  ///
  /// The clause must already be on the statement, through `returning()`.
  /// Adding it here by string-replacing the compiled SQL would work only for
  /// the shape it was written for.
  Future<List<MssqlRow>> runReturning(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) =>
      _returning(session, compile(dialect: dialect), output, 'INSERT', timeout);
}

/// Shared by the three statements that can carry an `OUTPUT` clause.
Future<List<MssqlRow>> _returning(
  MssqlSession session,
  MssqlStatement statement,
  MssqlOutputClause? clause,
  String verb,
  Duration? timeout,
) {
  if (clause == null || !clause.returnsRows) {
    throw StateError(
      'This $verb has no OUTPUT clause that returns rows, so there is nothing '
      'to read. Add returning(MssqlOutputClause.inserted([...])) without an '
      'into: target, or call run() for the count alone.',
    );
  }
  return session.queryTypedRows(
    statement.sql,
    parameters: statement.parameters,
    timeout: timeout,
  );
}

extension MssqlInsertSelectExecution on MssqlInsertSelect {
  Future<int> run(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) => compile(dialect: dialect).run(session, timeout: timeout);
}

extension MssqlUpsertExecution on MssqlUpsert {
  Future<int> run(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) => compile(dialect: dialect).run(session, timeout: timeout);
}

extension MssqlUpdateExecution on MssqlUpdate {
  Future<int> run(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) => compile(dialect: dialect).run(session, timeout: timeout);

  /// Runs the statement and returns the rows its `OUTPUT` clause produced.
  Future<List<MssqlRow>> runReturning(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) =>
      _returning(session, compile(dialect: dialect), output, 'UPDATE', timeout);
}

extension MssqlDeleteExecution on MssqlDelete {
  Future<int> run(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) => compile(dialect: dialect).run(session, timeout: timeout);

  /// Runs the statement and returns the rows its `OUTPUT` clause produced.
  Future<List<MssqlRow>> runReturning(
    MssqlSession session, {
    MssqlDialect dialect = MssqlDialect.sql2012,
    Duration? timeout,
  }) =>
      _returning(session, compile(dialect: dialect), output, 'DELETE', timeout);
}
