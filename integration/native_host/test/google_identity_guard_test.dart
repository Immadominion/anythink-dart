import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../integration_test/google_device_test.dart' show TestIdentityGuard;

void main() {
  test(
    'test-only guard blocks cancel phase and unintended account before HTTP',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        requests++;
        await request.drain<void>();
        request.response.write('{}');
        await request.response.close();
      });
      final guard = TestIdentityGuard('ordinary@example.test');
      http.Request requestFor(String token) => http.Request(
        'POST',
        Uri.parse('http://127.0.0.1:${server.port}/auth/v1/native/google'),
      )..body = jsonEncode({'identity_token': token});
      String tokenFor(String email) =>
          'fixture.${base64Url.encode(utf8.encode(jsonEncode({'email': email})))}.fixture';
      try {
        await expectLater(
          guard.send(requestFor(tokenFor('ordinary@example.test'))),
          throwsA(isA<Object>()),
        );
        guard.allowExchange = true;
        for (final token in [
          'invalid',
          tokenFor('administrator@example.test'),
        ]) {
          await expectLater(
            guard.send(requestFor(token)),
            throwsA(isA<Object>()),
          );
        }
        expect(requests, 0);
        expect(guard.forwarded, 0);
        expect(guard.blocked, 3);
        // This proves only outbound filtering, never token authenticity. The
        // loopback server accepts a fixture; production Anythink must verify it.
        final response = await guard.send(
          requestFor(tokenFor('ordinary@example.test')),
        );
        await response.stream.drain<void>();
        expect(requests, 1);
        expect(guard.forwarded, 1);
      } finally {
        guard.close();
        await server.close(force: true);
      }
    },
  );
}
