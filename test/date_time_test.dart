import 'package:mssql_native/mssql_native.dart';
import 'package:mssql_orm/orm.dart';
import 'package:test/test.dart';

MssqlDateTimeValue value({
  int year = 2026,
  int month = 9,
  int day = 7,
  int hour = 0,
  int minute = 0,
  int second = 0,
  int nanosecond = 0,
  int offset = 0,
}) => MssqlDateTimeValue(
  year: year,
  month: month,
  day: day,
  hour: hour,
  minute: minute,
  second: second,
  nanosecond: nanosecond,
  timezoneOffsetMinutes: offset,
);

void main() {
  group('toDateTime', () {
    test('carries the whole value down to microseconds', () {
      final d = value(
        hour: 13,
        minute: 45,
        second: 7,
        nanosecond: 123456000,
      ).toDateTime();
      expect(d.year, 2026);
      expect(d.month, 9);
      expect(d.day, 7);
      expect(d.hour, 13);
      expect(d.minute, 45);
      expect(d.second, 7);
      expect(d.millisecond, 123);
      expect(d.microsecond, 456);
    });

    test('utc is asked for, not guessed', () {
      expect(value().toDateTime().isUtc, isFalse);
      expect(value().toDateTime(utc: true).isUtc, isTrue);
    });

    test('a scale-7 value refuses rather than rounding', () {
      expect(
        () => value(nanosecond: 1234567 * 100).toDateTime(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('microsecond'),
          ),
        ),
      );
    });

    test('a scale-6 value converts', () {
      expect(value(nanosecond: 999999000).toDateTime().microsecond, 999);
    });

    test('a non-zero offset refuses, because DateTime cannot carry one', () {
      expect(
        () => value(offset: 180).toDateTime(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('offset'),
          ),
        ),
      );
    });
  });

  group('toDuration', () {
    test('a time is the offset from the start of the day', () {
      final d = value(hour: 13, minute: 45, second: 7).toDuration();
      expect(d, const Duration(hours: 13, minutes: 45, seconds: 7));
    });

    test('microseconds survive', () {
      expect(value(nanosecond: 123456000).toDuration().inMicroseconds, 123456);
    });

    test('a scale-7 value refuses', () {
      expect(
        () => value(nanosecond: 1234567 * 100).toDuration(),
        throwsArgumentError,
      );
    });

    test('midnight is zero, not a date', () {
      expect(value().toDuration(), Duration.zero);
    });
  });
}

