import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

/// What a column belongs to, as an identity rather than as a piece of text.
///
/// Writing a fixed qualifier such as `[dbo].[Orders].[CustomerId]` into every
/// column breaks once the query aliases the table or points the same generated
/// code at another schema: the qualifier names the source it was generated
/// from, not the one in the statement.
///
/// A column therefore carries which source it belongs to, and the alias it is
/// written with is resolved during compilation from the scope that knows what
/// that source is called in this statement.
@immutable
class MssqlSourceRef {
  const MssqlSourceRef({required this.table, this.schema});

  /// A source that is not a table: a subquery, a CTE, a derived table.
  ///
  /// It has no schema, and its name is the alias the query gave it.
  const MssqlSourceRef.named(this.table) : schema = null;

  final String? schema;
  final String table;

  /// This source under another schema or name.
  ///
  /// What `at(schema:, table:)` produces. Rebinding a query's root has to
  /// rebind its columns too, and a column that held a fixed qualifier could
  /// not be rebound at all.
  MssqlSourceRef at({String? schema, String? table}) =>
      MssqlSourceRef(schema: schema ?? this.schema, table: table ?? this.table);

  /// The parts to quote when the source appears unaliased.
  List<String> get parts =>
      schema == null ? <String>[table] : <String>[schema!, table];

  /// `[dbo].[Orders]`, for a query that gave the source no alias.
  String get quoted => MssqlSql.quoteMultipartIdentifier(parts);

  /// `dbo.Orders`, for a message.
  String get qualifiedName => schema == null ? table : '$schema.$table';

  @override
  bool operator ==(Object other) =>
      other is MssqlSourceRef && other.table == table && other.schema == schema;

  @override
  int get hashCode => Object.hash(schema, table);

  @override
  String toString() => 'MssqlSourceRef($qualifiedName)';
}

/// What each source is called inside one statement.
///
/// Filled in as a query compiles its `FROM` and joins, and read by every column
/// that names a source. An unregistered source resolves to its own qualified
/// name, which keeps the ordinary unaliased query and a bare `compile()` of a
/// fragment working.
class MssqlSourceScope {
  final Map<MssqlSourceRef, String> _aliases = <MssqlSourceRef, String>{};

  /// Records that [source] appears in this statement as [alias].
  ///
  /// [alias] is the already-quoted identifier the query wrote.
  void bind(MssqlSourceRef source, String alias) => _aliases[source] = alias;

  /// Forgets a binding, for a subquery whose scope has closed.
  void unbind(MssqlSourceRef source) => _aliases.remove(source);

  /// How to qualify a column of [source] here.
  String qualifierFor(MssqlSourceRef source) =>
      _aliases[source] ?? source.quoted;

  /// Whether [source] is one of the statement's own sources.
  bool contains(MssqlSourceRef source) => _aliases.containsKey(source);
}
