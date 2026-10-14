import 'package:http/http.dart' as http;

import 'auth/anythink_auth.dart';
import 'auth/session_store.dart';
import 'files/files_api.dart';
import 'http/api_transport.dart';
import 'json.dart';
import 'push/push_api.dart';
import 'payments/payments_api.dart';
import 'records/record_service.dart';
import 'search/search_api.dart';
import 'subscriptions/subscriptions_api.dart';
import 'workflows/workflows_api.dart';

/// A project-scoped Anythink client. Creating it does not perform network calls.
///
/// Call `auth.restoreSession()` explicitly when using persistence. Without a
/// [sessionStore], credentials live only in memory for this client instance.
/// Injected HTTP clients remain caller-owned unless [closeHttpClient] is true.
final class AnythinkClient {
  AnythinkClient({
    required Uri apiOrigin,
    required String projectId,
    SessionStore? sessionStore,
    http.Client? httpClient,
    bool? closeHttpClient,
    DateTime Function()? clock,
    Duration requestTimeout = const Duration(seconds: 30),
    Duration refreshMargin = const Duration(seconds: 30),
    int maxResponseBytes = 8 * 1024 * 1024,
    bool allowInsecureLocalhost = false,
  }) : _transport = ApiTransport(
         apiOrigin: apiOrigin,
         projectId: projectId,
         httpClient: httpClient,
         closeHttpClient: closeHttpClient,
         requestTimeout: requestTimeout,
         maxResponseBytes: maxResponseBytes,
         allowInsecureLocalhost: allowInsecureLocalhost,
       ) {
    auth = AnythinkAuth(
      _transport,
      sessionStore: sessionStore,
      clock: clock,
      refreshMargin: refreshMargin,
    );
    _transport.provideAccessToken = auth.accessTokenForRequest;
    _transport.recoverAccessToken = auth.recoverAfterUnauthorized;
    _transport.sessionGeneration = () => auth.generation;
    files = FilesApi(_transport);
    subscriptions = SubscriptionsApi(_transport);
    payments = PaymentsApi(_transport);
    push = PushApi(_transport);
    search = SearchApi(_transport);
    workflows = WorkflowsApi(_transport);
  }

  final ApiTransport _transport;
  late final AnythinkAuth auth;
  late final FilesApi files;
  late final SubscriptionsApi subscriptions;
  late final PaymentsApi payments;
  late final PushApi push;
  late final SearchApi search;
  late final WorkflowsApi workflows;
  Uri get apiOrigin => _transport.origin;
  String get projectId => _transport.projectId;

  RecordService<T> collection<T>(
    String entity, {
    required T Function(JsonObject) decode,
  }) => RecordService<T>(transport: _transport, entity: entity, decode: decode);

  /// Raw records for dynamic schemas. Use [collection] for application models.
  RecordService<JsonObject> records(String entity) =>
      collection(entity, decode: (json) => Map.unmodifiable(json));

  /// Cancels HTTP work and releases resources. Does not revoke or clear a
  /// persisted account; call `auth.signOut()` when sign-out is intended.
  Future<void> close() async {
    final authClosing = auth.close();
    _transport.close();
    await authClosing;
  }
}
