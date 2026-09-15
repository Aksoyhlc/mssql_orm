import 'package:mssql_native/mssql_native.dart';

/// The driver returns every date and time column as an [MssqlDateTimeValue] —
/// year through nanosecond, plus an offset in minutes — because SQL Server's
/// types each have their own packed layout and hand-decoding them produces
/// plausible wrong answers rather than errors.
///
/// These convert to the Dart types a caller would rather have, and refuse
/// when the conversion would lose something.
extension MssqlDateTimeConversion on MssqlDateTimeValue {
  /// This value as a [DateTime].
  ///
  /// Throws when the conversion would lose information:
  ///
  /// * `DateTime` resolves to microseconds and `datetime2(7)`/`time(7)` to
  ///   100 nanoseconds, so a nanosecond field that is not a whole number of
  ///   microseconds cannot round-trip.
  /// * `DateTime` is either UTC or local and cannot carry an arbitrary offset,
  ///   so a non-zero [timezoneOffsetMinutes] would be dropped.
  ///
  /// Refusing rather than rounding is the same choice this package makes for
  /// `DECIMAL`: losing precision quietly is worse than an error. Generated
  /// code only calls this where the schema says the conversion is lossless, so
  /// the throw is a safety net for hand-written calls.
  DateTime toDateTime({bool utc = false}) {
    if (nanosecond % 1000 != 0) {
      throw ArgumentError.value(
        nanosecond,
        'nanosecond',
        'DateTime resolves to microseconds and this value carries $nanosecond '
            'nanoseconds. Keep the MssqlDateTimeValue, or read the column at '
            'a scale of 6 or less.',
      );
    }
    if (timezoneOffsetMinutes != 0) {
      throw ArgumentError.value(
        timezoneOffsetMinutes,
        'timezoneOffsetMinutes',
        'DateTime cannot carry an offset of $timezoneOffsetMinutes minutes; '
            'it is either UTC or local. Keep the MssqlDateTimeValue.',
      );
    }
    final microsecond = nanosecond ~/ 1000;
    return utc
        ? DateTime.utc(
            year,
            month,
            day,
            hour,
            minute,
            second,
            microsecond ~/ 1000,
            microsecond % 1000,
          )
        : DateTime(
            year,
            month,
            day,
            hour,
            minute,
            second,
            microsecond ~/ 1000,
            microsecond % 1000,
          );
  }

  /// A `time` column as the offset from the start of the day.
  ///
  /// [Duration] is the right type: a `time` has no date, and a [DateTime] would
  /// invent a day the database never stored.
  Duration toDuration() {
    if (nanosecond % 1000 != 0) {
      throw ArgumentError.value(
        nanosecond,
        'nanosecond',
        'Duration resolves to microseconds and this value carries $nanosecond '
            'nanoseconds. Keep the MssqlDateTimeValue, or read the column at '
            'a scale of 6 or less.',
      );
    }
    return Duration(
      hours: hour,
      minutes: minute,
      seconds: second,
      microseconds: nanosecond ~/ 1000,
    );
  }
}
