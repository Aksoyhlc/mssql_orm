import 'package:mssql_native/mssql_native.dart';

import '../dialect.dart';
import '../expression.dart';
import '../projection.dart';
import '../query.dart';
import 'capability_cache.dart';
import 'cursor.dart';
import 'observer.dart';
import 'page.dart';
import 'run_query.dart';
import 'watch.dart';

/// A query whose result is [R], not an entity row.
///
/// There is no `create` / `update` / relation getter here: a projection is
/// a read shape. Putting writes on it would imply updating a DTO that has
/// no table identity.
class MssqlProjectedQuery<R> {
  MssqlProjectedQuery({
    required this.session,
    required this.dialect,
    required this.projection,
    required MssqlQuery Function(List<MssqlExpression> columns) build,
    this.timeout,
    this.options = const MssqlQueryOptions(),
    this.capabilities,
  }) : _build = build;

  final MssqlSession session;
  final MssqlDialect dialect;
  final MssqlCapabilityCache? capabilities;
  final MssqlProjection<R> projection;
  final Duration? timeout;
  final MssqlQueryOptions options;
  final MssqlQuery Function(List<MssqlExpression> columns) _build;

  MssqlQuery get _select => _build(projection.selectList);

  Future<MssqlDialect> _resolvedDialect() {
    final cache = capabilities;
    if (cache == null) return Future<MssqlDialect>.value(dialect);
    return cache.resolve(session);
  }

  /// Every projected row.
  Future<List<R>> get() async {
    final dialect = await _resolvedDialect();
    final rows = await _select.get(
      session,
      dialect: dialect,
      timeout: timeout,
      cancellationToken: options.cancellationToken,
      options: options,
    );
    return rows.map(_map).toList(growable: false);
  }

  /// The first projected row, or null.
  Future<R?> first() async {
    final dialect = await _resolvedDialect();
    final row = await _select.first(
      session,
      dialect: dialect,
      timeout: timeout,
      cancellationToken: options.cancellationToken,
      options: options,
    );
    return row == null ? null : _map(row);
  }

  /// How many rows this projection returns.
  Future<int> count() async {
    final dialect = await _resolvedDialect();
    return _select.count(
      session,
      dialect: dialect,
      timeout: timeout,
      cancellationToken: options.cancellationToken,
      options: options,
    );
  }

  /// One OFFSET page of projected rows.
  ///
  /// Needs a unique `orderBy` on the projection. The root entity primary
  /// key is not added: a distinct or grouped result does not have that
  /// identity.
  Future<MssqlPage<R>> page({
    int size = 25,
    int offset = 0,
    bool total = false,
    MssqlReadConsistency consistency = MssqlReadConsistency.committed,
  }) async {
    if (offset < 0) {
      throw ArgumentError.value(offset, 'offset', 'Cannot be negative.');
    }
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive.');
    }
    final dialect = await _resolvedDialect();
    final query = _select;
    if (query.ordering.isEmpty) {
      throw StateError(
        'Projection ${projection.name} needs an explicit unique orderBy '
        'before page(). The root primary key is not added to a projection.',
      );
    }
    if (query.distinct || query.grouping.isNotEmpty) {
      MssqlKeyset.requireProjectedColumns(
        query.ordering,
        projection.columns.map((c) => c.alias),
        projection.name,
      );
    }
    return mssqlRunConsistent(
      session: session,
      consistency: consistency,
      body: (s) async {
        final fetched = await query
            .paged(offset: offset, rows: size + 1)
            .get(
              s,
              dialect: dialect,
              timeout: timeout,
              cancellationToken: options.cancellationToken,
              options: options,
            );
        final hasMore = fetched.length > size;
        final slice = hasMore ? fetched.sublist(0, size) : fetched;
        return MssqlPage<R>(
          rows: slice.map(_map).toList(growable: false),
          offset: offset,
          requestedRows: size,
          hasMore: hasMore,
          total: total ? await _countOn(s, dialect: dialect) : null,
        );
      },
    );
  }

  /// A keyset page of projected rows. [after] and [before] are exclusive.
  Future<MssqlCursorPage<R>> cursorPage({
    int size = 25,
    MssqlCursor? after,
    MssqlCursor? before,
    MssqlReadConsistency consistency = MssqlReadConsistency.committed,
  }) async {
    if (after != null && before != null) {
      throw ArgumentError('cursorPage cannot take after and before together.');
    }
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive.');
    }
    final dialect = await _resolvedDialect();
    final base = _select;
    if (base.ordering.isEmpty) {
      throw StateError(
        'Projection ${projection.name} needs an explicit unique orderBy '
        'before cursorPage().',
      );
    }
    MssqlKeyset.requireProjectedColumns(
      base.ordering,
      projection.columns.map((c) => c.alias),
      projection.name,
    );
    final orders = base.ordering;
    final orderSig = MssqlKeyset.orderSignature(orders, dialect);
    final filterSig = MssqlKeyset.queryFilterSignature(base, dialect);
    if (after != null) {
      MssqlKeyset.check(
        after,
        orderSignature: orderSig,
        filterSignature: filterSig,
        keyCount: orders.length,
      );
    }
    if (before != null) {
      MssqlKeyset.check(
        before,
        orderSignature: orderSig,
        filterSignature: filterSig,
        keyCount: orders.length,
      );
    }
    final walking = before != null ? MssqlKeyset.reverseOrders(orders) : orders;
    final cursor = after ?? before;
    return mssqlRunConsistent(
      session: session,
      consistency: consistency,
      body: (s) async {
        var query = base.orderBy(walking);
        if (cursor != null) {
          query = query.where(MssqlKeyset.after(walking, cursor.keys));
        }
        final fetched = await query
            .top(size + 1)
            .get(
              s,
              dialect: dialect,
              timeout: timeout,
              cancellationToken: options.cancellationToken,
              options: options,
            );
        final hasExtra = fetched.length > size;
        final kept = hasExtra ? fetched.sublist(0, size) : fetched;
        var mapped = kept.map(_map).toList();
        if (before != null) {
          mapped = mapped.reversed.toList();
        }
        if (kept.isEmpty) {
          return MssqlCursorPage<R>(rows: mapped, hasMore: false);
        }
        final firstRaw = before != null ? kept.last : kept.first;
        final lastRaw = before != null ? kept.first : kept.last;
        MssqlCursor make(MssqlRow row) => MssqlKeyset.encode(
          orderSignature: orderSig,
          filterSignature: filterSig,
          keys: MssqlKeyset.keysFromRow(row, orders),
        );
        return MssqlCursorPage<R>(
          rows: mapped,
          hasMore: hasExtra,
          next: before != null || hasExtra ? make(lastRaw) : null,
          previous: after != null || (before != null && hasExtra)
              ? make(firstRaw)
              : null,
        );
      },
    );
  }

  /// Keyset chunks of projected rows. OFFSET is not used.
  Stream<List<R>> chunk({int size = 500}) async* {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'Must be positive.');
    }
    final base = _select;
    if (base.ordering.isEmpty) {
      throw StateError(
        'Projection ${projection.name} needs an explicit unique orderBy '
        'before chunk(). The root primary key is not added.',
      );
    }
    MssqlKeyset.requireProjectedColumns(
      base.ordering,
      projection.columns.map((c) => c.alias),
      projection.name,
    );
    final dialect = await _resolvedDialect();
    final orders = base.ordering;
    List<Object?>? after;
    while (true) {
      var query = base;
      if (after != null) {
        query = query.where(MssqlKeyset.after(orders, after));
      }
      final fetched = await query
          .top(size)
          .get(
            session,
            dialect: dialect,
            timeout: timeout,
            cancellationToken: options.cancellationToken,
            options: options,
          );
      if (fetched.isEmpty) return;
      yield fetched.map(_map).toList(growable: false);
      if (fetched.length < size) return;
      after = MssqlKeyset.keysFromRow(fetched.last, orders);
    }
  }

  /// [chunk] as a row stream.
  Stream<R> lazy({int size = 500}) async* {
    await for (final batch in chunk(size: size)) {
      for (final row in batch) {
        yield row;
      }
    }
  }

  /// Streams projected rows from the native row stream.
  Stream<R> stream() async* {
    final dialect = await _resolvedDialect();
    final compileWatch = Stopwatch()..start();
    final statement = _select.compile(dialect: dialect);
    compileWatch.stop();
    mssqlNoteCompileElapsed(session, compileWatch.elapsed);
    await for (final event in session.stream(
      statement.sql,
      parameters: statement.parameters,
      options: options,
      timeout: timeout,
      cancellationToken: options.cancellationToken,
      batchRows: options.batchRows,
    )) {
      if (event is MssqlRowBatch) {
        for (final row in event.rows) {
          yield _map(row);
        }
      }
    }
  }

  Future<int> _countOn(MssqlSession session, {MssqlDialect? dialect}) async {
    final resolved = dialect ?? await _resolvedDialect();
    return _select.count(
      session,
      dialect: resolved,
      timeout: timeout,
      cancellationToken: options.cancellationToken,
      options: options,
    );
  }

  /// Re-runs this projection when [tables] may have changed.
  ///
  /// A projection has no table identity of its own. [tables] must name the
  /// objects whose writes should invalidate it.
  Stream<List<R>> watch({
    required Iterable<String> tables,
    MssqlWatchStrategy strategy = MssqlWatchStrategy.polling,
    Duration interval = const Duration(seconds: 1),
    MssqlChangeHub? hub,
  }) {
    final watched = tables.toSet();
    if (watched.isEmpty) {
      throw ArgumentError.value(
        tables,
        'tables',
        'A projection watch needs explicit table names; the SELECT list '
            'does not name its sources.',
      );
    }
    return mssqlWatchRows<R>(
      strategy: strategy,
      interval: interval,
      tables: watched,
      hub: hub,
      read: get,
      same: (a, b) {
        if (a.length != b.length) return false;
        for (var i = 0; i < a.length; i++) {
          if (a[i] != b[i]) return false;
        }
        return true;
      },
    );
  }

  R _map(MssqlRow row) {
    try {
      return projection.map(row);
    } on Object catch (error) {
      throw StateError(
        'Projection ${projection.name} failed to map a row: $error',
      );
    }
  }
}
