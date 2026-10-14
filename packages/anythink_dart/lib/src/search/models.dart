import '../errors.dart';
import '../json.dart';
import '../records/page.dart';

/// One indexed record. Search IDs are strings and are never coerced to integers.
/// Different entities can appear together; [entity] identifies the schema.
final class SearchHit {
  SearchHit.fromJson(JsonObject value)
    : id = stringFromJson(value['id'], 'search.id'),
      entity = stringFromJson(value['__entity'], 'search.__entity'),
      resourcePath = stringFromJson(value['__url'], 'search.__url'),
      name = optionalStringFromJson(value['__name'], 'search.__name'),
      data = _freezeObject(value),
      untrustedFormatted = value['_formatted'] == null
          ? null
          : _freezeObject(objectFromJson(value['_formatted'], '_formatted')) {
    if (id.isEmpty || entity.isEmpty || resourcePath.isEmpty) {
      throw const ProtocolException('Incomplete search hit metadata.');
    }
  }

  final String id;
  final String entity;

  /// A server-supplied navigation hint. It is never fetched or opened by the SDK.
  final String resourcePath;
  final String? name;
  final JsonObject data;

  /// Server-generated highlighted copies can contain HTML and untrusted record
  /// content. These values are NOT safe HTML; the application must sanitize
  /// before rendering markup, or display them as ordinary text.
  final JsonObject? untrustedFormatted;

  /// Decode a schema only after selecting the appropriate [entity]. Public
  /// results omit private fields, so a decoder must support that projection.
  T decode<T>(RecordDecoder<T> decoder) => decoder(data);

  @override
  String toString() => 'SearchHit(metadata: [redacted])';
}

/// Search pagination plus optional per-field facet counts.
final class SearchPage {
  SearchPage._(this.pageData, this.facetDistribution);

  factory SearchPage.fromJson(Object? value) {
    final json = objectFromJson(value, 'search page');
    final page = Page<SearchHit>.fromJson(json, SearchHit.fromJson);
    final rawFacets = json['facet_distribution'];
    Map<String, Map<String, int>>? facets;
    if (rawFacets != null) {
      final fields = objectFromJson(rawFacets, 'facet_distribution');
      facets = Map.unmodifiable({
        for (final field in fields.entries)
          field.key: Map<String, int>.unmodifiable({
            for (final entry in objectFromJson(
              field.value,
              'facet counts',
            ).entries)
              entry.key: _facetCount(entry.value),
          }),
      });
    }
    return SearchPage._(page, facets);
  }

  final Page<SearchHit> pageData;

  /// Server-computed facets. Live validation found values from RLS-hidden
  /// records here even when [items] contained only the caller's own records.
  /// Do not treat facet values or counts as proof of record visibility.
  final Map<String, Map<String, int>>? facetDistribution;
  List<SearchHit> get items => pageData.items;
  int get page => pageData.page;
  int get pageSize => pageData.pageSize;

  /// The server's index count may include records removed by row-level access
  /// checks. It is not necessarily the number of visible records for this user.
  int get totalItems => pageData.totalItems;
  int get totalPages => pageData.totalPages;
  bool get hasNextPage => pageData.hasNextPage;
  bool get hasPreviousPage => pageData.hasPreviousPage;
  Duration? get retrievalTime => pageData.retrievalTime;
}

int _facetCount(Object? value) {
  final count = intFromJson(value, 'facet count');
  if (count < 0) throw const ProtocolException('Negative facet count.');
  return count;
}

JsonObject _freezeObject(JsonObject value) =>
    _freeze(value, Set<Object>.identity())! as JsonObject;

Object? _freeze(Object? value, Set<Object> ancestors) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is Map<String, Object?>) {
    if (!ancestors.add(value)) {
      throw const ProtocolException('Cyclic search result JSON.');
    }
    try {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key: _freeze(entry.value, ancestors),
      });
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is List<Object?>) {
    if (!ancestors.add(value)) {
      throw const ProtocolException('Cyclic search result JSON.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((item) => _freeze(item, ancestors)),
      );
    } finally {
      ancestors.remove(value);
    }
  }
  throw const ProtocolException('Search results contain non-JSON values.');
}
