import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

import 'support/fake_driver.dart';

MssqlProjectedQuery<int> projected(
  FakeConnection session,
  MssqlQueryOptions options,
) => MssqlProjectedQuery<int>(
  session: session,
  dialect: MssqlDialect.sql2012,
  projection: MssqlProjection<int>(
    name: 'ids',
    columns: <MssqlProjectionColumn>[MssqlProjectionColumn('Id', Col('Id'))],
    map: (row) => (row['Id']! as num).toInt(),
  ),
  options: options,
  timeout: options.timeout,
  build: (columns) => MssqlQuery.from(
    'dbo.Items',
  ).select(columns).orderBy(<MssqlOrder>[Col('Id').asc()]),
);

void expectOptions(DriverCall call, MssqlQueryOptions options) {
  expect(call['options'], same(options));
  expect(call['cancellationToken'], same(options.cancellationToken));
  expect(call['timeout'], options.timeout);
}

void main() {
  late MssqlCancellationToken token;
  late MssqlQueryOptions options;

  setUp(() {
    token = MssqlCancellationToken();
    options = MssqlQueryOptions(
      timeout: const Duration(seconds: 9),
      cancellationToken: token,
      queryName: 'items.projected',
    );
  });

  test('count forwards the complete query options', () async {
    final fake = FakeConnection()
      ..replies.add(<Map<String, Object?>>[
        <String, Object?>{'': 2},
      ]);

    expect(await projected(fake, options).count(), 2);

    expectOptions(fake.onlyCall, options);
  });

  test('offset page forwards options to page and total reads', () async {
    final fake = FakeConnection()
      ..replies.add(<Map<String, Object?>>[
        <String, Object?>{'Id': 1},
      ])
      ..replies.add(<Map<String, Object?>>[
        <String, Object?>{'': 1},
      ]);

    await projected(fake, options).page(size: 2, total: true);

    expect(fake.calls, hasLength(2));
    for (final call in fake.calls) {
      expectOptions(call, options);
    }
  });

  test('cursor page forwards the complete query options', () async {
    final fake = FakeConnection()
      ..replies.add(<Map<String, Object?>>[
        <String, Object?>{'Id': 1},
      ]);

    await projected(fake, options).cursorPage(size: 2);

    expectOptions(fake.onlyCall, options);
  });

  test('chunk forwards the complete query options', () async {
    final fake = FakeConnection()
      ..replies.add(<Map<String, Object?>>[
        <String, Object?>{'Id': 1},
      ]);

    await projected(fake, options).chunk(size: 2).toList();

    expectOptions(fake.onlyCall, options);
  });
}
