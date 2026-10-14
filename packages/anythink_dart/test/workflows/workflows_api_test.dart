import 'dart:async';
import 'dart:convert';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:test/test.dart';

import '../files/local_server.dart';

void main() {
  test('API route sends raw JSON and trigger query with user auth', () async {
    var requests = 0;
    final server = await LocalServer.start((request) async {
      requests++;
      expect(request.method, 'POST');
      expect(request.uri.path, '/org/42/workflows/api/Sync-Orders');
      expect(request.uri.queryParameters, {
        'id': '1042',
        'entity_name': 'orders',
      });
      expect(request.headers.value('authorization'), 'Bearer fixture-access');
      expect(request.headers.value('x-api-key'), isNull);
      expect(await readJson(request), {
        'source': 'shopify',
        'nested': [true, 4.5, null],
      });
      await respondJson(request, null, status: 204);
    });
    final transport = server.transport();
    addTearDown(() async {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    });
    await WorkflowsApi(transport).triggerApi(
      'Sync-Orders',
      id: 1042,
      entityName: 'orders',
      data: {
        'source': 'shopify',
        'nested': [true, 4.5, null],
      },
    );
    expect(requests, 1); // No fabricated job lookup or completion polling.
  });

  test('manual trigger encodes the payload as a JSON string field', () async {
    final server = await LocalServer.start((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/org/42/workflows/51/trigger');
      expect(request.uri.queryParameters, isEmpty);
      expect(await readJson(request), {
        'entity_name': 'orders',
        'entity_id': 1042,
        'data': '{"reason":"manual resend","items":[1,2]}',
      });
      await respondJson(request, null, status: 204);
    });
    final transport = server.transport();
    addTearDown(() async {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    });
    await WorkflowsApi(transport).trigger(
      51,
      entityName: 'orders',
      entityId: 1042,
      data: {
        'reason': 'manual resend',
        'items': [1, 2],
      },
    );
  });

  test(
    'optional values are omitted and API empty-body semantics survive',
    () async {
      var requests = 0;
      final server = await LocalServer.start((request) async {
        requests++;
        expect(request.uri.queryParameters, isEmpty);
        final body = await utf8.decoder.bind(request).join();
        if (request.uri.path.endsWith('/api/empty')) {
          expect(body, isEmpty);
          expect(request.headers.contentType, isNull);
        } else {
          expect(request.uri.path, '/org/42/workflows/5/trigger');
          expect(jsonDecode(body), isEmpty);
        }
        await respondJson(request, null, status: 204);
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final api = WorkflowsApi(transport);
      await api.triggerApi('empty');
      await api.trigger(5); // Other configured trigger types need no entity.
      expect(requests, 2);
    },
  );

  test('JSON arrays and scalar payloads retain their wire types', () async {
    final bodies = <Object?>[];
    final server = await LocalServer.start((request) async {
      bodies.add(await readJson(request));
      await respondJson(request, null, status: 204);
    });
    final transport = server.transport();
    addTearDown(() async {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    });
    final api = WorkflowsApi(transport);
    await api.triggerApi('event', data: [1, false, 'text']);
    await api.triggerApi('event', data: true);
    await api.trigger(5, data: 'text');
    expect(bodies, [
      [1, false, 'text'],
      true,
      {'data': '"text"'},
    ]);
  });

  test(
    'nested payload snapshots precede asynchronous token acquisition',
    () async {
      final authReady = Completer<String>();
      final bodies = <Object?>[];
      final server = await LocalServer.start((request) async {
        bodies.add(await readJson(request));
        await respondJson(request, null, status: 204);
      });
      final transport = server.transport()
        ..provideAccessToken = () => authReady.future;
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final api = WorkflowsApi(transport);
      final nested = <String, Object?>{'value': 1};
      final list = <Object?>[nested];
      final data = <String, Object?>{'items': list};
      final first = api.triggerApi('event', data: data);
      final second = api.trigger(5, data: data);
      nested['value'] = 99;
      list.add('late');
      data['late'] = true;
      authReady.complete('fixture-access');
      await Future.wait([first, second]);
      expect(
        bodies,
        unorderedEquals([
          {
            'items': [
              {'value': 1},
            ],
          },
          {'data': '{"items":[{"value":1}]}'},
        ]),
      );
    },
  );

  test(
    'invalid paths, IDs and non-JSON inputs never reach the server',
    () async {
      var requests = 0;
      final server = await LocalServer.start((request) async {
        requests++;
        await respondJson(request, null, status: 204);
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      final api = WorkflowsApi(transport);
      for (final route in [
        '',
        ' ',
        ' route',
        '.',
        '..',
        'a/b',
        'a\\b',
        'a\n',
      ]) {
        await expectLater(api.triggerApi(route), throwsArgumentError);
      }
      await expectLater(api.trigger(0), throwsArgumentError);
      await expectLater(api.trigger(1, entityId: -1), throwsArgumentError);
      await expectLater(api.triggerApi('event', id: 0), throwsArgumentError);
      await expectLater(api.trigger(1, entityName: ''), throwsArgumentError);
      final cycle = <Object?>[];
      cycle.add(cycle);
      final mapCycle = <String, Object?>{};
      mapCycle['self'] = mapCycle;
      for (final data in [
        double.nan,
        double.infinity,
        cycle,
        mapCycle,
        _PrivateInput(),
      ]) {
        await expectLater(
          api.triggerApi('event', data: data),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'redacted',
              isNot(contains('private-value')),
            ),
          ),
        );
        await expectLater(api.trigger(1, data: data), throwsArgumentError);
      }
      expect(requests, 0);
    },
  );

  test('401, 403 and 404 are surfaced without replaying invocation', () async {
    var status = 401;
    var requests = 0;
    var recoveries = 0;
    final server = await LocalServer.start((request) async {
      requests++;
      await respondJson(request, {
        'title': 'fixture-rejection',
      }, status: status);
    });
    final transport = server.transport()
      ..recoverAccessToken = (_) async {
        recoveries++;
        return 'replacement';
      };
    addTearDown(() async {
      transport.close();
      await server.close();
    });
    for (final code in [401, 403, 404]) {
      status = code;
      await expectLater(
        WorkflowsApi(transport).triggerApi('event'),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'status', code),
        ),
      );
    }
    expect(requests, 3);
    expect(recoveries, 0);
  });

  test(
    'a lost response is uncertain and never invokes the workflow twice',
    () async {
      var requests = 0;
      final release = Completer<void>();
      final server = await LocalServer.start((request) async {
        requests++;
        await release.future;
        await respondJson(request, null, status: 204);
      });
      final transport = server.transport(
        timeout: const Duration(milliseconds: 250),
      );
      addTearDown(() async {
        release.complete();
        transport.close();
        await server.close();
      });
      await expectLater(
        WorkflowsApi(transport).trigger(5),
        throwsA(
          isA<TransportException>().having(
            (e) => e.outcomeUncertain,
            'uncertain',
            true,
          ),
        ),
      );
      expect(requests, 1);
    },
  );

  test('cancellation before send or during invocation is explicit', () async {
    var requests = 0;
    final started = Completer<void>();
    final release = Completer<void>();
    final server = await LocalServer.start((request) async {
      requests++;
      started.complete();
      await release.future;
      await respondJson(request, null, status: 204);
    });
    final transport = server.transport();
    addTearDown(() async {
      release.complete();
      transport.close();
      await server.close();
    });
    final api = WorkflowsApi(transport);
    await expectLater(
      api.triggerApi('event', cancellation: CancellationToken()..cancel()),
      throwsA(
        isA<TransportException>().having(
          (e) => e.outcomeUncertain,
          'preflight',
          false,
        ),
      ),
    );
    expect(requests, 0);
    final cancel = CancellationToken();
    final pending = api.trigger(1, cancellation: cancel);
    await started.future;
    cancel.cancel();
    await expectLater(
      pending,
      throwsA(
        isA<TransportException>().having(
          (e) => e.outcomeUncertain,
          'in flight',
          true,
        ),
      ),
    );
    expect(requests, 1);
  });

  test(
    'unexpected successful response is not a queued acknowledgment',
    () async {
      final server = await LocalServer.start((request) async {
        await respondJson(request, {'fake_job_id': 9});
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      await expectLater(
        WorkflowsApi(transport).trigger(1),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
}

final class _PrivateInput {
  @override
  String toString() => 'private-value';
}
