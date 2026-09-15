// The sales example's application types come from the generator, not from
// a hand-written binding. `class_names` maps dbo.Orders → Order so the
// owned row is `OrderRow` rather than `OrdersRow`.
//
// Snapshot: example/tool/mssql_schema.json
// Regenerator: mssql_orm_dev/tool/generate_sales_example.dart
library;

export 'generated/database.g.dart';
export 'generated/generated.dart';
