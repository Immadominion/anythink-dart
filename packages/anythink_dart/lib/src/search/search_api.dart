import '../cancellation.dart';
import '../http/api_transport.dart';
import '../json.dart';
import 'models.dart';
import 'query.dart';

/// End-user full-text and similarity search. Administrative index rebuild/purge
/// is deliberately not part of this service. Server RLS and public-field policy
/// determine visibility; client filters are never an access-control boundary.
final class SearchApi {
  const SearchApi(this._transport);
  final ApiTransport _transport;

  Future<SearchPage> query({
    SearchQuery? query,
    CancellationToken? cancellation,
  }) => _query(['search'], query, true, cancellation);

  /// Sends no user credential, even when the client has a signed-in account.
  ///
  /// Public highlighting is currently unavailable: the live service returned
  /// private fields inside `_formatted` during validation. A request with
  /// [SearchQuery.highlight] enabled fails before any network call. This
  /// safeguard does not fix or enforce the server's public-field policy.
  Future<SearchPage> queryPublic({
    SearchQuery? query,
    CancellationToken? cancellation,
  }) async {
    if (query?.highlight ?? false) {
      throw UnsupportedError(
        'Public search highlighting is unavailable because the service can '
        'return private fields in highlighted results.',
      );
    }
    return _query(['search', 'public'], query, false, cancellation);
  }

  Future<SearchPage> _query(
    List<String> path,
    SearchQuery? query,
    bool authenticated,
    CancellationToken? cancellation,
  ) async {
    final response = await _transport.request(
      'GET',
      path,
      query: (query ?? SearchQuery()).toQueryParameters(),
      authenticated: authenticated,
      retryOnUnauthorized: authenticated,
      cancellation: cancellation,
    );
    return SearchPage.fromJson(response.data);
  }

  /// Returns a bare list, unlike paginated query results. The source record
  /// is excluded and RLS can yield fewer records than [limit]. An unindexed
  /// source or unknown entity returns the server's 404.
  ///
  /// The source [recordId] and [limit] are positive int32 values in the API;
  /// returned [SearchHit.id] values retain the search index's string encoding.
  Future<List<SearchHit>> similar({
    required String entity,
    required int recordId,
    int limit = 10,
    CancellationToken? cancellation,
  }) => _similar(
    ['search', 'similar'],
    entity,
    recordId,
    limit,
    true,
    cancellation,
  );

  Future<List<SearchHit>> _similar(
    List<String> path,
    String entity,
    int recordId,
    int limit,
    bool authenticated,
    CancellationToken? cancellation,
  ) async {
    // Reuse entity-name validation without passing records query grammar.
    SearchQuery(entities: [entity]);
    if (recordId < 1 ||
        recordId > 2147483647 ||
        limit < 1 ||
        limit > 2147483647) {
      throw ArgumentError('A positive int32 record ID and limit are required.');
    }
    final response = await _transport.request(
      'GET',
      path,
      query: {'e': entity, 'id': '$recordId', 'limit': '$limit'},
      authenticated: authenticated,
      retryOnUnauthorized: authenticated,
      cancellation: cancellation,
    );
    return List.unmodifiable(
      listFromJson(response.data, 'similar search results').map(
        (value) =>
            SearchHit.fromJson(objectFromJson(value, 'similar search hit')),
      ),
    );
  }
}
