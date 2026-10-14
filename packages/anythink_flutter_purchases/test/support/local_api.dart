import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Real loopback server used by auth and transport tests.
final class LocalApi {
  LocalApi._(this._server) {
    _subscription = _server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      final observation = ObservedRequest(request.method, request.uri, {
        for (final name in [
          HttpHeaders.authorizationHeader,
          HttpHeaders.contentTypeHeader,
          HttpHeaders.cookieHeader,
        ])
          if (request.headers.value(name) case final String value) name: value,
      }, text.isEmpty ? null : jsonDecode(text));
      requests.add(observation);
      _arrivals.add(observation);
      WireReply reply;
      try {
        reply = await handle(observation);
      } catch (error, stack) {
        handlerErrors.add((error, stack));
        reply = WireReply.json({'error': 'test_handler_failed'}, status: 500);
      }
      try {
        await reply.send(request.response);
      } on SocketException {
        // The caller may intentionally cancel or time out before a response.
      } on HttpException {
        // A test may deliberately close its client with the response in flight.
      }
    });
  }

  static Future<LocalApi> start() async =>
      LocalApi._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final _arrivals = StreamController<ObservedRequest>.broadcast();
  final requests = <ObservedRequest>[];
  final handlerErrors = <(Object, StackTrace)>[];
  FutureOr<WireReply> Function(ObservedRequest) handle = (_) =>
      WireReply.json({'error': 'test_route_missing'}, status: 404);

  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');
  List<ObservedRequest> at(String suffix) =>
      requests.where((request) => request.uri.path.endsWith(suffix)).toList();

  Future<ObservedRequest> waitFor(String suffix, {int count = 1}) {
    if (at(suffix).length >= count) return Future.value(at(suffix)[count - 1]);
    return _arrivals.stream
        .firstWhere((_) => at(suffix).length >= count)
        .then((_) => at(suffix)[count - 1]);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
    await _arrivals.close();
  }
}

final class ObservedRequest {
  const ObservedRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Object? body;
  String? get authorization => headers[HttpHeaders.authorizationHeader];
}

final class WireReply {
  WireReply.json(Object? data, {int status = 200, Map<String, String>? headers})
    : this.bytes(
        utf8.encode(jsonEncode(data)),
        status: status,
        contentType: 'application/json',
        headers: headers,
      );
  WireReply.text(String data, {int status = 200, Map<String, String>? headers})
    : this.bytes(
        utf8.encode(data),
        status: status,
        contentType: 'text/plain',
        headers: headers,
      );
  WireReply.bytes(
    this.body, {
    this.status = 200,
    this.contentType = 'application/octet-stream',
    Map<String, String>? headers,
  }) : headers = headers ?? {},
       _custom = null;
  WireReply.empty({int status = 204}) : this.bytes([], status: status);
  WireReply.custom(Future<void> Function(HttpResponse) send)
    : body = [],
      status = 200,
      contentType = '',
      headers = {},
      _custom = send;

  final List<int> body;
  final int status;
  final String contentType;
  final Map<String, String> headers;
  final Future<void> Function(HttpResponse)? _custom;

  Future<void> send(HttpResponse response) async {
    if (_custom case final send?) {
      response.bufferOutput = false;
      await send(response);
      return;
    }
    response.statusCode = status;
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    headers.forEach(response.headers.set);
    if (status != 204) response.add(body);
    await response.close();
  }
}
