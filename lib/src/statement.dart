import 'package:meta/meta.dart';

import 'source_ref.dart';

/// A compiled statement: the SQL text and the values bound to it.
///
/// Compilation is separate from execution so that generated SQL can be
/// asserted in a test with no server, logged before it runs, and compiled for
/// a chosen dialect rather than for whatever the connection happens to be.
@immutable
class MssqlStatement {
  MssqlStatement(
    this.sql,
    Map<String, Object?> parameters, {
    this.containsRawSql = false,
  }) : parameters = Map<String, Object?>.unmodifiable(parameters);

  /// Builds a statement from an allocator, carrying over what it observed.
  ///
  /// The preferred constructor for the compilers: whether a raw fragment went
  /// into the SQL is not something a caller should have to remember to pass.
  MssqlStatement.fromAllocator(this.sql, MssqlParameterAllocator allocator)
    : parameters = Map<String, Object?>.unmodifiable(allocator.values),
      containsRawSql = allocator.sawRawSql;

  /// The SQL text, with every caller-supplied value replaced by a parameter.
  final String sql;

  /// The values to bind, keyed by parameter name without the leading `@`.
  ///
  /// Names are an implementation detail of one [MssqlStatement]; depend on
  /// this map, not on the names in [sql].
  final Map<String, Object?> parameters;

  /// Whether any part of [sql] came from a `raw` fragment.
  ///
  /// The one question the execution layer has to ask before deciding a
  /// statement is safe to repeat. Everything the builder emits itself, it
  /// knows the meaning of; a raw fragment could be `INSERT … OUTPUT` or a
  /// procedure call, and the builder has no way to tell. So a statement with
  /// raw in it is never an automatic retry candidate, whatever shape it has.
  final bool containsRawSql;

  @override
  String toString() => 'MssqlStatement($sql, $parameters)';
}

/// Names parameters and collects their values while a statement is compiled.
///
/// Generated names are `q0`, `q1`, … in binding order. A fragment passed to
/// `raw` carries names the caller chose, so those are checked against the
/// generated shape rather than trusted: a collision would silently rebind one
/// of the two values.
class MssqlParameterAllocator {
  final Map<String, Object?> _values = <String, Object?>{};

  /// Names already taken, folded to lower case.
  ///
  /// SQL Server matches parameter names case-insensitively under its usual
  /// collations, so `@From` and `@from` are one parameter to the server and
  /// two to a Dart map. Tracking the folded form is what turns that from a
  /// value silently overwriting another into an error the caller can read.
  final Map<String, String> _folded = <String, String>{};
  int _next = 0;
  bool _sawRawSql = false;

  /// What each source in the statement being compiled is called.
  ///
  /// A fragment compiled on its own has an empty scope, and every column then
  /// writes its own qualified name — which is what a standalone `compile()`
  /// should produce.
  final MssqlSourceScope sources = MssqlSourceScope();

  /// SQL Server's own ceiling on parameters in one statement.
  ///
  /// Checked here rather than left to the server because the server's answer
  /// is error 8003 with no indication of which query, and because a builder
  /// that fans a list into parameters can cross it without the caller ever
  /// seeing a number.
  static const int maximumParameters = 2100;

  /// How many parameters have been bound.
  int get length => _values.length;

  /// Whether a `raw` fragment has been compiled through this allocator.
  bool get sawRawSql => _sawRawSql;

  /// Records that SQL the builder did not write went into the statement.
  void markRaw() => _sawRawSql = true;

  /// The reserved shape. A `raw` fragment may not use a name matching this.
  static final RegExp reservedName = RegExp(r'^q\d+$');

  /// Binds [value] to a fresh generated name and returns that name with its
  /// leading `@`, ready to be written into the SQL text.
  String bind(Object? value) {
    final name = 'q${_next++}';
    _claim(name, 'the builder');
    _values[name] = value;
    return '@$name';
  }

  void _claim(String name, String owner) {
    final folded = name.toLowerCase();
    final existing = _folded[folded];
    if (existing != null && existing != name) {
      throw ArgumentError.value(
        name,
        'parameters',
        'collides with "@$existing": SQL Server matches parameter names '
            'without regard to case, so the two would be one parameter. '
            'Rename the one $owner did not generate.',
      );
    }
    _folded[folded] = name;
    if (_values.length >= maximumParameters) {
      throw ArgumentError(
        'This statement would bind more than $maximumParameters parameters, '
        'which is SQL Server\'s limit for one statement. Narrow the filter, '
        'or send the values through a temporary table.',
      );
    }
  }

  /// Merges the parameters of a `raw` fragment.
  ///
  /// Throws [ArgumentError] if a name uses the generated shape, or if two
  /// fragments bind different values to the same name. Two fragments binding
  /// the *same* value to one name is allowed: reusing `@from` across a pair of
  /// date predicates is a reasonable thing to write.
  void merge(Map<String, Object?> parameters) {
    for (final entry in parameters.entries) {
      final name = entry.key.startsWith('@')
          ? entry.key.substring(1)
          : entry.key;
      if (reservedName.hasMatch(name)) {
        throw ArgumentError.value(
          entry.key,
          'parameters',
          'Parameter names matching @q<number> are reserved for the builder. '
              'Rename this one.',
        );
      }
      if (_values.containsKey(name) && _values[name] != entry.value) {
        throw ArgumentError.value(
          entry.key,
          'parameters',
          'Two raw fragments bind different values to "@$name".',
        );
      }
      if (!_values.containsKey(name)) _claim(name, 'the raw fragment');
      _values[name] = entry.value;
    }
  }

  /// The values bound so far.
  Map<String, Object?> get values => Map<String, Object?>.of(_values);
}
