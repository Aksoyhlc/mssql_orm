-- name: categoryTrend
-- describe: manual
-- read_only: true
-- returns: list
-- param: rootId int
-- param: since datetime2
-- column: Month date not null
-- column: Category nvarchar not null
-- column: Revenue decimal(18,2) not null
-- column: Lines int not null
--
-- Revenue by month for the category subtree under @rootId, from @since.
-- Soft-deleted orders are excluded here, matching the Dart builder example.
-- DATEADD/DATEDIFF month buckets, not DATE_BUCKET: this file must compile
-- on 2012. The Dart side shows the 2022 DATE_BUCKET capability gate.
WITH tree AS (
    SELECT c.Id, CAST(0 AS int) AS Depth
    FROM dbo.Categories AS c
    WHERE c.Id = @rootId
    UNION ALL
    SELECT c.Id, tree.Depth + 1
    FROM dbo.Categories AS c
    INNER JOIN tree ON tree.Id = c.ParentId
    WHERE tree.Depth < 20
)
SELECT
    CAST(DATEADD(month, DATEDIFF(month, 0, o.PlacedAt), 0) AS date) AS [Month],
    cat.Name AS [Category],
    SUM(l.LineTotal) AS [Revenue],
    COUNT(l.Id) AS [Lines]
FROM dbo.Orders AS o
INNER JOIN dbo.OrderLines AS l ON l.OrderId = o.Id
INNER JOIN dbo.Products AS p ON p.Id = l.ProductId
INNER JOIN tree ON tree.Id = p.CategoryId
INNER JOIN dbo.Categories AS cat ON cat.Id = p.CategoryId
WHERE o.DeletedAt IS NULL
  AND o.Status <> N'cancelled'
  AND o.PlacedAt >= @since
GROUP BY
    CAST(DATEADD(month, DATEDIFF(month, 0, o.PlacedAt), 0) AS date),
    cat.Name
ORDER BY [Month] DESC, [Revenue] DESC;
