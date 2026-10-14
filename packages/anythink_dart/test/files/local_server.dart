import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_dart/src/http/api_transport.dart';

/// Real loopback HTTP, exercising the actual transport and wire serialization.
final class LocalServer {
  LocalServer._(this.server);
  final HttpServer server;
  final errors = <Object>[];
  final _tasks = <Future<void>>[];

  static Future<LocalServer> start(
    Future<void> Function(HttpRequest) handler,
  ) async {
    final fixture = LocalServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen((request) {
      final task = () async {
        try {
          await handler(request);
        } on HttpException {
          /* Client cancellation can close an in-flight body. */
        } on SocketException {
          /* Expected for aborted transport tests. */
        } catch (error) {
          fixture.errors.add(error);
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {
            /* Already closed. */
          }
        }
      }();
      fixture._tasks.add(task);
    });
    return fixture;
  }

  Uri get origin => Uri.parse('http://127.0.0.1:${server.port}');
  ApiTransport transport({
    Duration timeout = const Duration(seconds: 3),
    int maxResponseBytes = 8 * 1024 * 1024,
  }) => ApiTransport(
    apiOrigin: origin,
    projectId: '42',
    allowInsecureLocalhost: true,
    requestTimeout: timeout,
    maxResponseBytes: maxResponseBytes,
  )..provideAccessToken = () async => 'fixture-access';

  Future<void> close() async {
    await server.close(force: true);
    await Future.wait(_tasks).timeout(const Duration(seconds: 3));
  }
}

Future<Object?> readJson(HttpRequest request) async =>
    jsonDecode(await utf8.decoder.bind(request).join());

Future<void> respondJson(
  HttpRequest request,
  Object? body, {
  int status = 200,
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  if (status != 204) request.response.write(jsonEncode(body));
  await request.response.close();
}
