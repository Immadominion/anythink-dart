import 'errors.dart';

typedef JsonObject = Map<String, Object?>;

JsonObject objectFromJson(Object? value, [String context = 'response']) {
  if (value is Map<String, Object?>) return Map.unmodifiable(value);
  throw ProtocolException('Expected a JSON object for $context.');
}

List<Object?> listFromJson(Object? value, [String context = 'response']) {
  if (value is List<Object?>) return List.unmodifiable(value);
  throw ProtocolException('Expected a JSON list for $context.');
}

String stringFromJson(Object? value, String field) {
  if (value is String) return value;
  throw ProtocolException('Expected a string for $field.');
}

String? optionalStringFromJson(Object? value, String field) =>
    value == null ? null : stringFromJson(value, field);

int intFromJson(Object? value, String field) {
  if (value is int) return value;
  throw ProtocolException('Expected an integer for $field.');
}

bool boolFromJson(Object? value, String field) {
  if (value is bool) return value;
  throw ProtocolException('Expected a boolean for $field.');
}
