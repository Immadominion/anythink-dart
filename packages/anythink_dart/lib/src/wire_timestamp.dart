import 'errors.dart';
import 'json.dart';

/// Parses an API instant without Dart's silent calendar overflow or host-zone
/// assumptions. Fractional seconds and explicit UTC offsets are supported.
DateTime timestampFromJson(Object? value, String field) {
  final text = stringFromJson(value, field);
  final match = _timestamp.firstMatch(text);
  if (match == null || match.end != text.length) {
    throw ProtocolException('Invalid timestamp for $field.');
  }
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final hour = int.parse(match[4]!);
  final minute = int.parse(match[5]!);
  final second = int.parse(match[6]!);
  final date = DateTime.utc(year, month, day);
  final offsetHour = int.tryParse(match[7] ?? '') ?? 0;
  final offsetMinute = int.tryParse(match[8] ?? '') ?? 0;
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      hour > 23 ||
      minute > 59 ||
      second > 59 ||
      offsetHour > 23 ||
      offsetMinute > 59) {
    throw ProtocolException('Invalid timestamp for $field.');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null || !parsed.isUtc) {
    throw ProtocolException('Invalid timestamp for $field.');
  }
  return parsed;
}

final _timestamp = RegExp(
  r'^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:[.,][0-9]+)?(?:[Zz]|[+-]([0-9]{2}):?([0-9]{2}))$',
);
