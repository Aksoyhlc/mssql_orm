import 'package:mssql_native/mssql_native.dart';

import 'observer.dart';
import 'watch.dart';

Future<R> mssqlRunAtomic<R>({
  required MssqlSession session,
  required Future<R> Function(MssqlSession session) body,
  required String unavailableMessage,
  MssqlChangeHub? changes,
}) async {
  final inner = _unwrap(session);
  if (inner is MssqlTransaction) {
    return inner.savepoint(() => body(session));
  }
  if (inner is MssqlConnection) {
    MssqlTransaction? transaction;
    try {
      final result = await inner.transaction((opened) async {
        transaction = opened;
        return body(_rewrap(session, opened));
      });
      if (transaction != null) changes?.commitPending(transaction);
      return result;
    } catch (_) {
      if (transaction != null) changes?.discardPending(transaction);
      rethrow;
    }
  }
  throw StateError(unavailableMessage);
}

MssqlSession _unwrap(MssqlSession session) {
  var current = session;
  while (current is MssqlObservedSession) {
    current = current.inner;
  }
  return current;
}

MssqlSession _rewrap(MssqlSession original, MssqlSession transaction) {
  final observers = <MssqlQueryObserver>[];
  var current = original;
  while (current is MssqlObservedSession) {
    observers.add(current.observer);
    current = current.inner;
  }
  var out = transaction;
  for (final observer in observers.reversed) {
    out = MssqlObservedSession(out, observer);
  }
  return out;
}
