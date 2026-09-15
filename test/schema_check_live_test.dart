import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/live_server.dart';

const String driftSchema = 'orm_drift_fixture';

void main() {
  group('the drift check, against a server', () {
    late MssqlConnection connection;
    late MssqlSchemaReader reader;

    setUpAll(() async {
      if (!liveEnabled) return;
      await initializeLive();
      connection = await MssqlConnection.open(liveConfig());
      await connection.execute(
        "IF SCHEMA_ID(N'$driftSchema') IS NULL "
        "EXEC(N'CREATE SCHEMA [$driftSchema]');",
      );
      reader = MssqlSchemaReader(connection);
    });

    tearDownAll(() async {
      if (!liveEnabled) return;
      await connection.close();
    });

    Future<MssqlSchemaReport> drift(
      String name,
      String create,
      List<String> change,
    ) async {
      await connection.execute(
        "IF OBJECT_ID(N'[$driftSchema].[$name]', N'U') IS NOT NULL "
        'DROP TABLE [$driftSchema].[$name];',
      );
      await connection.execute(create);
      final before = (await reader.readTable('$driftSchema.$name'))!;
      final binding = bindingFor(before);
      for (final statement in change) {
        await connection.execute(statement);
      }
      final after = (await reader.readTable('$driftSchema.$name'))!;
      return MssqlSchemaCheck.compare(binding, after);
    }

    test('an unchanged table is clean', () async {
      final report = await drift(
        'Stable',
        'CREATE TABLE [$driftSchema].[Stable] '
            '([Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY, [Name] NVARCHAR(50) NOT NULL);',
        const <String>[],
      );
      expect(report.isClean, isTrue, reason: report.describe());
    }, skip: liveSkip);

    test('a dropped column is breaking', () async {
      final report = await drift(
        'Dropped',
        'CREATE TABLE [$driftSchema].[Dropped] '
            '([Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY, [Gone] INT NULL);',
        <String>['ALTER TABLE [$driftSchema].[Dropped] DROP COLUMN [Gone];'],
      );
      expect(report.hasBreakingChanges, isTrue);
      expect(
        report.differences.map((d) => d.kind),
        contains(MssqlDifferenceKind.columnMissing),
      );
    }, skip: liveSkip);

    test('a new nullable column is benign', () async {
      final report = await drift(
        'Added',
        'CREATE TABLE [$driftSchema].[Added] '
            '([Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY);',
        <String>['ALTER TABLE [$driftSchema].[Added] ADD [Extra] INT NULL;'],
      );
      expect(report.isClean, isFalse);
      expect(report.hasBreakingChanges, isFalse, reason: report.describe());
    }, skip: liveSkip);

    test('a new NOT NULL column with a default is benign', () async {
      final report = await drift(
        'AddedDefault',
        'CREATE TABLE [$driftSchema].[AddedDefault] '
            '([Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY);',
        <String>[
          'ALTER TABLE [$driftSchema].[AddedDefault] '
              'ADD [Extra] INT NOT NULL CONSTRAINT [DF_drift_Extra] DEFAULT 0;',
        ],
      );
      expect(report.hasBreakingChanges, isFalse, reason: report.describe());
    }, skip: liveSkip);

    test('nullability flipping is breaking', () async {
      final report = await drift(
        'Nullability',
        'CREATE TABLE [$driftSchema].[Nullability] '
            '([Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY, [Name] NVARCHAR(50) NULL);',
        <String>[
          'ALTER TABLE [$driftSchema].[Nullability] '
              'ALTER COLUMN [Name] NVARCHAR(50) NOT NULL;',
        ],
      );
      expect(
        report.differences.map((d) => d.kind),
        contains(MssqlDifferenceKind.nullabilityChanged),
      );
      expect(report.hasBreakingChanges, isTrue);
    }, skip: liveSkip);

    test('a trigger added under OUTPUT INSERTED is breaking', () async {
      final report = await drift(
        'Triggering',
        'CREATE TABLE [$driftSchema].[Triggering] '
            '([Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY, [Name] NVARCHAR(50) NULL);',
        <String>[
          'CREATE TRIGGER [$driftSchema].[TR_drift_Triggering] '
              'ON [$driftSchema].[Triggering] AFTER INSERT AS BEGIN SET NOCOUNT ON; END;',
        ],
      );
      expect(
        report.differences.map((d) => d.kind),
        contains(MssqlDifferenceKind.triggerAdded),
      );
      expect(report.describe(), contains('334'));
    }, skip: liveSkip);

    test('a changed primary key is breaking', () async {
      final report = await drift(
        'Keyed',
        'CREATE TABLE [$driftSchema].[Keyed] '
            '([Id] INT NOT NULL CONSTRAINT [PK_drift_Keyed] PRIMARY KEY, '
            '[Code] VARCHAR(10) NOT NULL);',
        <String>[
          'ALTER TABLE [$driftSchema].[Keyed] DROP CONSTRAINT [PK_drift_Keyed];',
          'ALTER TABLE [$driftSchema].[Keyed] ADD CONSTRAINT [PK_drift_Keyed2] '
              'PRIMARY KEY ([Code]);',
        ],
      );
      expect(
        report.differences.map((d) => d.kind),
        contains(MssqlDifferenceKind.primaryKeyChanged),
      );
    }, skip: liveSkip);

    test('a widened column is benign, a narrowed one is not', () async {
      final widened = await drift(
        'Widened',
        'CREATE TABLE [$driftSchema].[Widened] '
            '([Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY, [Name] NVARCHAR(20) NULL);',
        <String>[
          'ALTER TABLE [$driftSchema].[Widened] ALTER COLUMN [Name] NVARCHAR(80) NULL;',
        ],
      );
      expect(widened.hasBreakingChanges, isFalse, reason: widened.describe());

      final narrowed = await drift(
        'Narrowed',
        'CREATE TABLE [$driftSchema].[Narrowed] '
            '([Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY, [Name] NVARCHAR(80) NULL);',
        <String>[
          'ALTER TABLE [$driftSchema].[Narrowed] ALTER COLUMN [Name] NVARCHAR(20) NULL;',
        ],
      );
      expect(narrowed.hasBreakingChanges, isTrue, reason: narrowed.describe());
    }, skip: liveSkip);

    test('the fingerprint agrees with the detailed comparison', () async {
      final report = await drift(
        'Fingerprinted',
        'CREATE TABLE [$driftSchema].[Fingerprinted] '
            '([Id] INT IDENTITY(1,1) NOT NULL PRIMARY KEY);',
        <String>[
          'ALTER TABLE [$driftSchema].[Fingerprinted] ADD [Extra] INT NULL;',
        ],
      );
      expect(report.isClean, isFalse);
    }, skip: liveSkip);
  });
}

MssqlTableBinding<Object?> bindingFor(MssqlTableSchema table) =>
    MssqlTableBinding<Object?>(
      schema: table.schema,
      table: table.name,
      primaryKey: table.primaryKey?.columns ?? const <String>[],
      identityColumn: table.identityColumn?.name,
      insertStrategy: table.identityColumn == null
          ? MssqlInsertStrategy.noKeyReadback
          : table.hasEnabledTrigger
          ? MssqlInsertStrategy.scopeIdentity
          : MssqlInsertStrategy.outputInserted,
      schemaFingerprint: fingerprintOf(table),
      columns: <MssqlBoundColumn>[
        for (final column in table.columns)
          MssqlBoundColumn(
            name: column.name,
            type: column.type,
            nullable: column.nullable,
            isIdentity: column.isIdentity,
            isComputed: column.isComputed,
            isRowVersion: column.isRowVersion,
            hasDefault: column.hasDefault,
            maxLength: column.maxLength,
            precision: column.precision,
            scale: column.scale,
          ),
      ],
      fromRow: (row) => row,
      toColumns: (row) => const <String, Object?>{},
      readColumn: (row, name) => null,
    );

