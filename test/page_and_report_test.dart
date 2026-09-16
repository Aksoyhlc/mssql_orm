import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

MssqlBoundColumn column(
  MssqlType type, {
  int maxLength = 0,
  int precision = 18,
  int scale = 0,
  bool identity = false,
  bool computed = false,
  bool rowVersion = false,
  bool readOnly = false,
  bool nullable = false,
}) => MssqlBoundColumn(
  name: 'C',
  type: type,
  maxLength: maxLength,
  precision: precision,
  scale: scale,
  isIdentity: identity,
  isComputed: computed,
  isRowVersion: rowVersion,
  isReadOnly: readOnly,
  nullable: nullable,
);

MssqlSchemaDifference difference({
  String table = 'dbo.Orders',
  String? col,
  MssqlDifferenceKind kind = MssqlDifferenceKind.columnMissing,
  MssqlDifferenceSeverity severity = MssqlDifferenceSeverity.breaking,
  String expected = 'a column',
  String actual = 'nothing',
  String remedy = 'Regenerate.',
}) => MssqlSchemaDifference(
  table: table,
  column: col,
  kind: kind,
  severity: severity,
  expected: expected,
  actual: actual,
  remedy: remedy,
);

void main() {
  group('a page', () {
    MssqlPage<int> page({
      List<int> rows = const <int>[1, 2],
      int offset = 0,
      int requested = 2,
      bool hasMore = false,
      int? total,
    }) => MssqlPage<int>(
      rows: rows,
      offset: offset,
      requestedRows: requested,
      hasMore: hasMore,
      total: total,
    );

    test('answers isEmpty and isNotEmpty consistently', () {
      expect(page().isEmpty, isFalse);
      expect(page().isNotEmpty, isTrue);
      expect(page(rows: const <int>[]).isEmpty, isTrue);
      expect(page(rows: const <int>[]).isNotEmpty, isFalse);
    });

    test('cannot be modified through the list it hands out', () {
      expect(() => page().rows.add(3), throwsUnsupportedError);
    });

    test('keeps requestedRows apart from how many came back', () {
      final last = page(rows: const <int>[9], offset: 20, requested: 10);
      expect(last.rows, hasLength(1));
      expect(last.requestedRows, 10);
      expect(last.hasMore, isFalse);
    });

    test('total is null unless it was asked for', () {
      expect(page().total, isNull);
      expect(page(total: 57).total, 57);
    });

    test('says how many rows, where, and out of how many', () {
      expect(page().toString(), 'MssqlPage(2 rows at 0)');
      expect(
        page(offset: 40, total: 57).toString(),
        'MssqlPage(2 rows at 40 of 57)',
      );
      expect(page(rows: const <int>[]).toString(), 'MssqlPage(0 rows at 0)');
    });
  });

  group('writable', () {
    test('an ordinary column is', () {
      expect(column(MssqlType.int32).writable, isTrue);
    });

    test('is false for every column the server owns', () {
      expect(column(MssqlType.int32, identity: true).writable, isFalse);
      expect(column(MssqlType.int32, computed: true).writable, isFalse);
      expect(column(MssqlType.binary, rowVersion: true).writable, isFalse);
    });

    test('is false for a column the application was told not to write', () {
      expect(column(MssqlType.dateTime2, readOnly: true).writable, isFalse);
    });
  });

  group('a typed null', () {
    test('carries the column type, because a bare null cannot', () {
      expect(column(MssqlType.int32).nullValue.type, MssqlType.int32);
      expect(column(MssqlType.bit).nullValue.value, isNull);
    });

    test('carries precision and scale for a decimal', () {
      final value = column(MssqlType.decimal, precision: 9, scale: 4).nullValue;
      expect(value.precision, 9);
      expect(value.scale, 4);
    });

    test('halves max_length for an n-type, which counts bytes', () {
      expect(column(MssqlType.nvarchar, maxLength: 100).nullValue.size, 50);
      expect(column(MssqlType.varchar, maxLength: 50).nullValue.size, 50);
    });

    test('a max column declares no size rather than -1', () {
      expect(column(MssqlType.nvarchar, maxLength: -1).nullValue.size, 0);
      expect(column(MssqlType.varbinary, maxLength: -1).nullValue.size, 0);
    });

    test('a fixed-width type never declares a zero size', () {
      expect(column(MssqlType.char, maxLength: 0).nullValue.size, 1);
      expect(column(MssqlType.nchar, maxLength: 0).nullValue.size, 1);
      expect(column(MssqlType.binary, maxLength: 0).nullValue.size, 1);
    });

    test('bind types a null, and a value too', () {
      final c = column(MssqlType.int32, nullable: true);
      expect(c.bind(null).value, isNull);
      final bound = c.bind(7);
      expect(bound.value, 7);
      expect(bound.type, MssqlType.int32);
    });
  });

  group('a report reads like something a person can act on', () {
    test('a clean one says so in one line', () {
      final report = MssqlSchemaReport(const <MssqlSchemaDifference>[]);
      expect(report.isClean, isTrue);
      expect(report.hasBreakingChanges, isFalse);
      expect(report.describe().trim(), 'Generated code matches the database.');
    });

    test('counts the differences and the breaking ones separately', () {
      final report = MssqlSchemaReport(<MssqlSchemaDifference>[
        difference(),
        difference(
          kind: MssqlDifferenceKind.columnAdded,
          severity: MssqlDifferenceSeverity.benign,
        ),
      ]);
      expect(report.differences, hasLength(2));
      expect(report.breaking, hasLength(1));
      expect(report.hasBreakingChanges, isTrue);
      expect(report.describe(), contains('2 difference(s)'));
      expect(report.describe(), contains('1 of them breaking'));
    });

    test('a benign difference alone is not clean, and does not break', () {
      final report = MssqlSchemaReport(<MssqlSchemaDifference>[
        difference(severity: MssqlDifferenceSeverity.benign),
      ]);
      expect(report.isClean, isFalse);
      expect(report.hasBreakingChanges, isFalse);
    });

    test('names the table, the column, the kind and the remedy', () {
      final text = difference(
        col: 'Total',
        kind: MssqlDifferenceKind.typeChanged,
        expected: 'decimal',
        actual: 'nvarchar',
        remedy: 'Regenerate and review.',
      ).describe();
      expect(text, contains('dbo.Orders.Total'));
      expect(text, contains('typeChanged'));
      expect(text, contains('expected decimal'));
      expect(text, contains('found nvarchar'));
      expect(text, contains('Regenerate and review.'));
    });

    test('a table-level difference names no column', () {
      expect(difference().describe(), contains('dbo.Orders:'));
      expect(difference().describe(), isNot(contains('dbo.Orders.')));
    });

    test('the severity is legible at the start of the line', () {
      final breaking = difference().describe();
      final benign = difference(
        severity: MssqlDifferenceSeverity.benign,
      ).describe();
      expect(breaking, startsWith('breaking'));
      expect(benign, startsWith('benign'));
      expect(breaking.indexOf('dbo.Orders'), benign.indexOf('dbo.Orders'));
    });

    test('every difference reaches the summary', () {
      final report = MssqlSchemaReport(<MssqlSchemaDifference>[
        difference(table: 'dbo.Orders'),
        difference(table: 'dbo.Customers'),
        difference(table: 'dbo.Items'),
      ]);
      final text = report.describe();
      for (final table in <String>['Orders', 'Customers', 'Items']) {
        expect(text, contains(table));
      }
    });

    test('toString is the same sentence, so a log line is readable', () {
      final one = difference();
      expect(one.toString(), contains(one.describe()));
    });

    test('a report cannot be modified after it is made', () {
      final report = MssqlSchemaReport(<MssqlSchemaDifference>[difference()]);
      expect(
        () => report.differences.add(difference()),
        throwsUnsupportedError,
      );
    });
  });
}
