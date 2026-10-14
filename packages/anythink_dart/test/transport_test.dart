import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_dart/src/http/api_transport.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'auth_transport_support/local_api.dart';

final class _BodyObservedClient extends http.BaseClient {
  final _delegate = http.Client();
  final firstBodyChunk = Completer<void>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _delegate.send(request);
    return http.StreamedResponse(
      response.stream.map((bytes) {
        if (!firstBodyChunk.isCompleted) firstBodyChunk.complete();
        return bytes;
      }),
      response.statusCode,
      headers: response.headers,
      contentLength: response.contentLength,
      request: response.request,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _delegate.close();
}

void main() {
  late LocalApi api;
  late List<ApiTransport> transports;

  ApiTransport createTransport({
    http.Client? client,
    bool? closeClient,
    int maxBytes = 1024 * 1024,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final transport = ApiTransport(
      apiOrigin: api.origin,
      projectId: 'transport-tests',
      httpClient: client,
      closeHttpClient: closeClient,
      maxResponseBytes: maxBytes,
      requestTimeout: timeout,
      allowInsecureLocalhost: true,
    );
    transports.add(transport);
    return transport;
  }

  setUp(() async {
    api = await LocalApi.start();
    transports = [];
  });
  tearDown(() async {
    for (final transport in transports) {
      transport.close();
    }
    await api.close();
    expect(api.handlerErrors, isEmpty);
  });

  test(
    'HTTP verbs, JSON body, encoded URL and response headers are preserved',
    () async {
      final transport = createTransport();
      transport.provideAccessToken = () async => 'synthetic-access-token';
      api.handle = (_) => WireReply.json(
        {'ok': true},
        status: 201,
        headers: {'x-request-id': 'request-1'},
      );
      final response = await transport.request(
        'post',
        ['entities', 'notes & stuff', 'items'],
        query: {'search': 'a+b & 東京', 'fields': 'a,b'},
        body: {
          'nested': [1, true, null],
        },
      );
      final request = api.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.pathSegments, [
        'org',
        'transport-tests',
        'entities',
        'notes & stuff',
        'items',
      ]);
      expect(request.uri.queryParameters, {
        'search': 'a+b & 東京',
        'fields': 'a,b',
      });
      expect(request.authorization, 'Bearer synthetic-access-token');
      expect(request.body, {
        'nested': [1, true, null],
      });
      expect(response.data, {'ok': true});
      expect(response.statusCode, 201);
      expect(response.headers['x-request-id'], 'request-1');
      expect(() => response.headers.clear(), throwsUnsupportedError);
    },
  );

  test(
    'decodes JSON strings booleans arrays plain text and empty 204 responses',
    () async {
      final transport = createTransport();
      final replies = [
        WireReply.json('json string'),
        WireReply.json(true),
        WireReply.json([1, 2]),
        WireReply.text('plain acknowledgment'),
        WireReply.empty(),
      ];
      final expected = <Object?>[
        'json string',
        true,
        [1, 2],
        'plain acknowledgment',
        null,
      ];
      for (var index = 0; index < replies.length; index++) {
        api.handle = (_) => replies[index];
        expect(
          (await transport.request('GET', ['read'], authenticated: false)).data,
          expected[index],
        );
      }
    },
  );

  test(
    'JSON validation and plain HTTP failures become redacted typed errors',
    () async {
      final transport = createTransport();
      api.handle = (_) => WireReply.json({
        'error': 'invalid_request',
        'traceId': 'trace-1',
        'retry_after': 12,
        'errors': {
          'email': ['private-user@example.test is invalid'],
        },
      }, status: 422);
      try {
        await transport.request(
          'POST',
          ['write'],
          authenticated: false,
          body: {},
        );
        fail('The server rejection must throw.');
      } on ApiException catch (error) {
        expect(error.statusCode, 422);
        expect(error.code, 'invalid_request');
        expect(error.traceId, 'trace-1');
        expect(error.retryAfter, const Duration(seconds: 12));
        expect(error.fieldErrors['email'], [
          'private-user@example.test is invalid',
        ]);
        expect(error.toString(), isNot(contains('private-user')));
        expect(() => error.fieldErrors.clear(), throwsUnsupportedError);
        expect(
          () => error.fieldErrors['email']!.clear(),
          throwsUnsupportedError,
        );
      }
      api.handle = (_) => WireReply.text(
        'Private backend failure details',
        status: 500,
        headers: {'retry-after': '5'},
      );
      await expectLater(
        transport.request('GET', ['read'], authenticated: false),
        throwsA(
          isA<ApiException>()
              .having((error) => error.statusCode, 'status', 500)
              .having(
                (error) => error.retryAfter,
                'retry',
                const Duration(seconds: 5),
              )
              .having(
                (error) => error.toString(),
                'diagnostic',
                isNot(contains('Private')),
              ),
        ),
      );
    },
  );

  test(
    'structured server messages stay separate from safe diagnostics',
    () async {
      final transport = createTransport();
      api.handle = (_) => WireReply.json({
        'error': 'private-error-code',
        'traceId': 'private-trace-value',
        'message': 'private-user@example.test already exists',
        'title': 'Fallback title',
      }, status: 400);
      try {
        await transport.request('POST', ['register'], authenticated: false);
        fail('A rejected request must throw.');
      } on ApiException catch (error) {
        expect(error.serverMessage, 'private-user@example.test already exists');
        expect(error.message, 'The API rejected the request.');
        expect(error.toString(), 'ApiException(statusCode: 400)');
        expect('$error', isNot(contains('private-')));
      }
      api.handle = (_) => WireReply.json({
        'title': 'Validation requires a company email',
      }, status: 400);
      await expectLater(
        transport.request('POST', ['register'], authenticated: false),
        throwsA(
          isA<ApiException>().having(
            (error) => error.serverMessage,
            'serverMessage',
            'Validation requires a company email',
          ),
        ),
      );
    },
  );

  test(
    'JSON string, error field, plain and malformed errors retain private messages safely',
    () async {
      final transport = createTransport();
      for (final (reply, expected) in <(WireReply, String)>[
        (
          WireReply.json('JSON private-user@example.test error', status: 400),
          'JSON private-user@example.test error',
        ),
        (
          WireReply.json({
            'error': 'error-field private-user@example.test error',
          }, status: 400),
          'error-field private-user@example.test error',
        ),
        (
          WireReply.text('plain private-user@example.test error', status: 400),
          'plain private-user@example.test error',
        ),
        (
          WireReply.bytes(
            utf8.encode('{malformed private-user@example.test'),
            contentType: 'application/json',
            status: 502,
          ),
          '{malformed private-user@example.test',
        ),
      ]) {
        api.handle = (_) => reply;
        await expectLater(
          transport.request('GET', ['read'], authenticated: false),
          throwsA(
            isA<ApiException>()
                .having(
                  (error) => error.serverMessage,
                  'serverMessage',
                  expected,
                )
                .having(
                  (error) => error.toString(),
                  'diagnostic',
                  isNot(contains('private-user')),
                ),
          ),
        );
      }
    },
  );

  test(
    'server error message cap applies to JSON fields and plain text',
    () async {
      final transport = createTransport();
      final message = 'sensitive' * 400;
      for (final reply in [
        WireReply.json({'message': message}, status: 400),
        WireReply.json({'title': message}, status: 400),
        WireReply.json({'error': message}, status: 400),
        WireReply.json(message, status: 400),
        WireReply.text(message, status: 500),
      ]) {
        api.handle = (_) => reply;
        await expectLater(
          transport.request('GET', ['read'], authenticated: false),
          throwsA(
            isA<ApiException>()
                .having(
                  (error) => error.serverMessage,
                  'bounded message',
                  message.substring(0, 2048),
                )
                .having(
                  (error) => error.toString(),
                  'diagnostic',
                  isNot(contains('sensitive')),
                ),
          ),
        );
      }
    },
  );

  test(
    'invalid error message types and unreadable text remain typed HTTP failures',
    () async {
      final transport = createTransport();
      for (final reply in [
        WireReply.json({
          'message': {'private': 'value'},
        }, status: 400),
        WireReply.json({
          'title': ['private value'],
        }, status: 400),
        WireReply.bytes([0xff], contentType: 'application/json', status: 502),
      ]) {
        api.handle = (_) => reply;
        await expectLater(
          transport.request('GET', ['read'], authenticated: false),
          throwsA(
            isA<ApiException>()
                .having((error) => error.serverMessage, 'serverMessage', isNull)
                .having(
                  (error) => error.toString(),
                  'diagnostic',
                  isNot(contains('private')),
                ),
          ),
        );
      }
    },
  );

  test('malformed JSON and invalid UTF-8 are protocol failures', () async {
    final transport = createTransport();
    for (final reply in [
      WireReply.bytes(utf8.encode('{bad'), contentType: 'application/json'),
      WireReply.bytes([0xff], contentType: 'application/json'),
    ]) {
      api.handle = (_) => reply;
      await expectLater(
        transport.request('GET', ['read'], authenticated: false),
        throwsA(isA<ProtocolException>()),
      );
    }
  });

  test(
    'nonfinite retry metadata cannot escape the typed HTTP error boundary',
    () async {
      final transport = createTransport();
      api.handle = (_) => WireReply.bytes(
        utf8.encode('{"error":"busy","retry_after":1e400}'),
        contentType: 'application/json',
        status: 429,
      );
      await expectLater(
        transport.request('GET', ['read'], authenticated: false),
        throwsA(
          isA<ApiException>().having(
            (error) => error.retryAfter,
            'retryAfter',
            isNull,
          ),
        ),
      );
    },
  );

  test(
    'authenticated requests require credentials; public requests do not call provider',
    () async {
      final transport = createTransport();
      await expectLater(
        transport.request('GET', ['read']),
        throwsA(isA<AuthRequiredException>()),
      );
      expect(api.requests, isEmpty);
      transport.provideAccessToken = () =>
          throw StateError('Public request read credentials');
      api.handle = (_) => WireReply.json(true);
      await transport.request('GET', ['read'], authenticated: false);
      expect(api.requests.single.authorization, isNull);
    },
  );

  test(
    'generation is captured before the asynchronous token provider',
    () async {
      final transport = createTransport();
      var generation = 1;
      final token = Completer<String>();
      transport.sessionGeneration = () => generation;
      transport.provideAccessToken = () => token.future;
      final request = transport.request('GET', ['read']);
      final rejected = expectLater(
        request,
        throwsA(isA<SessionChangedException>()),
      );
      generation++;
      token.complete('token-for-replacement-account');
      await rejected;
      expect(api.requests, isEmpty);
    },
  );

  test(
    'generation changes during recovery prevent old requests replaying',
    () async {
      final transport = createTransport();
      var generation = 1;
      final recovery = Completer<String>();
      final recovering = Completer<void>();
      transport.sessionGeneration = () => generation;
      transport.provideAccessToken = () async => 'old-access';
      transport.recoverAccessToken = (_) {
        recovering.complete();
        return recovery.future;
      };
      api.handle = (_) => WireReply.json({'error': 'expired'}, status: 401);
      final request = transport.request('GET', [
        'read',
      ], retryOnUnauthorized: true);
      final rejected = expectLater(
        request,
        throwsA(isA<SessionChangedException>()),
      );
      await recovering.future;
      generation++;
      recovery.complete('new-access');
      await rejected;
      expect(api.requests.length, 1);
    },
  );

  test(
    'an account change during request creation prevents mutation dispatch',
    () async {
      final transport = createTransport();
      var generation = 1;
      transport.sessionGeneration = () => generation;
      transport.provideAccessToken = () async => 'old-account-access';
      final entered = Completer<void>();
      final release = Completer<void>();
      api.handle = (_) => WireReply.empty();
      final operation = transport.send(
        'POST',
        ['write'],
        requestFactory: (uri, abort) async {
          entered.complete();
          await release.future;
          return http.AbortableRequest('POST', uri, abortTrigger: abort)
            ..body = '{}';
        },
      );
      final rejected = expectLater(
        operation,
        throwsA(isA<SessionChangedException>()),
      );
      await entered.future;
      generation++;
      release.complete();
      await rejected;
      expect(api.requests, isEmpty);
    },
  );

  for (final status in [401, 403]) {
    test('an account change fences a streaming $status body', () async {
      final client = _BodyObservedClient();
      final transport = createTransport(client: client, closeClient: true);
      var generation = 1;
      var recoveries = 0;
      final release = Completer<void>();
      transport.sessionGeneration = () => generation;
      transport.provideAccessToken = () async => 'old-account-access';
      transport.recoverAccessToken = (_) async {
        recoveries++;
        return 'replacement-account-access';
      };
      api.handle = (_) => WireReply.custom((response) async {
        response.statusCode = status;
        response.headers.contentType = ContentType.json;
        response.write('{"message":"old-account-');
        await response.flush();
        await release.future;
        response.write('private-details"}');
        await response.close();
      });
      final operation = transport.request('GET', [
        'read',
      ], retryOnUnauthorized: true);
      final rejected = expectLater(
        operation,
        throwsA(isA<SessionChangedException>()),
      );
      await client.firstBodyChunk.future;
      generation++;
      release.complete();
      await rejected;
      expect(recoveries, 0);
      expect(api.requests, hasLength(1));
    });
  }

  test(
    'generation changes while reading a response reject stale bytes',
    () async {
      final transport = createTransport();
      var generation = 1;
      final firstChunk = Completer<void>();
      final release = Completer<void>();
      transport.sessionGeneration = () => generation;
      transport.provideAccessToken = () async => 'old-access';
      api.handle = (_) => WireReply.custom((response) async {
        response.headers.contentType = ContentType.json;
        response.write('{"id":');
        await response.flush();
        firstChunk.complete();
        await release.future;
        response.write('1}');
        await response.close();
      });
      final pending = transport.request('GET', ['read']);
      final rejected = expectLater(
        pending,
        throwsA(isA<SessionChangedException>()),
      );
      await firstChunk.future;
      generation++;
      release.complete();
      await rejected;
    },
  );

  test('401 retry is opt in and occurs at most once', () async {
    final transport = createTransport();
    transport.provideAccessToken = () async => 'old-access';
    var recoveries = 0;
    transport.recoverAccessToken = (_) async {
      recoveries++;
      return 'new-access';
    };
    api.handle = (_) => WireReply.json({'error': 'expired'}, status: 401);
    await expectLater(
      transport.request('GET', ['read'], retryOnUnauthorized: true),
      throwsA(isA<ApiException>()),
    );
    expect(api.requests.length, 2);
    expect(recoveries, 1);
    expect(api.requests.last.authorization, 'Bearer new-access');
    await expectLater(
      transport.request('POST', ['write'], body: {'value': 1}),
      throwsA(isA<ApiException>()),
    );
    expect(api.requests.length, 3);
    expect(recoveries, 1);
  });

  test(
    'cancelled token waiter settles without completing shared token work',
    () async {
      final transport = createTransport();
      final token = Completer<String>();
      final cancellation = CancellationToken();
      transport.provideAccessToken = () => token.future;
      final pending = transport.request('GET', [
        'read',
      ], cancellation: cancellation);
      final rejected = expectLater(
        pending,
        throwsA(
          isA<TransportException>().having(
            (error) => error.failure,
            'failure',
            TransportFailure.cancelled,
          ),
        ),
      );
      cancellation.cancel();
      await rejected.timeout(const Duration(seconds: 1));
      expect(token.isCompleted, isFalse);
      expect(api.requests, isEmpty);
      token.complete('shared-operation-still-completes');
    },
  );

  test(
    'network cancellation marks dispatched mutation outcome uncertain',
    () async {
      final transport = createTransport();
      final cancellation = CancellationToken();
      final release = Completer<WireReply>();
      api.handle = (_) => release.future;
      final pending = transport.request(
        'POST',
        ['write'],
        body: {'value': 1},
        authenticated: false,
        cancellation: cancellation,
      );
      final rejected = expectLater(
        pending,
        throwsA(
          isA<TransportException>()
              .having(
                (error) => error.failure,
                'failure',
                TransportFailure.cancelled,
              )
              .having((error) => error.outcomeUncertain, 'outcome', isTrue),
        ),
      );
      await api.waitFor('/write');
      cancellation.cancel();
      await rejected;
      release.complete(WireReply.empty());
      expect(api.requests.length, 1);
    },
  );

  test(
    'timed out writes and reads have different uncertainty outcomes',
    () async {
      final transport = createTransport(
        timeout: const Duration(milliseconds: 100),
      );
      for (final method in ['POST', 'GET']) {
        final release = Completer<WireReply>();
        api.handle = (_) => release.future;
        await expectLater(
          transport.request(method, ['slow'], authenticated: false),
          throwsA(
            isA<TransportException>()
                .having(
                  (error) => error.failure,
                  'failure',
                  TransportFailure.timeout,
                )
                .having(
                  (error) => error.outcomeUncertain,
                  'outcome',
                  method == 'POST',
                ),
          ),
        );
        release.complete(WireReply.empty());
      }
      expect(api.requests.length, 2);
    },
  );

  test('timeout covers body streaming after response headers arrive', () async {
    final transport = createTransport(
      timeout: const Duration(milliseconds: 100),
    );
    final release = Completer<void>();
    api.handle = (_) => WireReply.custom((response) async {
      response.headers.contentType = ContentType.json;
      response.write('{"value":');
      await response.flush();
      await release.future;
      response.write('1}');
      await response.close();
    });
    await expectLater(
      transport.request('GET', ['slow-body'], authenticated: false),
      throwsA(
        isA<TransportException>().having(
          (error) => error.failure,
          'failure',
          TransportFailure.timeout,
        ),
      ),
    );
    release.complete();
  });

  test(
    'cancelling after a body chunk aborts the active response stream',
    () async {
      final transport = createTransport();
      final cancellation = CancellationToken();
      final release = Completer<void>();
      final receivedChunk = Completer<void>();
      api.handle = (_) => WireReply.custom((response) async {
        response.add([1, 2, 3]);
        await response.flush();
        await release.future;
        response.add([4]);
        await response.close();
      });
      final response = await transport.send(
        'GET',
        ['stream'],
        authenticated: false,
        cancellation: cancellation,
      );
      final reading = response.stream.map((chunk) {
        if (!receivedChunk.isCompleted) receivedChunk.complete();
        return chunk;
      }).toList();
      final cancelled = expectLater(
        reading,
        throwsA(
          isA<TransportException>().having(
            (error) => error.failure,
            'failure',
            TransportFailure.cancelled,
          ),
        ),
      );
      await receivedChunk.future;
      cancellation.cancel();
      await cancelled;
      release.complete();
    },
  );

  test(
    'explicit stream cancellation leaves the HTTP client reusable',
    () async {
      final transport = createTransport();
      final release = Completer<void>();
      final receivedChunk = Completer<void>();
      api.handle = (request) => request.uri.path.endsWith('/stream')
          ? WireReply.custom((response) async {
              response.add([1, 2, 3]);
              await response.flush();
              await release.future;
              await response.close();
            })
          : WireReply.json({'ok': true});
      final response = await transport.send('GET', [
        'stream',
      ], authenticated: false);
      final subscription = response.stream.listen((_) {
        if (!receivedChunk.isCompleted) receivedChunk.complete();
      });
      await receivedChunk.future;
      await subscription.cancel();
      release.complete();
      expect(
        (await transport.request('GET', ['next'], authenticated: false)).data,
        {'ok': true},
      );
    },
  );

  test(
    'client close aborts active HTTP work and rejects later calls',
    () async {
      final transport = createTransport();
      final release = Completer<WireReply>();
      api.handle = (_) => release.future;
      final pending = transport.request('GET', ['read'], authenticated: false);
      final rejected = expectLater(
        pending,
        throwsA(
          isA<TransportException>().having(
            (error) => error.failure,
            'failure',
            TransportFailure.cancelled,
          ),
        ),
      );
      await api.waitFor('/read');
      transport.close();
      await rejected;
      release.complete(WireReply.empty());
      await expectLater(
        transport.request('GET', ['read'], authenticated: false),
        throwsA(isA<ClientClosedException>()),
      );
    },
  );

  test(
    'injected HTTP client remains usable unless ownership is transferred',
    () async {
      api.handle = (_) => WireReply.json(true);
      final shared = http.Client();
      addTearDown(shared.close);
      final transport = createTransport(client: shared);
      transport.close();
      expect((await shared.get(api.origin.resolve('/health'))).statusCode, 200);

      final owned = http.Client();
      final owningTransport = createTransport(client: owned, closeClient: true);
      owningTransport.close();
      await expectLater(
        owned.get(api.origin.resolve('/health')),
        throwsA(isA<http.ClientException>()),
      );
      expect(api.at('/health').length, 1);
    },
  );

  test(
    'redirects are rejected without forwarding Bearer credentials',
    () async {
      final external = await LocalApi.start();
      addTearDown(external.close);
      external.handle = (_) => WireReply.json(true);
      final transport = createTransport();
      transport.provideAccessToken = () async => 'synthetic-access-token';
      api.handle = (_) => WireReply.text(
        '',
        status: 302,
        headers: {'location': external.origin.resolve('/capture').toString()},
      );
      await expectLater(
        transport.request('GET', ['redirect']),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            302,
          ),
        ),
      );
      expect(
        api.requests.single.authorization,
        'Bearer synthetic-access-token',
      );
      expect(external.requests, isEmpty);
    },
  );

  test(
    'signed URL downloads use real HTTP without API auth or cookies',
    () async {
      final external = await LocalApi.start();
      addTearDown(external.close);
      external.handle = (_) => WireReply.bytes([1, 2, 3, 4]);
      final transport = createTransport();
      transport.provideAccessToken = () =>
          throw StateError('Must not request credentials');
      final response = await transport.download(
        external.origin.resolve('/file?signature=test'),
      );
      expect(await response.stream.expand((bytes) => bytes).toList(), [
        1,
        2,
        3,
        4,
      ]);
      expect(external.requests.single.authorization, isNull);
      expect(external.requests.single.headers['cookie'], isNull);
      expect(external.requests.single.uri.queryParameters, {
        'signature': 'test',
      });
      expect(api.requests, isEmpty);
    },
  );

  test(
    'request factories cannot redirect destinations or inject credentials',
    () async {
      final transport = createTransport();
      for (final header in ['Authorization', 'X-Api-Key', 'Cookie']) {
        await expectLater(
          transport.send(
            'GET',
            ['read'],
            authenticated: false,
            requestFactory: (uri, abort) =>
                http.AbortableRequest('GET', uri, abortTrigger: abort)
                  ..headers[header] = 'must-not-send',
          ),
          throwsArgumentError,
        );
      }
      await expectLater(
        transport.send(
          'GET',
          ['read'],
          authenticated: false,
          requestFactory: (uri, abort) => http.AbortableRequest(
            'GET',
            uri.replace(host: 'example.test'),
            abortTrigger: abort,
          ),
        ),
        throwsArgumentError,
      );
      expect(api.requests, isEmpty);
    },
  );

  test(
    'origin path segment and download validation rejects unsafe URLs',
    () async {
      for (final origin in [
        'http://example.test',
        'https://user:pass@example.test',
        'https://example.test/api',
        'https://example.test?key=secret',
        'https://example.test#fragment',
      ]) {
        expect(
          () => ApiTransport(apiOrigin: Uri.parse(origin), projectId: 'test'),
          throwsArgumentError,
        );
      }
      expect(
        () => ApiTransport(apiOrigin: api.origin, projectId: 'test'),
        throwsArgumentError,
      );
      final transport = createTransport();
      for (final segment in ['', '.', '..', 'a/b', 'a\\b', 'a\u0000b']) {
        expect(() => transport.uriFor([segment]), throwsArgumentError);
      }
      for (final url in [
        'http://example.test/file',
        'https://user:pass@example.test/file',
        'https://example.test/file#fragment',
        'file:///tmp/file',
      ]) {
        await expectLater(
          transport.download(Uri.parse(url)),
          throwsArgumentError,
        );
      }
      expect(api.requests, isEmpty);
    },
  );

  test(
    'response byte limit applies to successful and unsuccessful bodies',
    () async {
      final transport = createTransport(maxBytes: 32);
      for (final status in [200, 503]) {
        api.handle = (_) => WireReply.text('x' * 33, status: status);
        await expectLater(
          transport.request('GET', ['large'], authenticated: false),
          throwsA(isA<ProtocolException>()),
        );
      }
      api.handle = (_) => WireReply.text('x' * 32);
      expect(
        (await transport.request('GET', [
          'bounded',
        ], authenticated: false)).data,
        'x' * 32,
      );
    },
  );
}
