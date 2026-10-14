/// The query text grammar accepted by Anythink's full-text search service.
sealed class SearchText {
  const SearchText._(this.encoded);

  /// Plain text. A colon would instead select a field in the wire protocol.
  factory SearchText.text(String value) {
    _validateText(value);
    return _SearchText(value);
  }

  /// Search within one field, using the documented `field:text` syntax.
  factory SearchText.field(String field, String value) {
    _validateName(field, 'search field');
    _validateText(value);
    return _SearchText('$field:$value');
  }

  /// Match all indexed records. Omitting text from [SearchQuery] does the same.
  const factory SearchText.all() = _AllSearchText;

  final String encoded;
}

final class _SearchText extends SearchText {
  const _SearchText(super.encoded) : super._();
}

final class _AllSearchText extends SearchText {
  const _AllSearchText() : super._('*');
}

void _validateText(String value) {
  if (value.isEmpty || value.contains(':')) {
    throw ArgumentError(
      'Search text must be nonempty and cannot contain a literal colon. '
      'Use SearchText.field for field-scoped search; literal escaping is '
      'not documented.',
    );
  }
}

/// An explicit Meilisearch expression, not the records filter grammar.
///
/// Examples: `status = published`, `status IN [draft, published]`, or
/// `_geoRadius(51.5, -0.1, 1000)`. The server validates syntax and searchable
/// fields. This value is URL encoded as one `fl` query parameter and is never
/// combined with RecordFilter operators or treated as an authorization rule.
final class SearchFilter {
  SearchFilter.expression(this.expression) {
    if (expression.trim().isEmpty) {
      throw ArgumentError('A search filter expression must not be empty.');
    }
  }
  final String expression;
}

enum SearchSortDirection { ascending, descending }

/// A documented field or geographic-distance sort term.
final class SearchSort {
  SearchSort.field(
    String field, {
    this.direction = SearchSortDirection.ascending,
  }) : _field = field {
    _validateName(field, 'sort field');
  }

  SearchSort.distance({
    required double latitude,
    required double longitude,
    this.direction = SearchSortDirection.ascending,
  }) : _field = '_geoPoint($latitude, $longitude)' {
    if (!latitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        !longitude.isFinite ||
        longitude < -180 ||
        longitude > 180) {
      throw ArgumentError('Invalid latitude or longitude.');
    }
  }

  final String _field;
  final SearchSortDirection direction;
  String get encoded =>
      '$_field:${direction == SearchSortDirection.ascending ? 'asc' : 'desc'}';
}

/// Immutable options for full-text search across one or more entities.
///
/// Search indexes update asynchronously. The server exposes at most 1,000
/// reachable results per query per entity; narrowing a query may be necessary.
/// RLS filtering can yield a page shorter than [pageSize]. Sort/filter/facet
/// fields must be searchable according to the server's field configuration.
final class SearchQuery {
  SearchQuery({
    this.text,
    Iterable<String> entities = const [],
    Iterable<SearchSort> sort = const [],
    this.filter,
    Iterable<String> facets = const [],
    this.highlight = false,
    this.page = 1,
    this.pageSize = 20,
  }) : entities = List.unmodifiable(entities),
       sort = List.unmodifiable(sort),
       facets = List.unmodifiable(facets) {
    if (page < 1 || page > 2147483647 || pageSize < 1 || pageSize > 100) {
      throw ArgumentError(
        'Search page must be a positive int32; pageSize is 1 to 100.',
      );
    }
    _validateNames(this.entities, 'entity');
    _validateNames(this.facets, 'facet field');
    if (this.sort.map((term) => term._field).toSet().length !=
        this.sort.length) {
      throw ArgumentError('A search sort field must not be repeated.');
    }
  }

  final SearchText? text;
  final List<String> entities;
  final List<SearchSort> sort;
  final SearchFilter? filter;
  final List<String> facets;

  /// Requests `_formatted` fields containing untrusted HTML. Sanitize before
  /// any HTML rendering; the SDK never renders or treats this data as safe.
  /// Public queries reject this option because the live service can expose
  /// private fields in highlighted results. Authenticated queries support it.
  final bool highlight;
  final int page;
  final int pageSize;

  Map<String, String> toQueryParameters() => Map.unmodifiable({
    'q': ?text?.encoded,
    if (entities.isNotEmpty) 'e': entities.join(','),
    if (sort.isNotEmpty) 's': sort.map((term) => term.encoded).join(','),
    'fl': ?filter?.expression,
    if (facets.isNotEmpty) 'f': facets.join(','),
    if (highlight) 'hl': 'true',
    'page': '$page',
    'pageSize': '$pageSize',
  });
}

void _validateNames(List<String> names, String description) {
  for (final name in names) {
    _validateName(name, description);
  }
  if (names.toSet().length != names.length) {
    throw ArgumentError('Repeated $description names are not supported.');
  }
}

void _validateName(String value, String description) {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value)) {
    throw ArgumentError('The $description must be an entity or field name.');
  }
}
