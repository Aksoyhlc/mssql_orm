// GENERATED — do not edit. Rewritten on every run.
//
// Generator: mssql_orm_dev 0.1.1
// API contract: 2
//
// Typed from SQL Server's own description of each query, by
// sp_describe_first_result_set, or from -- describe: manual.
// Manual shapes are not a server-verified static analysis.

import 'package:meta/meta.dart';
import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'database.g.dart';

/// One row of categoryTrend.
///
/// Source: category_trend.sql
@immutable
class CategoryTrendRow {
  const CategoryTrendRow({
    required this.month,
    required this.category,
    required this.revenue,
    required this.lines,
  });

  final DateTime month;
  final String category;

  /// Exact, generated for MssqlDecimalMode.exact. The connection must use the same mode.
  final MssqlDecimal revenue;
  final int lines;

  static const List<String> columnOrder = <String>[
    'Month',
    'Category',
    'Revenue',
    'Lines',
  ];
  factory CategoryTrendRow.fromRow(MssqlRow row) {
    row.assertOrdinalNames(columnOrder);
    return CategoryTrendRow(
      month:
          (mssqlRequireNonNull(
                    row.at(0),
                    source: 'category_trend.sql',
                    column: 'Month',
                  )
                  as MssqlDateTimeValue)
              .toDateTime(),
      category:
          mssqlRequireNonNull(
                row.at(1),
                source: 'category_trend.sql',
                column: 'Category',
              )
              as String,
      revenue:
          mssqlRequireNonNull(
                row.at(2),
                source: 'category_trend.sql',
                column: 'Revenue',
              )
              as MssqlDecimal,
      lines:
          (mssqlRequireNonNull(
                    row.at(3),
                    source: 'category_trend.sql',
                    column: 'Lines',
                  )
                  as num)
              .toInt(),
    );
  }
}

/// Typed methods for every `.sql` file, on the generated
/// database. Call `db.reports.methodName(...)`.
///
/// Retry is never unless the file declared `-- read_only: true`.
/// Returning rows does not make a statement safe to repeat.
class AppDatabaseReports {
  AppDatabaseReports(this._db);

  final AppDatabase _db;

  /// category_trend.sql
  ///
  /// Shape declared by `-- describe: manual`. SQL Server
  /// has not verified this query.
  ///
  /// `-- read_only: true`: lost connections may retry.
  Future<List<CategoryTrendRow>> categoryTrend({
    required int rootId,
    required DateTime since,
    MssqlQueryOptions options = MssqlQueryOptions.defaults,
    Duration? timeout,
    MssqlCancellationToken? cancellationToken,
  }) async {
    final parameters = <String, Object?>{
      'rootId': MssqlValue.int32(rootId),
      'since': MssqlValue.dateTime2(since, scale: 7),
    };
    final run = options.merge(
      retry: MssqlRetryPolicy.idempotentRead,
      queryName: 'reports.categoryTrend',
    );
    final rows = await _db.session.queryTypedRows(
      'WITH tree AS (\n    SELECT c.Id, CAST(0 AS int) AS Depth\n    FROM dbo.Categories AS c\n    WHERE c.Id = @rootId\n    UNION ALL\n    SELECT c.Id, tree.Depth + 1\n    FROM dbo.Categories AS c\n    INNER JOIN tree ON tree.Id = c.ParentId\n    WHERE tree.Depth < 20\n)\nSELECT\n    CAST(DATEADD(month, DATEDIFF(month, 0, o.PlacedAt), 0) AS date) AS [Month],\n    cat.Name AS [Category],\n    SUM(l.LineTotal) AS [Revenue],\n    COUNT(l.Id) AS [Lines]\nFROM dbo.Orders AS o\nINNER JOIN dbo.OrderLines AS l ON l.OrderId = o.Id\nINNER JOIN dbo.Products AS p ON p.Id = l.ProductId\nINNER JOIN tree ON tree.Id = p.CategoryId\nINNER JOIN dbo.Categories AS cat ON cat.Id = p.CategoryId\nWHERE o.DeletedAt IS NULL\n  AND o.Status <> N\'cancelled\'\n  AND o.PlacedAt >= @since\nGROUP BY\n    CAST(DATEADD(month, DATEDIFF(month, 0, o.PlacedAt), 0) AS date),\n    cat.Name\nORDER BY [Month] DESC, [Revenue] DESC;',
      parameters: parameters,
      options: run,
      timeout: timeout,
      cancellationToken: cancellationToken,
    );
    return rows.map(CategoryTrendRow.fromRow).toList(growable: false);
  }
}
