import 'package:meta/meta.dart';

/// The difference between "the caller did not mention this column" and
/// "the caller set this column to NULL".
///
/// A `Patch` carries one of these per writable column:
///
/// * [AbsentField] — the column is not named in the statement. On an UPDATE,
///   the row keeps what it holds; on an INSERT, the column takes its default.
/// * [ValueField] — the column is named, and its value is [ValueField.value].
///
/// Only a nullable column accepts `Field<T?>.value(null)`; a non-null column
/// given `Field<T>.value(null)` is a programming error caught at the type
/// level, because `T` is not nullable.
///
/// ```dart
/// final clearCity = CustomerPatch(city: Field<String?>.value(null));
/// final keepCity = CustomerPatch();
/// ```
@immutable
sealed class Field<T> {
  const Field();

  /// The column is not named.
  const factory Field.absent() = AbsentField<T>;

  /// The column is named and carries [value].
  const factory Field.value(T value) = ValueField<T>;

  /// Whether this is [AbsentField].
  bool get isAbsent => this is AbsentField<T>;

  /// Whether this is [ValueField].
  bool get isPresent => this is ValueField<T>;

  /// The carried value. Throws if this is [AbsentField].
  T get value => switch (this) {
    ValueField<T>(:final value) => value,
    AbsentField<T>() => throw StateError(
      'Field is absent; check isPresent before reading value.',
    ),
  };

  /// The value, or null when absent.
  ///
  /// Convenience for callers that want `T?` without pattern matching: an
  /// absent field yields `null`, a present field yields its value. For a
  /// `Field<T?>` whose value is `null`, this still returns `null` — the two
  /// are distinguishable through [isAbsent] / [isPresent] when it matters.
  T? get valueOrNull => switch (this) {
    AbsentField<T>() => null,
    ValueField<T>(:final value) => value,
  };
}

/// The column is not named in the statement.
@immutable
final class AbsentField<T> extends Field<T> {
  const AbsentField();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AbsentField<T>;

  @override
  int get hashCode => 'AbsentField<$T>'.hashCode;

  @override
  String toString() => 'Field<$T>.absent()';
}

/// The column is named and carries [value].
@immutable
final class ValueField<T> extends Field<T> {
  const ValueField(this.value);

  @override
  final T value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ValueField<T> && value == other.value;

  @override
  int get hashCode => Object.hash('ValueField<$T>', value);

  @override
  String toString() => 'Field<$T>.value($value)';
}
