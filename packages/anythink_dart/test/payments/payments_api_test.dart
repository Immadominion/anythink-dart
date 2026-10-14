import 'dart:async';
import 'dart:io';
import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_dart/src/http/api_transport.dart';
import 'package:test/test.dart';
import '../files/local_server.dart';
import '../subscriptions/billing_api_test.dart' show page;

const base = '/org/42/integrations/anythinkpay';
const identifier = '11111111-1111-1111-1111-111111111111';
Map<String, Object?> method() => {
  'id': identifier,
  'type': 'card',
  'stripe_payment_method_id': 'pm_synthetic',
  'brand': 'visa',
  'last4': '4242',
  'exp_month': 12,
  'exp_year': 2030,
};
Map<String, Object?> intent() => {
  'anythink_pay_id': identifier,
  'payment_intent_id': 'pi_synthetic',
  'status': 'requires_action',
  'amount': 25.25,
  'currency': 'gbp',
  'client_secret': 'synthetic-sensitive-client-secret',
  'next_action': 'provider-action',
  'stripe_object': {
    'private': ['provider-data'],
  },
};
Map<String, Object?> payment() => {
  'id': identifier,
  'type': 'web',
  'provider': 'stripe',
  'amount': 25.25,
  'currency': 'gbp',
  'status': 'pending',
  'created_at': '2026-10-14T10:00:00Z',
};
void main() {
  Future<T> withApi<T>(
    Future<void> Function(HttpRequest) handler,
    Future<T> Function(PaymentsApi, ApiTransport) action,
  ) async {
    final server = await LocalServer.start(handler);
    final transport = server.transport();
    try {
      return await action(PaymentsApi(transport), transport);
    } finally {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    }
  }

  test(
    'one-off checkout serializes explicit typed inputs without changing amount or line items',
    () async {
      final request = PaymentCheckoutRequest(
        type: 'web',
        amount: 25.25,
        currency: 'gbp',
        description: 'Synthetic ticket',
        customerEmail: 'synthetic@example.test',
        lineItems: [
          PaymentLineItem(name: 'Ticket', unitAmount: 25.25, quantity: 1),
        ],
        successUrl: Uri.parse('app.example://success'),
      );
      await withApi(
        (r) async {
          expect(r.method, 'POST');
          expect(r.uri.path, '$base/payments');
          expect(r.headers.value('authorization'), 'Bearer fixture-access');
          expect(await readJson(r), {
            'type': 'web',
            'amount': 25.25,
            'currency': 'gbp',
            'description': 'Synthetic ticket',
            'customer_email': 'synthetic@example.test',
            'line_items': [
              {'name': 'Ticket', 'unit_amount': 25.25, 'quantity': 1},
            ],
            'success_url': 'app.example://success',
          });
          await respondJson(r, {
            'anythink_pay_id': identifier,
            'checkout_url': 'https://checkout.example.test/private',
            'session_id': 'cs_synthetic',
          });
        },
        (api, t) async {
          final result = await api.createCheckout(request);
          expect(result.id, identifier);
          expect(result.sessionId, 'cs_synthetic');
          expect(result.toString(), isNot(contains('cs_synthetic')));
          expect(request.toString(), isNot(contains('synthetic@example.test')));
        },
      );
    },
  );
  test(
    'payment reads and status filter preserve a real paginated envelope',
    () async {
      final paths = <String>[];
      await withApi(
        (r) async {
          paths.add(r.uri.path);
          expect(r.method, 'GET');
          if (r.uri.path.endsWith(identifier)) {
            await respondJson(r, payment());
          } else {
            expect(r.uri.queryParameters, {'page': '2', 'pageSize': '25'});
            await respondJson(r, {
              ...page([payment()]),
              'page': 2,
              'total_pages': 2,
              'has_previous_page': true,
            });
          }
        },
        (api, t) async {
          final all = await api.list(page: 2);
          expect(all.items.single.amount, 25.25);
          expect(all.hasPreviousPage, true);
          await api.list(page: 2, status: 'requires action');
          expect((await api.get(identifier)).paidAt, isNull);
        },
      );
      expect(paths, [
        '$base/payments',
        '$base/payments/status/requires%20action',
        '$base/payments/$identifier',
      ]);
    },
  );
  test(
    'saved methods separate Anythink UUID and Stripe identifier plus explicit delete',
    () async {
      final paths = <String>[];
      await withApi(
        (r) async {
          paths.add(r.uri.path);
          if (r.method == 'DELETE') {
            await respondJson(r, null, status: 204);
            return;
          }
          if (r.uri.path.endsWith('query-by-stripe-id')) {
            expect(r.uri.queryParameters, {
              'stripePaymentMethodId': 'pm_synthetic',
            });
          }
          await respondJson(
            r,
            r.uri.path.endsWith('/payment-methods') ? [method()] : method(),
          );
        },
        (api, t) async {
          expect((await api.listMethods()).single.expiryMonth, 12);
          expect(
            (await api.getMethod(identifier)).stripePaymentMethodId,
            'pm_synthetic',
          );
          expect(
            (await api.getMethodByStripeId('pm_synthetic')).id,
            identifier,
          );
          await api.removeMethod(identifier);
        },
      );
      expect(paths, [
        '$base/payment-methods',
        '$base/payment-methods/$identifier',
        '$base/payment-methods/query-by-stripe-id',
        '$base/payment-methods/$identifier',
      ]);
    },
  );
  test(
    'setup intent request snapshots metadata and result redacts client secrets',
    () async {
      final nested = <Object?>['before'];
      final request = PaymentMethodSetupRequest(
        customerEmail: 'synthetic@example.test',
        usage: 'off_session',
        metadata: {'nested': nested},
      );
      nested.add('after');
      await withApi(
        (r) async {
          expect(r.method, 'POST');
          expect(r.uri.path, '$base/payment-methods/setup-intent');
          expect(await readJson(r), {
            'customer_email': 'synthetic@example.test',
            'usage': 'off_session',
            'metadata': {
              'nested': ['before'],
            },
          });
          await respondJson(r, {
            'setup_intent_id': 'seti_synthetic',
            'client_secret': 'sensitive-setup-secret',
            'customer_id': 'cus_synthetic',
            'stripe_object': {'future': true},
          });
        },
        (api, t) async {
          final result = await api.createMethodSetup(request);
          expect(result.clientSecret, 'sensitive-setup-secret');
          expect(result.toString(), isNot(contains('secret')));
          expect(result.toString(), isNot(contains('cus_synthetic')));
          expect(
            () => (result.data['stripe_object'] as Map)['future'] = false,
            throwsUnsupportedError,
          );
        },
      );
    },
  );
  test(
    'saved-method charge forwards idempotency and documented boolean capture wire type',
    () async {
      final request = SavedMethodChargeRequest(
        paymentMethodId: identifier,
        amount: 25.25,
        currency: 'gbp',
        idempotencyKey: 'synthetic-idempotency',
        confirmImmediately: false,
        captureMethod: false,
      );
      await withApi(
        (r) async {
          expect(r.method, 'POST');
          expect(r.uri.path, '$base/payments/charge-payment-method');
          expect(await readJson(r), {
            'payment_method_id': identifier,
            'amount': 25.25,
            'currency': 'gbp',
            'confirm_immediately': false,
            'capture_method': false,
            'idempotency_key': 'synthetic-idempotency',
          });
          await respondJson(r, intent());
        },
        (api, t) async {
          final result = await api.chargeMethod(request);
          expect(result.status, 'requires_action');
          expect(result.nextAction, 'provider-action');
          expect(result.clientSecret, 'synthetic-sensitive-client-secret');
          expect(result.toString(), isNot(contains('synthetic')));
        },
      );
    },
  );
  test(
    'intent read confirm and capture use exact methods empty bodies and capture query',
    () async {
      final calls = <String>[];
      await withApi(
        (r) async {
          calls.add('${r.method} ${r.uri.path}');
          expect(await r.isEmpty, true);
          if (r.uri.path.endsWith('/capture')) {
            expect(r.uri.queryParameters, {'amountToCapture': '12.5'});
          }
          await respondJson(r, intent());
        },
        (api, t) async {
          await api.getIntent('pi_synthetic');
          await api.confirmIntent('pi_synthetic');
          await api.captureIntent('pi_synthetic', amountToCapture: 12.5);
        },
      );
      expect(calls, [
        'GET $base/payments/payment-intent/pi_synthetic',
        'POST $base/payments/payment-intent/pi_synthetic/confirm',
        'POST $base/payments/payment-intent/pi_synthetic/capture',
      ]);
    },
  );
  test(
    'every payment mutation refuses401 replay even if refresh recovery exists',
    () async {
      var count = 0, refreshes = 0;
      await withApi(
        (r) async {
          count++;
          await respondJson(r, {'title': 'Unauthorized'}, status: 401);
        },
        (api, t) async {
          t.recoverAccessToken = (_) async {
            refreshes++;
            return 'renewed';
          };
          final operations = <Future<Object?> Function()>[
            () => api.createCheckout(
              PaymentCheckoutRequest(
                type: 'web',
                amount: 1,
                currency: 'gbp',
                description: 'test',
                customerEmail: 'synthetic@example.test',
              ),
            ),
            () => api.createMethodSetup(
              PaymentMethodSetupRequest(
                customerEmail: 'synthetic@example.test',
              ),
            ),
            () => api.removeMethod(identifier),
            () => api.chargeMethod(
              SavedMethodChargeRequest(
                paymentMethodId: identifier,
                amount: 1,
                currency: 'gbp',
              ),
            ),
            () => api.confirmIntent('pi_synthetic'),
            () => api.captureIntent('pi_synthetic'),
          ];
          for (final operation in operations) {
            final before = count;
            await expectLater(operation(), throwsA(isA<ApiException>()));
            expect(count, before + 1);
          }
          expect(refreshes, 0);
        },
      );
    },
  );
  test(
    'payment read can recover once on401 and rejected404 stays an API failure',
    () async {
      var count = 0, refreshes = 0;
      await withApi(
        (r) async {
          count++;
          await respondJson(
            r,
            count == 1 ? {'title': 'Unauthorized'} : payment(),
            status: count == 1 ? 401 : 200,
          );
        },
        (api, t) async {
          t.recoverAccessToken = (_) async {
            refreshes++;
            return 'renewed';
          };
          expect((await api.get(identifier)).id, identifier);
          expect(count, 2);
          expect(refreshes, 1);
        },
      );
      await withApi(
        (r) async => respondJson(r, {'title': 'Missing'}, status: 404),
        (api, t) async {
          await expectLater(
            api.getMethod(identifier),
            throwsA(
              isA<ApiException>().having((e) => e.statusCode, 'status', 404),
            ),
          );
        },
      );
    },
  );
  test(
    'mutation timeout remains uncertain and no retry causes duplicate charge',
    () async {
      var count = 0;
      final release = Completer<void>();
      final server = await LocalServer.start((r) async {
        count++;
        await release.future;
        await respondJson(r, intent());
      });
      final transport = server.transport(
        timeout: const Duration(milliseconds: 50),
      );
      try {
        await expectLater(
          PaymentsApi(transport).chargeMethod(
            SavedMethodChargeRequest(
              paymentMethodId: identifier,
              amount: 1,
              currency: 'gbp',
            ),
          ),
          throwsA(
            isA<TransportException>().having(
              (e) => e.outcomeUncertain,
              'uncertain',
              true,
            ),
          ),
        );
        expect(count, 1);
      } finally {
        release.complete();
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      }
    },
  );
  test(
    'malformed setup/intent results fail rather than manufacturing payment success',
    () {
      expect(
        () => PaymentMethodSetup.fromJson({'setup_intent_id': 'seti'}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => PaymentIntent.fromJson({...intent(), 'status': null}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => PaymentIntent.fromJson({...intent(), 'amount': double.nan}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => SavedPaymentMethod.fromJson({...method(), 'exp_month': '12'}),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
  test('invalid inputs and cancelled mutations perform no request', () async {
    var count = 0;
    await withApi(
      (r) async {
        count++;
        await respondJson(r, {});
      },
      (api, t) async {
        expect(
          () => PaymentLineItem(name: 'x', unitAmount: 1, quantity: 0),
          throwsArgumentError,
        );
        expect(
          () => PaymentCheckoutRequest(
            type: 'web',
            amount: -1,
            currency: 'gbp',
            description: 'x',
            customerEmail: 'synthetic@example.test',
          ),
          throwsArgumentError,
        );
        await expectLater(api.list(page: 0), throwsArgumentError);
        await expectLater(api.getMethod('../unsafe'), throwsArgumentError);
        await expectLater(api.getMethodByStripeId(' '), throwsArgumentError);
        expect(
          () => api.captureIntent('pi', amountToCapture: double.infinity),
          throwsArgumentError,
        );
        final token = CancellationToken()..cancel();
        await expectLater(
          api.removeMethod(identifier, cancellation: token),
          throwsA(
            isA<TransportException>().having(
              (e) => e.failure,
              'failure',
              TransportFailure.cancelled,
            ),
          ),
        );
        expect(count, 0);
      },
    );
  });
}
