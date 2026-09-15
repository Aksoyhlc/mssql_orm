import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';

import 'runtime/exception.dart';

/// What the target SQL Server can do, and therefore which SQL a statement is
/// compiled to.
///
/// Not an enum of version names. Two things decide whether a clause is
/// available, and only one is the product version: SQL Server gates
/// `OFFSET … FETCH`, `DATEFROMPARTS` and the rest of the 2012 language on the
/// database's compatibility level as well, so a 2022 server hosting a database
/// left at level 100 rejects them exactly as a 2008 server would. A descriptor
/// carrying both numbers can answer that; a name cannot.
///
/// [sql2008] and [sql2012] remain as the two shapes a caller compiles for
/// without a server in reach.
@immutable
class MssqlDialect {
  const MssqlDialect._(this.majorVersion, this.compatibilityLevel);

  /// A descriptor for a server whose numbers are both known.
  ///
  /// Omitting [compatibilityLevel] assumes the level that major version ships
  /// as its default. A database restored from an older server keeps its old
  /// level, so pass the real number when it is known.
  factory MssqlDialect.forVersion({
    required int majorVersion,
    int? compatibilityLevel,
  }) => MssqlDialect._(
    majorVersion,
    compatibilityLevel ?? _defaultCompatibilityLevel(majorVersion),
  );

  /// SQL Server 2008 and 2008 R2: paging through a `ROW_NUMBER()` subquery.
  static const MssqlDialect sql2008 = MssqlDialect._(10, 100);

  /// SQL Server 2012: paging through `OFFSET … FETCH NEXT`.
  ///
  /// The default a statement compiles for. Every server newer than 2012
  /// accepts what this emits, so the name is the floor rather than the
  /// target; a feature that needs more than 2012 asks [majorVersion]
  /// directly.
  static const MssqlDialect sql2012 = MssqlDialect._(11, 110);

  /// The product version's major number: 10 is 2008, 11 is 2012, 16 is 2022.
  final int majorVersion;

  /// The database's `compatibility_level`: 100 is 2008, 110 is 2012, 160 is
  /// 2022.
  final int compatibilityLevel;

  /// `OFFSET … FETCH NEXT`, which is also what makes a page one statement
  /// rather than three.
  bool get supportsOffsetFetch => _atLeast(11, 110);

  /// `DATEFROMPARTS`, `EOMONTH`, `TRY_CONVERT` and the rest of the functions
  /// SQL Server 2012 added.
  ///
  /// There is no equivalent for 2008 worth emitting silently: the closest
  /// rewrites change either the type or the sargability of the expression, so
  /// a compiler that substituted one would be answering a different question.
  /// The 2012 functions are therefore refused on 2008, not translated.
  bool get supportsDatePartFunctions => _atLeast(11, 110);

  /// `ROWS`/`RANGE` window frames and the ordered window aggregates that need
  /// them. 2008 has `ROW_NUMBER`, `RANK` and `OVER (PARTITION BY …)` but no
  /// frame clause.
  bool get supportsWindowFrames => _atLeast(11, 110);

  /// `LAG`, `LEAD`, `FIRST_VALUE` and `LAST_VALUE`: the window functions that
  /// read another row of the same partition, added in SQL Server 2012.
  ///
  /// Separate from [supportsWindowFrames] although both arrived together,
  /// because the two are refused with different advice. A frame can usually
  /// be dropped — the default frame is what the caller meant anyway — while
  /// there is no rewrite for `LAG` short of joining the table to itself on a
  /// row number, which is a different query.
  bool get supportsWindowOffsetFunctions => _atLeast(11, 110);

  /// `STRING_AGG`, added in SQL Server 2017.
  bool get supportsStringAgg => _atLeast(14, 140);

  /// `DATE_BUCKET`, added in SQL Server 2022.
  ///
  /// A bucket can be expressed on older servers with `DATEADD`/`DATEDIFF`
  /// arithmetic, which is a different expression rather than a translation of
  /// this one; whichever a query uses, it uses the same descriptor for the
  /// `SELECT` and the `GROUP BY` so the two cannot drift apart.
  bool get supportsDateBucket => _atLeast(16, 160);

  /// Both numbers in a sentence, for an error a user can act on.
  String get description =>
      'SQL Server major version $majorVersion at database compatibility '
      'level $compatibilityLevel';

  /// Throws [MssqlCapabilityException] unless [available] holds.
  ///
  /// The one place a capability turns into a refusal, so every message names
  /// the feature, what it needs and what was found instead.
  void require(
    // ignore: avoid_positional_boolean_parameters
    bool available, {
    required String feature,
    required String requires,
  }) {
    if (available) return;
    throw MssqlCapabilityException(
      feature: feature,
      requires: requires,
      found: description,
    );
  }

  /// The descriptor for [info], read from its product version.
  ///
  /// [compatibilityLevel] comes from `sys.databases`, which is a separate
  /// query; omitted, the product version's own default level is assumed.
  static MssqlDialect forServer(
    MssqlServerInfo info, {
    int? compatibilityLevel,
  }) => forProductVersion(
    info.productVersion,
    compatibilityLevel: compatibilityLevel,
  );

  /// The descriptor for a raw `SERVERPROPERTY('ProductVersion')` string.
  ///
  /// Separate from [forServer] because a repository inside a transaction
  /// cannot call `MssqlConnection.serverInfo()` — the connection is leased by
  /// the transaction — and so reads the property through its own session.
  ///
  /// A version this cannot parse yields [sql2012]: guessing downward would
  /// silently hand a modern server the legacy paging syntax, while guessing
  /// upward at worst produces a clear error naming the feature.
  static MssqlDialect forProductVersion(
    String productVersion, {
    int? compatibilityLevel,
  }) {
    final major = RegExp(r'^\d+').firstMatch(productVersion.trim());
    final value = major == null ? null : int.tryParse(major.group(0)!);
    if (value == null) {
      return compatibilityLevel == null
          ? sql2012
          : MssqlDialect._(11, compatibilityLevel);
    }
    return MssqlDialect.forVersion(
      majorVersion: value,
      compatibilityLevel: compatibilityLevel,
    );
  }

  bool _atLeast(int major, int level) =>
      majorVersion >= major && compatibilityLevel >= level;

  /// The compatibility level a database created on [majorVersion] carries.
  ///
  /// SQL Server's levels run ten to a release from 2008 onwards, and every
  /// release since 2016 has kept 100 as its floor.
  static int _defaultCompatibilityLevel(int majorVersion) =>
      switch (majorVersion) {
        <= 10 => 100,
        11 => 110,
        12 => 120,
        13 => 130,
        14 => 140,
        15 => 150,
        16 => 160,
        _ => 170,
      };

  @override
  bool operator ==(Object other) =>
      other is MssqlDialect &&
      other.majorVersion == majorVersion &&
      other.compatibilityLevel == compatibilityLevel;

  @override
  int get hashCode => Object.hash(majorVersion, compatibilityLevel);

  @override
  String toString() => 'MssqlDialect($majorVersion, $compatibilityLevel)';
}
