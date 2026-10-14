import 'package:anythink_dart/subscriptions.dart';
import 'package:anythink_dart/src/cancellation.dart';
import 'package:anythink_dart/src/errors.dart';
import 'package:test/test.dart';

import '../files/local_server.dart';

Map<String, Object?> verification({bool known = true}) => {
  'subscription_id': 'subscription-fixture',
  'bound_user_id': 51,
  'provider': 'apple',
  'product_id': 'com.example.pro',
  'plan_name': known ? 'Pro' : null,
  'plan_id': known ? 4 : null,
  'status': 'active',
  'expires_at': '2030-01-01T00:00:00Z',
  'has_access': true,
  'matched_known_plan': known,
};

void main() {
  test(
    'entitlement reads user endpoint and preserves nullable trial state',
    () async {
      final server = await LocalServer.start((request) async {
        expect(request.method, 'GET');
        expect(
          request.uri.path,
          '/org/42/integrations/anythinkpay/subscriptions/me/entitlement',
        );
        expect(request.headers.value('authorization'), 'Bearer fixture-access');
        await respondJson(request, {
          'has_access': false,
          'subscription_id': null,
          'provider': null,
          'product_id': null,
          'status': null,
          'expires_at': null,
          'is_trial': false,
          'trial_days_remaining': null,
          'future_server_field': 12,
        });
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final result = await SubscriptionsApi(transport).entitlement();
      expect(result.hasAccess, false);
      expect(result.subscriptionId, isNull);
      expect(result.trialDaysRemaining, isNull);
      expect(result.data['future_server_field'], 12);
    },
  );

  test(
    'Apple verify posts a single proof and refuses unknown-plan access',
    () async {
      final requests = <Object?>[];
      final server = await LocalServer.start((request) async {
        expect(request.method, 'POST');
        expect(
          request.uri.path,
          '/org/42/integrations/anythinkpay/subscriptions/apple/verify',
        );
        requests.add(await readJson(request));
        await respondJson(request, verification(known: false));
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final api = SubscriptionsApi(transport);
      final result = await api.verifyApple(
        signedTransaction: 'fixture.jws.proof',
      );
      await api.verifyApple(originalTransactionId: '123456');
      expect(requests, [
        {'signed_transaction': 'fixture.jws.proof'},
        {'original_transaction_id': '123456'},
      ]);
      expect(result.hasAccess, true);
      expect(result.matchedKnownPlan, false);
      expect(result.hasKnownPlanAccess, false);
      expect(result.planId, isNull);
    },
  );

  test('repeat-safe Apple verification opts into one auth replay', () async {
    var requests = 0;
    var refreshes = 0;
    final server = await LocalServer.start((request) async {
      requests++;
      expect(await readJson(request), {'signed_transaction': 'fixture.proof'});
      if (requests == 1) {
        await respondJson(request, {'title': 'Unauthorized'}, status: 401);
      } else {
        expect(
          request.headers.value('authorization'),
          'Bearer refreshed-fixture',
        );
        await respondJson(request, verification());
      }
    });
    final transport = server.transport()
      ..recoverAccessToken = (_) async {
        refreshes++;
        return 'refreshed-fixture';
      };
    addTearDown(() async {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    });
    final result = await SubscriptionsApi(
      transport,
    ).verifyApple(signedTransaction: 'fixture.proof');
    expect(result.hasKnownPlanAccess, true);
    expect(requests, 2);
    expect(refreshes, 1);
  });

  test('proof ambiguity and cancellation cause no server mutation', () async {
    var count = 0;
    final server = await LocalServer.start((request) async {
      count++;
      await request.response.close();
    });
    final transport = server.transport();
    addTearDown(() async {
      transport.close();
      await server.close();
    });
    final api = SubscriptionsApi(transport);
    await expectLater(api.verifyApple(), throwsArgumentError);
    await expectLater(
      api.verifyApple(signedTransaction: 'a', originalTransactionId: 'b'),
      throwsArgumentError,
    );
    await expectLater(
      api.verifyApple(signedTransaction: ' '),
      throwsArgumentError,
    );
    await expectLater(
      api.verifyApple(
        signedTransaction: 'a',
        cancellation: CancellationToken()..cancel(),
      ),
      throwsA(isA<TransportException>()),
    );
    expect(count, 0);
  });
}
