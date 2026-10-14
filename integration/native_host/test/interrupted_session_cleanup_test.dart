import 'dart:convert';
import 'dart:io';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/interrupted_session_cleanup.dart';

final class _Store implements SessionStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
  @override
  Future<void> clear() async => value = null;
}

void main() {
  test('malformed session still clears without claiming revoke', () async {
    final store = _Store()..value = '{invalid';
    final client = AnythinkClient(
      apiOrigin: Uri.parse('http://127.0.0.1:1'),
      projectId: 'test',
      sessionStore: store,
      allowInsecureLocalhost: true,
    );
    try {
      final result = await cleanupInterruptedSession(
        client,
        store,
        expectedEmail: 'ordinary@example.test',
      );
      expect(result.localCleared, isTrue);
      expect(result.identityConfirmed, isFalse);
      expect(result.remoteRevoked, isFalse);
      expect(store.value, isNull);
    } finally {
      await client.close();
    }
  });

  test(
    'pending rotation clears but old-token revoke cannot prove successor revoke',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = Uri.parse('http://127.0.0.1:${server.port}');
      var logouts = 0;
      server.listen((request) async {
        try {
          expect(request.method, 'POST');
          expect(request.uri.path, '/org/test/auth/v1/logout');
          expect(jsonDecode(await utf8.decoder.bind(request).join()), {
            'token': 'synthetic-old-refresh',
          });
          logouts++;
          request.response.statusCode = 204;
        } finally {
          await request.response.close();
        }
      });
      final store = _Store()
        ..value = jsonEncode({
          'version': 1,
          'api_origin': origin.toString(),
          'project_id': 'test',
          'rotation_pending': true,
          'session': {
            'access_token': 'synthetic-access',
            'refresh_token': 'synthetic-old-refresh',
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .toIso8601String(),
          },
        });
      final client = AnythinkClient(
        apiOrigin: origin,
        projectId: 'test',
        sessionStore: store,
        allowInsecureLocalhost: true,
      );
      try {
        final result = await cleanupInterruptedSession(
          client,
          store,
          expectedEmail: 'ordinary@example.test',
        );
        expect(logouts, 1);
        expect(result.localCleared, isTrue);
        expect(result.rotationUncertain, isTrue);
        expect(result.remoteRevoked, isFalse);
        expect(store.value, isNull);
      } finally {
        await client.close();
        await server.close(force: true);
      }
    },
  );
}
