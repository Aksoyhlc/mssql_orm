import 'dart:async';

import 'package:mssql_native/mssql_native.dart';

/// How [MssqlEntityQuery.watch] learns that its rows may have changed.
enum MssqlWatchStrategy {
  /// Re-run after a committed write on this [MssqlAppDatabase] family.
  ///
  /// Rollback does not emit. Writes from another application, another
  /// connection, or a raw SQL string this hub did not see are invisible.
  localWrites,

  /// Re-run on a timer. Sees external writes that [localWrites] cannot.
  polling,
}

/// Committed table names this AppDatabase family has written.
///
/// Shared across [MssqlAppDatabase.fork] so a transaction database and its
/// parent notify the same listeners, and only after COMMIT.
class MssqlChangeHub {
  final List<void Function(Set<String> tables)> _listeners =
      <void Function(Set<String> tables)>[];
  final Expando<Set<String>> _pending = Expando<Set<String>>();

  /// Records a write. Notified immediately when [session] is not in a
  /// transaction; otherwise held until [commitPending].
  void note(MssqlSession session, String table) {
    if (session.inTransaction) {
      (_pending[session] ??= <String>{}).add(table);
      return;
    }
    notify(<String>{table});
  }

  /// Publishes tables written in [session]'s transaction after COMMIT.
  void commitPending(MssqlSession? session) {
    if (session == null) return;
    final tables = _pending[session];
    _pending[session] = null;
    if (tables == null || tables.isEmpty) return;
    notify(tables);
  }

  /// Drops tables written in [session] because the transaction rolled back.
  void discardPending(MssqlSession? session) {
    if (session == null) return;
    _pending[session] = null;
  }

  /// Tells listeners which qualified table names changed.
  void notify(Set<String> tables) {
    if (tables.isEmpty) return;
    final snapshot = Set<String>.unmodifiable(tables);
    for (final listener in List<void Function(Set<String>)>.of(_listeners)) {
      listener(snapshot);
    }
  }

  void Function() listen(void Function(Set<String> tables) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// Builds the watch stream for one query.
Stream<List<TRow>> mssqlWatchRows<TRow>({
  required MssqlWatchStrategy strategy,
  required Duration interval,
  required Set<String> tables,
  required MssqlChangeHub? hub,
  required Future<List<TRow>> Function() read,
  required bool Function(List<TRow> a, List<TRow> b) same,
}) {
  late StreamController<List<TRow>> controller;
  Timer? timer;
  var inflight = false;
  var closed = false;
  List<TRow>? last;
  void Function()? unsubscribe;

  Future<void> emit() async {
    if (closed || inflight) return;
    inflight = true;
    try {
      final rows = await read();
      if (closed) return;
      if (last != null && same(last!, rows)) return;
      last = rows;
      if (!controller.isClosed) controller.add(rows);
    } catch (error, stack) {
      if (!closed && !controller.isClosed) {
        controller.addError(error, stack);
      }
    } finally {
      inflight = false;
    }
  }

  void cancel() {
    if (closed) return;
    closed = true;
    timer?.cancel();
    timer = null;
    unsubscribe?.call();
    unsubscribe = null;
    if (!controller.isClosed) controller.close();
  }

  controller = StreamController<List<TRow>>(
    onListen: () {
      if (strategy == MssqlWatchStrategy.localWrites) {
        final changes = hub;
        if (changes == null) {
          controller.addError(
            StateError(
              'watch(strategy: localWrites) needs an AppDatabase so it can '
              'see that family\'s committed writes. Use polling to see '
              'external writers, or open the query from db.orders rather '
              'than a bare session.',
            ),
          );
          return;
        }
        unsubscribe = changes.listen((written) {
          if (written.any(tables.contains)) scheduleMicrotask(emit);
        });
      } else {
        timer = Timer.periodic(interval, (_) {
          unawaited(emit());
        });
      }
      unawaited(emit());
    },
    onCancel: cancel,
  );
  return controller.stream;
}

/// Column-map equality for rows that do not override `==`.
bool mssqlRowsEqual<TRow>(
  List<TRow> a,
  List<TRow> b,
  Map<String, Object?> Function(TRow row)? columnsOf,
) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] == b[i]) continue;
    if (columnsOf == null) return false;
    if (!_mapsEqual(columnsOf(a[i]), columnsOf(b[i]))) return false;
  }
  return true;
}

bool _mapsEqual(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
