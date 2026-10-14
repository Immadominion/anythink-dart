import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_dart/src/http/api_transport.dart';
import 'package:test/test.dart';

import '../auth_transport_support/local_api.dart';

void main() {
  late LocalApi api;
  late LocalApi cdn;
  late ApiTransport transport;
  late FilesApi files;
  var credentialReads = 0;

  setUp(() async {
    api = await LocalApi.start();
    cdn = await LocalApi.start();
    transport =
        ApiTransport(
            apiOrigin: api.origin,
            projectId: 'project',
            allowInsecureLocalhost: true,
          )
          ..provideAccessToken = () async {
            credentialReads++;
            return 'private-session-credential';
          };
    credentialReads = 0;
    files = FilesApi(transport);
  });

  tearDown(() async {
    transport.close();
    await api.close();
    await cdn.close();
    expect(api.handlerErrors, isEmpty);
    expect(cdn.handlerErrors, isEmpty);
  });

  test(
    'public link and CDN redirects work without auth or forwarded cookies',
    () async {
      final url = files.publicUrl(12);
      expect(url, api.origin.resolve('/org/project/files/12/public'));
      expect(api.requests, isEmpty);
      expect(() => files.publicUrl(0), throwsArgumentError);
      api.handle = (_) => WireReply.text(
        '',
        status: 302,
        headers: {
          'location': cdn.origin.resolve('/first').toString(),
          'set-cookie': 'private_cookie=must-not-forward',
        },
      );
      cdn.handle = (request) => request.uri.path == '/first'
          ? WireReply.text(
              '',
              status: 307,
              headers: {
                'location': '/asset?public=1',
                'set-cookie': 'cdn_cookie=must-not-forward',
              },
            )
          : WireReply.bytes([1, 2, 3, 4]);
      final progress = <int>[];
      final result = await files.downloadPublic(
        12,
        onProgress: (bytes, _) => progress.add(bytes),
      );
      expect(await result.stream.expand((chunk) => chunk).toList(), [
        1,
        2,
        3,
        4,
      ]);
      expect(progress.last, 4);
      expect(api.requests.single.uri.path, '/org/project/files/12/public');
      expect(cdn.requests.map((r) => r.uri.toString()), [
        '/first',
        '/asset?public=1',
      ]);
      for (final request in [...api.requests, ...cdn.requests]) {
        expect(request.method, 'GET');
        expect(request.authorization, isNull);
        expect(request.headers[HttpHeaders.cookieHeader], isNull);
      }
      expect(credentialReads, 0);
    },
  );

  test(
    'private or absent public file returns 404 without auth fallback',
    () async {
      api.handle = (_) => WireReply.text('Not found', status: 404);
      await expectLater(
        files.downloadPublic(12),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      expect(api.requests, hasLength(1));
      expect(credentialReads, 0);
      expect(cdn.requests, isEmpty);
    },
  );

  test('malicious redirect locations fail before any unsafe follow-up', () async {
    for (final location in [
      'http://public.example.test/file',
      '//user:secret@127.0.0.1:${cdn.origin.port}/asset',
      '${cdn.origin}/asset#private-fragment',
      'file:///etc/passwd',
      'javascript:alert(1)',
      'http://[invalid',
    ]) {
      api.handle = (_) =>
          WireReply.text('', status: 302, headers: {'location': location});
      await expectLater(
        files.downloadPublic(12),
        throwsA(isA<ProtocolException>()),
      );
    }
    expect(cdn.requests, isEmpty);
    expect(credentialReads, 0);
    // Failed validation releases the prior response and the client stays usable.
    api.handle = (_) => WireReply.bytes([7]);
    final result = await files.downloadPublic(12);
    expect(await result.stream.expand((chunk) => chunk).toList(), [7]);
  });

  test('missing redirect location and loops are bounded failures', () async {
    api.handle = (_) => WireReply.text('', status: 302);
    await expectLater(
      files.downloadPublic(12),
      throwsA(isA<ProtocolException>()),
    );
    final before = api.requests.length;
    api.handle = (_) =>
        WireReply.text('', status: 302, headers: {'location': '/loop'});
    await expectLater(
      files.downloadPublic(12),
      throwsA(isA<ProtocolException>()),
    );
    expect(api.requests.length - before, 6); // Initial request plus five hops.
    expect(credentialReads, 0);
  });

  test(
    'redirect bodies are bounded before following another destination',
    () async {
      final bounded = ApiTransport(
        apiOrigin: api.origin,
        projectId: 'project',
        allowInsecureLocalhost: true,
        maxResponseBytes: 2,
      );
      addTearDown(bounded.close);
      api.handle = (_) => WireReply.bytes(
        [1, 2, 3],
        status: 302,
        headers: {'location': cdn.origin.resolve('/asset').toString()},
      );
      await expectLater(
        FilesApi(bounded).downloadPublic(12),
        throwsA(isA<ProtocolException>()),
      );
      expect(cdn.requests, isEmpty);
      api.handle = (_) => WireReply.bytes([1]);
      final result = await FilesApi(bounded).downloadPublic(12);
      expect(await result.stream.expand((chunk) => chunk).toList(), [1]);
    },
  );

  test(
    'public streaming cancellation aborts and keeps the client reusable',
    () async {
      final finish = Completer<void>();
      addTearDown(() {
        if (!finish.isCompleted) finish.complete();
      });
      api.handle = (_) => WireReply.text(
        '',
        status: 302,
        headers: {'location': cdn.origin.resolve('/stream').toString()},
      );
      cdn.handle = (_) => WireReply.custom((response) async {
        response.headers.contentType = ContentType.binary;
        response.add(utf8.encode('first chunk'));
        await response.flush();
        await finish.future;
        await response.close();
      });
      final cancellation = CancellationToken();
      final result = await files.downloadPublic(12, cancellation: cancellation);
      final chunks = <List<int>>[];
      await expectLater(
        result.stream.forEach((chunk) {
          chunks.add(chunk);
          cancellation.cancel();
        }),
        throwsA(
          isA<TransportException>().having(
            (e) => e.failure,
            'failure',
            TransportFailure.cancelled,
          ),
        ),
      );
      expect(chunks, isNotEmpty);
      finish.complete();
      api.handle = (_) => WireReply.bytes([9]);
      final next = await files.downloadPublic(12);
      expect(await next.stream.expand((chunk) => chunk).toList(), [9]);
    },
  );

  test(
    'pre-cancelled or closed public downloads never make a request',
    () async {
      final cancellation = CancellationToken()..cancel();
      await expectLater(
        files.downloadPublic(12, cancellation: cancellation),
        throwsA(isA<TransportException>()),
      );
      transport.close();
      await expectLater(
        files.downloadPublic(12),
        throwsA(isA<ClientClosedException>()),
      );
      expect(api.requests, isEmpty);
    },
  );

  test(
    'production download validation rejects HTTP even on loopback',
    () async {
      final strict = ApiTransport(
        apiOrigin: Uri.https('api.example.test'),
        projectId: 'p',
      );
      addTearDown(strict.close);
      await expectLater(
        strict.download(cdn.origin.resolve('/asset'), followRedirects: true),
        throwsArgumentError,
      );
      expect(cdn.requests, isEmpty);
    },
  );
}
