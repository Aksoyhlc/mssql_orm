import 'dart:io';

import 'package:mssql_native/mssql_native.dart';

bool get liveEnabled => Platform.environment['MSSQL_NATIVE_LIVE'] == '1';

String? get liveSkip =>
    liveEnabled ? null : 'Set MSSQL_NATIVE_LIVE=1 with a reachable SQL Server.';

MssqlConnectionConfig liveConfig({
  MssqlDecimalMode decimalMode = MssqlDecimalMode.text,
}) => MssqlConnectionConfig(
  host: Platform.environment['MSSQL_NATIVE_HOST'] ?? '127.0.0.1',
  port: int.parse(Platform.environment['MSSQL_NATIVE_PORT'] ?? '1433'),
  database: Platform.environment['MSSQL_NATIVE_DB'] ?? 'mssql_native_test',
  username: Platform.environment['MSSQL_NATIVE_USER'] ?? 'sa',
  password: Platform.environment['MSSQL_NATIVE_PASSWORD'] ?? 'Mssql@Native2026',
  decimalMode: decimalMode,
  encryption: MssqlEncryption.off,
  defaultQueryTimeout: const Duration(seconds: 30),
);

Future<void> initializeLive() => MssqlRuntime.instance.initialize(
  bridgePath: Platform.environment['MSSQL_NATIVE_BRIDGE'],
  sybdbPath: Platform.environment['MSSQL_NATIVE_SYBDB'],
);

const String readerSchema = 'orm_reader_fixture';
const String repositorySchema = 'orm_repo_fixture';

List<String> _drops(String schema) => <String>[
  for (final name in <String>[
    'SelfRef',
    'CompositeChild',
    'CompositeParent',
    'Lines',
  ])
    "IF OBJECT_ID(N'[$schema].[$name]', N'U') IS NOT NULL DROP TABLE [$schema].[$name];",
  "IF OBJECT_ID(N'[$schema].[OpenOrders]', N'V') IS NOT NULL DROP VIEW [$schema].[OpenOrders];",
  for (final name in <String>[
    'Profiles',
    'Triggered',
    'TriggerOff',
    'NoKey',
    'Orders',
    'Customers',
  ])
    "IF OBJECT_ID(N'[$schema].[$name]', N'U') IS NOT NULL DROP TABLE [$schema].[$name];",
];

List<String> _creates(String schema) => <String>[
  'SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON; '
      'SET ANSI_WARNINGS ON; SET CONCAT_NULL_YIELDS_NULL ON; '
      'SET ARITHABORT ON; SET NUMERIC_ROUNDABORT OFF;',
  "IF SCHEMA_ID(N'$schema') IS NULL EXEC(N'CREATE SCHEMA [$schema]');",
  """
CREATE TABLE [$schema].[Customers] (
  [Id]   INT IDENTITY(1, 1) NOT NULL CONSTRAINT [PK_${schema}_Customers] PRIMARY KEY,
  [Name] NVARCHAR(100) NOT NULL,
  [Note] NVARCHAR(MAX) NULL
);
""",
  """
CREATE TABLE [$schema].[Orders] (
  [Id]         INT IDENTITY(10, 5) NOT NULL CONSTRAINT [PK_${schema}_Orders] PRIMARY KEY,
  [CustomerId] INT NOT NULL CONSTRAINT [FK_${schema}_Orders_Customers]
                 REFERENCES [$schema].[Customers] ([Id]),
  [Code]       VARCHAR(20) NOT NULL,
  [Total]      DECIMAL(18, 4) NOT NULL,
  [Discount]   DECIMAL(9, 2) NULL,
  [CreatedAt]  DATETIME2(3) NOT NULL CONSTRAINT [DF_${schema}_Orders_CreatedAt]
                 DEFAULT SYSUTCDATETIME(),
  [Precise]    DATETIME2(7) NULL,
  [OnlyTime]   TIME(3) NULL,
  [Offset]     DATETIMEOFFSET(3) NULL,
  [IsOpen]     BIT NOT NULL,
  [Guid]       UNIQUEIDENTIFIER NULL,
  [Payload]    VARBINARY(MAX) NULL,
  [OwnerName]  SYSNAME NULL,
  [NetTotal]   AS ([Total] - ISNULL([Discount], 0)),
  [Version]    ROWVERSION NOT NULL
);
""",
  """
CREATE UNIQUE INDEX [UX_${schema}_Orders_Customer_Open]
ON [$schema].[Orders] ([CustomerId]) WHERE [IsOpen] = 1;
""",
  """
CREATE UNIQUE INDEX [UX_${schema}_Orders_Code_Disabled]
ON [$schema].[Orders] ([Code]);
ALTER INDEX [UX_${schema}_Orders_Code_Disabled]
ON [$schema].[Orders] DISABLE;
""",
  """
CREATE TABLE [$schema].[Lines] (
  [Id]      INT IDENTITY(1, 1) NOT NULL CONSTRAINT [PK_${schema}_Lines] PRIMARY KEY,
  [OrderId] INT NOT NULL CONSTRAINT [FK_${schema}_Lines_Orders]
              REFERENCES [$schema].[Orders] ([Id]),
  [LineNo]  INT NOT NULL,
  [Qty]     INT NOT NULL
);
""",
  """
CREATE TABLE [$schema].[NoKey] ([A] INT NOT NULL, [B] NVARCHAR(50) NULL);
""",
  """
CREATE TABLE [$schema].[Profiles] (
  [Id]         INT IDENTITY(1, 1) NOT NULL CONSTRAINT [PK_${schema}_Profiles] PRIMARY KEY,
  [CustomerId] INT NOT NULL CONSTRAINT [FK_${schema}_Profiles_Customers]
                 REFERENCES [$schema].[Customers] ([Id]),
  [Bio]        NVARCHAR(200) NULL,
  CONSTRAINT [UQ_${schema}_Profiles_Customer] UNIQUE ([CustomerId])
);
""",
  """
CREATE TABLE [$schema].[Triggered] (
  [Id]   INT IDENTITY(1, 1) NOT NULL CONSTRAINT [PK_${schema}_Triggered] PRIMARY KEY,
  [Name] NVARCHAR(50) NOT NULL
);
""",
  """
CREATE TRIGGER [$schema].[TR_${schema}_Triggered] ON [$schema].[Triggered]
AFTER INSERT AS BEGIN SET NOCOUNT ON; END;
""",
  """
CREATE TABLE [$schema].[TriggerOff] (
  [Id]   INT IDENTITY(1, 1) NOT NULL CONSTRAINT [PK_${schema}_TriggerOff] PRIMARY KEY,
  [Name] NVARCHAR(50) NOT NULL
);
""",
  """
CREATE TRIGGER [$schema].[TR_${schema}_TriggerOff] ON [$schema].[TriggerOff]
AFTER INSERT AS BEGIN SET NOCOUNT ON; END;
""",
  "DISABLE TRIGGER [$schema].[TR_${schema}_TriggerOff] ON [$schema].[TriggerOff];",
  """
CREATE TABLE [$schema].[CompositeParent] (
  [TenantId] INT NOT NULL,
  [Code]     VARCHAR(10) NOT NULL,
  [Label]    NVARCHAR(50) NULL,
  CONSTRAINT [PK_${schema}_CompositeParent] PRIMARY KEY ([TenantId], [Code])
);
""",
  """
CREATE TABLE [$schema].[CompositeChild] (
  [Id]       INT IDENTITY(1, 1) NOT NULL CONSTRAINT [PK_${schema}_CompositeChild] PRIMARY KEY,
  [TenantId] INT NOT NULL,
  [Code]     VARCHAR(10) NOT NULL,
  CONSTRAINT [FK_${schema}_CompositeChild] FOREIGN KEY ([TenantId], [Code])
    REFERENCES [$schema].[CompositeParent] ([TenantId], [Code])
);
""",
  """
CREATE TABLE [$schema].[SelfRef] (
  [Id]        INT IDENTITY(1, 1) NOT NULL CONSTRAINT [PK_${schema}_SelfRef] PRIMARY KEY,
  [ManagerId] INT NULL CONSTRAINT [FK_${schema}_SelfRef] REFERENCES [$schema].[SelfRef] ([Id])
);
""",
  """
CREATE VIEW [$schema].[OpenOrders] AS
SELECT [Id], [Code], [Total] FROM [$schema].[Orders] WHERE [IsOpen] = 1;
""",
];

Future<void> createFixtureSchema(
  MssqlConnection connection,
  String schema,
) async {
  await dropFixtureSchema(connection, schema);
  for (final statement in _creates(schema)) {
    await connection.execute(statement);
  }
}

Future<void> dropFixtureSchema(
  MssqlConnection connection,
  String schema,
) async {
  for (final statement in _drops(schema)) {
    await connection.execute(statement);
  }
}

