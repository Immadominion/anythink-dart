import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cancellation.dart';
import '../errors.dart';

final class ApiResponse {
  const ApiResponse({
    required this.data,
    required this.statusCode,
    required this.headers,
  });
  final Object? data;
  final int statusCode;
  final Map<String, String> headers;
}

/// Consume or cancel [stream] to release the underlying connection.
final class ApiStreamResponse {
  const ApiStreamResponse({
    required this.stream,
    required this.statusCode,
    required this.headers,
  });
  final Stream<List<int>> stream;
  final int statusCode;
  final Map<String, String> headers;
}

typedef RequestFactory =
    FutureOr<http.BaseRequest> Function(Uri uri, Future<void> abortTrigger);

/// Shared HTTP boundary. Feature services never implement their own auth retry.
/// No authorization header is attached to redirects or arbitrary URLs.
final class ApiTransport {
  ApiTransport({
    required Uri apiOrigin,
    required this.projectId,
    http.Client? httpClient,
    bool? closeHttpClient,
    this.requestTimeout = const Duration(seconds: 30),
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.allowInsecureLocalhost = false,
  }) : origin = _validateOrigin(apiOrigin, allowInsecureLocalhost),
       _client = httpClient ?? http.Client(),
       _ownsClient = closeHttpClient ?? httpClient == null {
    _validateSegment(projectId);
    if (requestTimeout <= Duration.zero || maxResponseBytes < 1) {
      throw ArgumentError('Timeout and response size must be positive.');
    }
  }

  final Uri origin;
  final String projectId;
  final Duration requestTimeout;
  final int maxResponseBytes;
  final bool allowInsecureLocalhost;
  final http.Client _client;
  final bool _ownsClient;
  final _active = <Completer<void>>{};
  bool _closed = false;

  // Assigned once by the owning AnythinkClient after auth construction.
  Future<String> Function()? provideAccessToken;
  Future<String> Function(String rejectedToken)? recoverAccessToken;
  int Function()? sessionGeneration;

  static Uri _validateOrigin(Uri uri, bool allowLocal) {
    final local = {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
    if (!uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.scheme != 'https' &&
            !(allowLocal && local && uri.scheme == 'http'))) {
      throw ArgumentError(
        'Use an HTTPS API origin without credentials, path, '
        'query or fragment. Local HTTP must be explicitly enabled.',
      );
    }
    return uri.replace(path: '');
  }

  static void _validateSegment(String segment) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains('\\') ||
        segment.codeUnits.any((c) => c < 32 || c == 127)) {
      throw ArgumentError('Invalid API path segment.');
    }
  }

  Uri uriFor(List<String> path, [Map<String, String>? query]) {
    for (final segment in path) {
      _validateSegment(segment);
    }
    return origin.replace(
      pathSegments: ['org', projectId, ...path],
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  Future<ApiResponse> request(
    String method,
    List<String> path, {
    Map<String, String>? query,
    Object? body,
    bool authenticated = true,
    bool retryOnUnauthorized = false,
    CancellationToken? cancellation,
  }) async {
    // Snapshot caller-owned payloads before auth/persistence can yield.
    final encodedBody = body == null ? null : jsonEncode(body);
    final response = await send(
      method,
      path,
      query: query,
      authenticated: authenticated,
      retryOnUnauthorized: retryOnUnauthorized,
      cancellation: cancellation,
      requestFactory: (uri, abort) {
        final request = http.AbortableRequest(
          method.toUpperCase(),
          uri,
          abortTrigger: abort,
        );
        if (encodedBody != null) {
          request.headers['content-type'] = 'application/json; charset=utf-8';
          request.body = encodedBody;
        }
        return request;
      },
    );
    final bytes = await _collect(response.stream);
    return ApiResponse(
      data: _decode(bytes, response.headers, response.statusCode),
      statusCode: response.statusCode,
      headers: response.headers,
    );
  }

  Future<ApiStreamResponse> send(
    String method,
    List<String> path, {
    Map<String, String>? query,
    bool authenticated = true,
    bool retryOnUnauthorized = false,
    CancellationToken? cancellation,
    RequestFactory? requestFactory,
  }) async {
    _checkOpen(cancellation);
    final uri = uriFor(path, query);
    final verb = method.toUpperCase();
    final generation = authenticated ? sessionGeneration?.call() : null;
    String? token;
    if (authenticated) {
      final provider = provideAccessToken;
      if (provider == null) throw const AuthRequiredException();
      token = await _withCancellation(provider(), cancellation);
    }
    _checkOpen(cancellation);
    if (generation != null && sessionGeneration?.call() != generation) {
      throw const SessionChangedException();
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      if (generation != null && sessionGeneration?.call() != generation) {
        throw const SessionChangedException();
      }
      final response = await _sendOnce(
        uri,
        verb,
        token: token,
        generation: generation,
        cancellation: cancellation,
        requestFactory: requestFactory,
      );
      if (generation != null && sessionGeneration?.call() != generation) {
        await response.stream.listen(null).cancel();
        throw const SessionChangedException();
      }
      // Error bodies can contain private validation details too. Fence every
      // response status before collecting it or attempting auth recovery.
      final stream = generation == null
          ? response.stream
          : _guardSession(response.stream, generation);
      if (response.statusCode == 401 &&
          authenticated &&
          retryOnUnauthorized &&
          attempt == 0 &&
          recoverAccessToken != null) {
        // Replays are opt-in. Services use this only for documented reads or
        // explicitly repeat-safe operations, with recreatable request bodies.
        await _collect(stream);
        token = await _withCancellation(
          recoverAccessToken!(token!),
          cancellation,
        );
        _checkOpen(cancellation);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final bytes = await _collect(stream);
        throw _apiError(response.statusCode, response.headers, bytes);
      }
      return ApiStreamResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        stream: stream,
      );
    }
    throw const ProtocolException('Authentication replay exhausted.');
  }

  /// Fetch a URL without any API authorization or cookies.
  /// Redirects are rejected by default. Public file downloads may explicitly
  /// follow up to five redirects; every destination is validated independently
  /// and an HTTPS request can never redirect to HTTP.
  Future<ApiStreamResponse> download(
    Uri signedUrl, {
    bool followRedirects = false,
    CancellationToken? cancellation,
  }) async {
    var destination = signedUrl;
    for (var redirects = 0; ; redirects++) {
      _validateDownloadUrl(destination);
      final response = await _sendOnce(
        destination,
        'GET',
        cancellation: cancellation,
      );
      if (followRedirects &&
          const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        // Fully consume the bounded redirect body before inspecting Location.
        // This starts the guarded stream and releases its connection even when
        // later URL validation fails. Timeout/cancellation remain in effect.
        await _collect(response.stream);
        if (redirects >= 5) {
          throw const ProtocolException('Too many download redirects.');
        }
        final location = response.headers['location'];
        if (location == null || location.trim().isEmpty) {
          throw const ProtocolException(
            'The download redirect has no location.',
          );
        }
        Uri next;
        try {
          next = destination.resolve(location);
        } on FormatException {
          throw const ProtocolException('The download redirect is invalid.');
        }
        if (destination.scheme == 'https' && next.scheme != 'https') {
          throw const ProtocolException('An HTTPS download cannot downgrade.');
        }
        try {
          _validateDownloadUrl(next);
        } on ArgumentError {
          throw const ProtocolException('The download redirect is unsafe.');
        }
        destination = next;
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final bytes = await _collect(response.stream);
        throw _apiError(response.statusCode, response.headers, bytes);
      }
      return response;
    }
  }

  void _validateDownloadUrl(Uri signedUrl) {
    final local = {'localhost', '127.0.0.1', '::1'}.contains(signedUrl.host);
    if (!signedUrl.hasAuthority ||
        signedUrl.host.isEmpty ||
        signedUrl.userInfo.isNotEmpty ||
        signedUrl.hasFragment ||
        (signedUrl.scheme != 'https' &&
            !(allowInsecureLocalhost && local && signedUrl.scheme == 'http'))) {
      throw ArgumentError('The download URL must use HTTPS.');
    }
  }

  Future<ApiStreamResponse> _sendOnce(
    Uri uri,
    String method, {
    String? token,
    int? generation,
    CancellationToken? cancellation,
    RequestFactory? requestFactory,
  }) async {
    _checkOpen(cancellation);
    final abort = Completer<void>();
    _active.add(abort);
    var timedOut = false;
    void stop() {
      if (!abort.isCompleted) abort.complete();
      // Even a caller that never subscribes to a streaming response must not
      // leave an expired request retained by this client indefinitely.
      _active.remove(abort);
    }

    final timer = Timer(requestTimeout, () {
      timedOut = true;
      stop();
    });
    // Completing a request releases this listener as well as the HTTP stream.
    final finished = Completer<void>();
    if (cancellation != null) {
      unawaited(
        Future.any([cancellation.whenCancelled, finished.future]).then((_) {
          if (cancellation.isCancelled) stop();
        }),
      );
    }
    void cleanup() {
      timer.cancel();
      _active.remove(abort);
      if (!finished.isCompleted) finished.complete();
    }

    TransportException transportError() => TransportException(
      timedOut
          ? TransportFailure.timeout
          : (_closed || cancellation?.isCancelled == true)
          ? TransportFailure.cancelled
          : TransportFailure.network,
      outcomeUncertain: method != 'GET' && method != 'HEAD',
    );
    try {
      final request = requestFactory == null
          ? http.AbortableRequest(method, uri, abortTrigger: abort.future)
          : await Future.sync(
              () => requestFactory(uri, abort.future),
            ).timeout(requestTimeout);
      if (request.url != uri ||
          request.method != method ||
          request.headers.keys.any(
            (k) => {
              'authorization',
              'x-api-key',
              'cookie',
            }.contains(k.toLowerCase()),
          )) {
        throw ArgumentError(
          'Request factories must preserve the destination '
          'and leave authentication to the client.',
        );
      }
      request.followRedirects = false;
      request.headers['accept'] = 'application/json';
      if (token != null) request.headers['authorization'] = 'Bearer $token';
      // Request factories may await native/file work. Account replacement,
      // cancellation or closure during that wait must win before dispatch.
      _checkOpen(cancellation);
      if (generation != null && sessionGeneration?.call() != generation) {
        throw const SessionChangedException();
      }
      final response = await _client.send(request).timeout(requestTimeout);
      Stream<List<int>> guarded() async* {
        try {
          await for (final bytes in response.stream) {
            yield bytes;
          }
        } on http.ClientException {
          throw transportError();
        } on TimeoutException {
          throw TransportException(
            TransportFailure.timeout,
            outcomeUncertain: method != 'GET' && method != 'HEAD',
          );
        } finally {
          cleanup();
        }
      }

      return ApiStreamResponse(
        stream: guarded(),
        statusCode: response.statusCode,
        headers: Map.unmodifiable(response.headers),
      );
    } on http.ClientException {
      cleanup();
      throw transportError();
    } on TimeoutException {
      stop();
      cleanup();
      throw TransportException(
        TransportFailure.timeout,
        outcomeUncertain: method != 'GET' && method != 'HEAD',
      );
    } catch (_) {
      cleanup();
      rethrow;
    }
  }

  Stream<List<int>> _guardSession(
    Stream<List<int>> stream,
    int generation,
  ) async* {
    await for (final bytes in stream) {
      if (sessionGeneration?.call() != generation) {
        throw const SessionChangedException();
      }
      yield bytes;
    }
    if (sessionGeneration?.call() != generation) {
      throw const SessionChangedException();
    }
  }

  Future<List<int>> _collect(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const ProtocolException(
          'API response exceeds the configured size limit.',
        );
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Object? _decode(List<int> bytes, Map<String, String> headers, int status) {
    if (status == 204 || bytes.isEmpty) return null;
    try {
      final text = utf8.decode(bytes);
      if ((headers['content-type'] ?? '').toLowerCase().contains('json')) {
        return jsonDecode(text);
      }
      return text;
    } on FormatException {
      throw const ProtocolException(
        'The response body is not valid for its content type.',
      );
    }
  }

  ApiException _apiError(
    int status,
    Map<String, String> headers,
    List<int> bytes,
  ) {
    Object? value;
    String? responseText;
    try {
      responseText = utf8.decode(bytes);
      value = jsonDecode(responseText);
    } on FormatException {
      value = null;
    }
    final data = value is Map<String, Object?> ? value : <String, Object?>{};
    final message =
        data['message'] ??
        data['title'] ??
        data['error'] ??
        (value is String ? value : (value == null ? responseText : null));
    final errors = <String, List<String>>{};
    if (data['errors'] case final Map<String, Object?> fields) {
      for (final entry in fields.entries) {
        // Validation details may contain user data and are never in toString.
        if (entry.value case final List<Object?> values) {
          errors[entry.key] = List.unmodifiable(values.whereType<String>());
        }
      }
    }
    final seconds = data['retry_after'];
    final headerRetry = int.tryParse(headers['retry-after'] ?? '');
    // Bound untrusted numeric values before conversion or Duration arithmetic.
    // A year already exceeds a useful automatic retry window.
    const maxRetrySeconds = 365 * 24 * 60 * 60;
    final retry =
        seconds is num &&
            seconds.isFinite &&
            seconds >= 0 &&
            seconds <= maxRetrySeconds
        ? seconds.ceil()
        : headerRetry;
    return ApiException(
      statusCode: status,
      code: data['error'] is String ? data['error'] as String : null,
      traceId: data['traceId'] is String ? data['traceId'] as String : null,
      serverMessage: message is String
          ? message.substring(0, message.length > 2048 ? 2048 : message.length)
          : null,
      retryAfter: retry == null || retry < 0 || retry > maxRetrySeconds
          ? null
          : Duration(seconds: retry),
      fieldErrors: Map.unmodifiable(errors),
    );
  }

  void _checkOpen(CancellationToken? cancellation) {
    if (_closed) throw const ClientClosedException();
    if (cancellation?.isCancelled == true) {
      throw const TransportException(TransportFailure.cancelled);
    }
  }

  Future<T> _withCancellation<T>(
    Future<T> operation,
    CancellationToken? cancellation,
  ) {
    if (cancellation == null) return operation;
    return Future.any([
      operation,
      cancellation.whenCancelled.then<T>((_) {
        throw const TransportException(TransportFailure.cancelled);
      }),
    ]);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final request in _active.toList()) {
      if (!request.isCompleted) request.complete();
    }
    if (_ownsClient) _client.close();
  }
}
