import 'package:anythink_dart/anythink_dart.dart';
import 'package:test/test.dart';

import '../files/local_server.dart';

Map<String, Object?> _options() => {
  'primary_provider': 'stripe_web',
  'providers': ['stripe_web', 'apple'],
  'web_checkout_allowed': true,
  'storefront': 'USA',
};

void main() {
  test(
    'reads payment routing with authenticated platform/storefront query',
    () async {
      final server = await LocalServer.start((request) async {
        expect(request.method, 'GET');
        expect(
          request.uri.path,
          '/org/42/integrations/anythinkpay/payment-options',
        );
        expect(request.uri.queryParameters, {
          'platform': 'ios',
          'storefront': 'USA',
        });
        expect(request.headers.value('authorization'), 'Bearer fixture-access');
        expect(await request.fold<int>(0, (n, bytes) => n + bytes.length), 0);
        await respondJson(request, {..._options(), 'future_rule': true});
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final result = await SubscriptionsApi(
        transport,
      ).paymentOptions(platform: 'ios', storefront: 'USA');
      expect(result.primaryProvider, 'stripe_web');
      expect(result.providers, ['stripe_web', 'apple']);
      expect(result.webCheckoutAllowed, true);
      expect(result.storefront, 'USA');
      expect(result.data['future_rule'], true);
    },
  );

  test(
    'does not invent platform policy or reject unknown provider identifiers',
    () async {
      final server = await LocalServer.start((request) async {
        expect(request.uri.queryParameters, {'platform': 'future_platform'});
        await respondJson(request, {
          'primary_provider': 'future_provider',
          'providers': ['future_provider', 'apple'],
          'web_checkout_allowed': false,
          'storefront': null,
        });
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final result = await SubscriptionsApi(
        transport,
      ).paymentOptions(platform: 'future_platform');
      expect(result.primaryProvider, 'future_provider');
      expect(result.providers, ['future_provider', 'apple']);
      expect(result.webCheckoutAllowed, false);
      expect(result.storefront, isNull);
      expect(result.toString(), isNot(contains('future_provider')));
    },
  );

  test(
    'malformed routing fields fail explicitly through the real transport',
    () async {
      Object? payload;
      final server = await LocalServer.start(
        (request) async => respondJson(request, payload),
      );
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      final malformed = <Object?>[
        [],
        {..._options(), 'primary_provider': null},
        {..._options(), 'primary_provider': ''},
        {..._options(), 'providers': 'stripe_web'},
        {..._options(), 'providers': <Object?>[]},
        {
          ..._options(),
          'providers': [''],
        },
        {
          ..._options(),
          'providers': [1],
        },
        {
          ..._options(),
          'providers': ['apple'],
        },
        {..._options(), 'web_checkout_allowed': 'true'},
        {..._options(), 'storefront': 44},
      ];
      for (final value in malformed) {
        payload = value;
        await expectLater(
          SubscriptionsApi(transport).paymentOptions(platform: 'ios'),
          throwsA(isA<ProtocolException>()),
        );
      }
    },
  );

  test(
    'routing provider order is immutable and detached from source lists',
    () {
      final input = _options();
      final nested = <Object?>[
        1.5,
        {'active': true},
      ];
      input['metadata'] = {'nested': nested};
      final result = PaymentOptions.fromJson(input);
      (input['providers'] as List<String>).clear();
      nested.clear();
      expect(result.providers, ['stripe_web', 'apple']);
      expect(result.data['providers'], ['stripe_web', 'apple']);
      expect(result.data['metadata'], {
        'nested': [
          1.5,
          {'active': true},
        ],
      });
      expect(() => result.providers.add('other'), throwsUnsupportedError);
      expect(
        () => (result.data['providers'] as List).clear(),
        throwsUnsupportedError,
      );
      final metadata = result.data['metadata'] as Map;
      expect(() => metadata.clear(), throwsUnsupportedError);
      expect(
        () => (metadata['nested'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => result.data['primary_provider'] = 'other',
        throwsUnsupportedError,
      );
    },
  );

  test('raw payment metadata rejects cycles and non-JSON values safely', () {
    final listCycle = <Object?>[];
    listCycle.add(listCycle);
    final mapCycle = <String, Object?>{};
    mapCycle['self'] = mapCycle;
    for (final value in [listCycle, mapCycle, double.nan, Object()]) {
      expect(
        () => PaymentOptions.fromJson({..._options(), 'metadata': value}),
        throwsA(isA<ProtocolException>()),
      );
    }
  });

  test('read can recover once from 401 with the same routing query', () async {
    var calls = 0;
    var refreshes = 0;
    final server = await LocalServer.start((request) async {
      calls++;
      expect(request.uri.queryParameters, {
        'platform': 'ios',
        'storefront': 'GBR',
      });
      if (calls == 1) {
        await respondJson(request, {'title': 'unauthorized'}, status: 401);
      } else {
        expect(request.headers.value('authorization'), 'Bearer replacement');
        await respondJson(request, _options());
      }
    });
    final transport = server.transport()
      ..recoverAccessToken = (_) async {
        refreshes++;
        return 'replacement';
      };
    addTearDown(() async {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    });
    await SubscriptionsApi(
      transport,
    ).paymentOptions(platform: 'ios', storefront: 'GBR');
    expect(calls, 2);
    expect(refreshes, 1);
  });

  test(
    'forbidden routing read is not treated as an auth-refresh problem',
    () async {
      var refreshes = 0;
      final server = await LocalServer.start((request) async {
        await respondJson(request, {'title': 'forbidden'}, status: 403);
      });
      final transport = server.transport()
        ..recoverAccessToken = (_) async {
          refreshes++;
          return 'replacement';
        };
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      await expectLater(
        SubscriptionsApi(transport).paymentOptions(platform: 'android'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
      );
      expect(refreshes, 0);
    },
  );

  test(
    'invalid routing arguments and pre-cancellation send no request',
    () async {
      var calls = 0;
      final server = await LocalServer.start((request) async {
        calls++;
        await respondJson(request, _options());
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      final api = SubscriptionsApi(transport);
      await expectLater(api.paymentOptions(platform: ''), throwsArgumentError);
      await expectLater(
        api.paymentOptions(platform: ' ios'),
        throwsArgumentError,
      );
      await expectLater(
        api.paymentOptions(platform: 'ios', storefront: ' '),
        throwsArgumentError,
      );
      await expectLater(
        api.paymentOptions(
          platform: 'ios',
          cancellation: CancellationToken()..cancel(),
        ),
        throwsA(
          isA<TransportException>().having(
            (e) => e.outcomeUncertain,
            'read',
            false,
          ),
        ),
      );
      expect(calls, 0);
    },
  );
}
