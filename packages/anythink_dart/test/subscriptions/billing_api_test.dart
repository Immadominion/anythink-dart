import 'dart:io';
import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_dart/src/http/api_transport.dart';
import 'package:test/test.dart';
import '../files/local_server.dart';

const pay = '/org/42/integrations/anythinkpay';
const subscriptionId = '11111111-1111-1111-1111-111111111111';
Map<String, Object?> plan() => {
  'id': 8,
  'plan_name': 'Pro',
  'name': 'Pro monthly',
  'description': 'Full access',
  'type': 'web',
  'amount': 9.99,
  'currency': 'gbp',
  'billing_interval': 'month',
  'interval_count': 1,
  'is_active': true,
  'trial_period_days': 7,
  'apple_product_id': null,
  'reference': 'catalog-reference',
};
Map<String, Object?> subscription() => {
  'id': subscriptionId,
  'type': 'web',
  'provider': 'stripe',
  'name': 'Pro monthly',
  'description': null,
  'amount': 9.99,
  'currency': 'gbp',
  'billing_interval': 'month',
  'interval_count': 1,
  'status': 'new_future_status',
  'created_at': '2026-10-14T10:00:00Z',
  'updated_at': '2026-10-14T10:01:00Z',
  'current_period_ends_at': null,
  'customer_email': 'synthetic@example.test',
};
Map<String, Object?> page([List<Object?> items = const []]) => {
  'items': items,
  'page': 1,
  'page_size': 25,
  'total_items': items.length,
  'total_pages': items.isEmpty ? 0 : 1,
  'has_next_page': false,
  'has_previous_page': false,
  'retrieval_time': 1,
};

void main() {
  Future<T> withApi<T>(
    Future<void> Function(HttpRequest) handler,
    Future<T> Function(SubscriptionsApi, ApiTransport) action,
  ) async {
    final server = await LocalServer.start(handler);
    final transport = server.transport();
    try {
      return await action(SubscriptionsApi(transport), transport);
    } finally {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    }
  }

  test(
    'plan catalog uses authenticated list/get and preserves decimal price',
    () async {
      final paths = <String>[];
      await withApi(
        (r) async {
          expect(r.method, 'GET');
          expect(r.headers.value('authorization'), 'Bearer fixture-access');
          paths.add(r.uri.path);
          await respondJson(r, r.uri.path.endsWith('/8') ? plan() : [plan()]);
        },
        (api, t) async {
          final result = await api.listPlans();
          final detail = await api.getPlan(8);
          expect(result.single.amount, 9.99);
          expect(detail.trialPeriodDays, 7);
          expect(detail.reference, 'catalog-reference');
          expect(() => result.clear(), throwsUnsupportedError);
          expect(detail.data['amount'], 9.99);
        },
      );
      expect(paths, ['$pay/subscription-plans', '$pay/subscription-plans/8']);
    },
  );
  test(
    'subscriptions list get status filter and events follow distinct wire shapes',
    () async {
      final paths = <String>[];
      await withApi(
        (r) async {
          paths.add(r.uri.path);
          expect(r.method, 'GET');
          if (r.uri.path.endsWith('/events')) {
            await respondJson(r, [
              {
                'id': subscriptionId,
                'event_type': 'created',
                'source': 'future_source',
                'occurred_at': '2026-10-14T10:00:00Z',
              },
            ]);
          } else if (r.uri.path.endsWith('/$subscriptionId')) {
            await respondJson(r, subscription());
          } else {
            expect(
              r.uri.queryParameters,
              r.uri.path.contains('/status/')
                  ? <String, String>{}
                  : {'page': '1', 'pageSize': '25'},
            );
            await respondJson(r, page([subscription()]));
          }
        },
        (api, t) async {
          final result = await api.list();
          expect(result.items.single.status, 'new_future_status');
          expect(result.items.single.currentPeriodEndsAt, isNull);
          expect(result.hasNextPage, false);
          expect(result.retrievalTime, const Duration(milliseconds: 1));
          await api.listByStatus('active');
          expect((await api.get(subscriptionId)).provider, 'stripe');
          expect(
            (await api.events(subscriptionId)).single.source,
            'future_source',
          );
        },
      );
      expect(paths, [
        '$pay/subscriptions',
        '$pay/subscriptions/status/active',
        '$pay/subscriptions/$subscriptionId',
        '$pay/subscriptions/$subscriptionId/events',
      ]);
    },
  );
  test(
    'named access escapes query and false is preserved without fabricated subscription',
    () async {
      await withApi(
        (r) async {
          expect(r.uri.path, '$pay/subscriptions/check-access');
          expect(r.uri.queryParameters, {
            'subscription_name': 'Pro & 東京',
            'status': 'active',
          });
          await respondJson(r, {'has_access': false, 'subscription': null});
        },
        (api, t) async {
          final r = await api.checkAccess(
            subscriptionName: 'Pro & 東京',
            status: 'active',
          );
          expect(r.hasAccess, false);
          expect(r.subscription, isNull);
        },
      );
    },
  );
  test(
    'subscription checkout copies plan values and snapshots private metadata',
    () async {
      final metadata = <String, Object?>{
        'nested': <Object?>['before'],
      };
      final request = SubscriptionCheckoutRequest.fromPlan(
        SubscriptionPlan.fromJson(plan()),
        customerEmail: 'synthetic@example.test',
        subscriberId: 51,
        successUrl: Uri.parse('app.example://checkout/return'),
        metadata: metadata,
      );
      (metadata['nested'] as List).add('after');
      await withApi(
        (r) async {
          expect(r.method, 'POST');
          expect(r.uri.path, '$pay/subscriptions');
          expect(await readJson(r), {
            'name': 'Pro monthly',
            'description': 'Full access',
            'type': 'web',
            'amount': 9.99,
            'currency': 'gbp',
            'billing_interval': 'month',
            'interval_count': 1,
            'customer_email': 'synthetic@example.test',
            'trial_period_days': 7,
            'reference': 'catalog-reference',
            'subscriber_id': 51,
            'success_url': 'app.example://checkout/return',
            'metadata': {
              'nested': ['before'],
            },
          });
          await respondJson(r, {
            'anythink_pay_id': subscriptionId,
            'checkout_url': 'https://checkout.example.test/private',
            'session_id': 'synthetic-checkout-session',
          });
        },
        (api, t) async {
          final r = await api.createCheckout(request);
          expect(r.id, subscriptionId);
          expect(r.sessionId, 'synthetic-checkout-session');
          expect(r.toString(), isNot(contains('session')));
          expect(request.toString(), isNot(contains('synthetic@example')));
        },
      );
    },
  );
  test(
    'cancel resume acknowledge empty success without inventing response fields',
    () async {
      final operations = <String>[];
      await withApi(
        (r) async {
          expect(r.method, 'POST');
          expect(await readJson(r), isEmpty);
          operations.add(r.uri.pathSegments.last);
          r.response.statusCode = r.uri.path.endsWith('/cancel') ? 200 : 204;
          await r.response.close();
        },
        (api, t) async {
          await api.cancel(subscriptionId);
          await api.resume(subscriptionId);
        },
      );
      expect(operations, ['cancel', 'resume']);
    },
  );
  test(
    'personal referral routes decode observed shapes and retain opaque immutable detail',
    () async {
      final calls = <String>[];
      final code = <String, Object?>{
        'slug': 'synthetic-code',
        'offer_id': subscriptionId,
        'redemption_count': 0,
        'offer_name': 'Synthetic referral',
      };
      await withApi(
        (r) async {
          calls.add(r.uri.pathSegments.last);
          expect(r.method, 'GET');
          if (r.uri.path.endsWith('/referrals')) {
            await respondJson(r, {
              'personal_code_slug': 'synthetic-code',
              'redemption_count': 1,
              'rewards_applied': 0,
              'rewards_pending': 1,
              'recent': [
                {
                  'future': ['opaque'],
                },
              ],
              'tier_progress': {'future': true},
            });
          } else {
            await respondJson(r, r.uri.path.endsWith('/codes') ? [code] : code);
          }
        },
        (api, t) async {
          expect((await api.personalReferralCode()).slug, 'synthetic-code');
          expect(
            (await api.personalReferralCodes()).single.offerId,
            subscriptionId,
          );
          final stats = await api.referralStats();
          expect(stats.rewardsPending, 1);
          expect((stats.tierProgress as Map)['future'], true);
          expect(
            () => ((stats.recent.single as Map)['future'] as List).clear(),
            throwsUnsupportedError,
          );
          expect(stats.toString(), isNot(contains('synthetic-code')));
        },
      );
      expect(calls, ['code', 'codes', 'referrals']);
    },
  );
  test(
    'lazy personal-code reads do not replay401 and missing referral counters fail',
    () async {
      var calls = 0, refreshes = 0;
      await withApi(
        (r) async {
          calls++;
          await respondJson(r, {}, status: 401);
        },
        (api, t) async {
          t.recoverAccessToken = (_) async {
            refreshes++;
            return 'renewed';
          };
          await expectLater(
            api.personalReferralCode(),
            throwsA(isA<ApiException>()),
          );
          await expectLater(
            api.personalReferralCodes(),
            throwsA(isA<ApiException>()),
          );
          await expectLater(api.referralStats(), throwsA(isA<ApiException>()));
          expect(calls, 3);
          expect(refreshes, 0);
        },
      );
      expect(
        () => ReferralStats.fromJson({
          'personal_code_slug': null,
          'recent': <Object?>[],
        }),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
  test(
    'balance uses integer minor units and accepts zero negative and unknown unit',
    () async {
      await withApi(
        (r) async {
          expect(r.uri.path, '$pay/balances/me');
          await respondJson(r, [
            {'unit_type': 'credit', 'currency': 'gbp', 'total': 500},
            {'unit_type': 'points', 'currency': null, 'total': 0},
            {'unit_type': 'future', 'currency': null, 'total': -1},
          ]);
        },
        (api, t) async {
          final b = await api.balances();
          expect(b.map((v) => v.total), [500, 0, -1]);
          expect(b.first.currency, 'gbp');
        },
      );
    },
  );
  test(
    'rejected HTTP200 offer redemption remains false and sends no invented body',
    () async {
      await withApi(
        (r) async {
          expect(r.method, 'POST');
          expect(r.uri.path, '$pay/offers/me/redeem/WELCOME%2014');
          expect(r.uri.queryParameters, {'subscription_id': subscriptionId});
          expect(await r.isEmpty, true);
          await respondJson(r, {
            'success': false,
            'rejection_reason': 'Already redeemed',
            'redemption_id': null,
            'redeemer_reward_summary': null,
            'referrer_reward_queued': false,
          });
        },
        (api, t) async {
          final result = await api.redeemOffer(
            'WELCOME 14',
            subscriptionId: subscriptionId,
          );
          expect(result.success, false);
          expect(result.rejectionReason, 'Already redeemed');
          expect(result.redemptionId, isNull);
        },
      );
    },
  );
  test(
    'read retries only once on401 but billing mutations never replay',
    () async {
      var requests = 0, refreshes = 0;
      await withApi(
        (r) async {
          requests++;
          await respondJson(r, {'title': 'Unauthorized'}, status: 401);
        },
        (api, t) async {
          t.recoverAccessToken = (_) async {
            refreshes++;
            return 'synthetic-renewed';
          };
          await expectLater(api.listPlans(), throwsA(isA<ApiException>()));
          expect(requests, 2);
          expect(refreshes, 1);
          for (final op in [
            () => api.cancel(subscriptionId),
            () => api.resume(subscriptionId),
            () => api.redeemOffer('X'),
            () => api.createCheckout(
              SubscriptionCheckoutRequest.fromPlan(
                SubscriptionPlan.fromJson(plan()),
                customerEmail: 'synthetic@example.test',
              ),
            ),
          ]) {
            final before = requests;
            await expectLater(op(), throwsA(isA<ApiException>()));
            expect(requests, before + 1);
            expect(refreshes, 1);
          }
        },
      );
    },
  );
  test('invalid inputs and pre-cancelled writes never reach network', () async {
    var calls = 0;
    await withApi(
      (r) async {
        calls++;
        await respondJson(r, {});
      },
      (api, t) async {
        await expectLater(api.list(page: 0), throwsArgumentError);
        await expectLater(api.list(pageSize: 1001), throwsArgumentError);
        await expectLater(
          api.checkAccess(subscriptionName: ' '),
          throwsArgumentError,
        );
        await expectLater(api.get('../bad'), throwsArgumentError);
        await expectLater(api.redeemOffer(' '), throwsArgumentError);
        final token = CancellationToken()..cancel();
        await expectLater(
          api.cancel(subscriptionId, cancellation: token),
          throwsA(
            isA<TransportException>().having(
              (e) => e.failure,
              'failure',
              TransportFailure.cancelled,
            ),
          ),
        );
        expect(calls, 0);
      },
    );
  });
  test(
    'billing responses reject missing access decisions and malformed dates',
    () {
      expect(
        () => OfferRedemption.fromJson({'referrer_reward_queued': false}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => NamedSubscriptionAccess.fromJson({}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => UserBalance.fromJson({
          'unit_type': 'credit',
          'currency': 'gbp',
          'total': 5.5,
        }),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => UserSubscription.fromJson({
          ...subscription(),
          'created_at': '2026-02-30T00:00:00Z',
        }),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => SubscriptionPlan.fromJson({...plan(), 'amount': double.infinity}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => SubscriptionPage.fromJson({'items': []}),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
  test(
    'billing snapshots are deeply immutable and reject cycles without leaking contents',
    () {
      final nested = <String, Object?>{
        'values': <Object?>['original'],
      };
      final input = {...plan(), 'unknown': nested};
      final result = SubscriptionPlan.fromJson(input);
      (nested['values'] as List).add('later');
      expect((result.data['unknown'] as Map)['values'], ['original']);
      expect(
        () => ((result.data['unknown'] as Map)['values'] as List).add('bad'),
        throwsUnsupportedError,
      );
      final cyclic = <String, Object?>{};
      cyclic['secret'] = cyclic;
      expect(
        () => SubscriptionPlan.fromJson({...plan(), 'unknown': cyclic}),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
}
