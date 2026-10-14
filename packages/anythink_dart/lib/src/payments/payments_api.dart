import '../cancellation.dart';
import '../http/api_transport.dart';
import '../json.dart';
import '../records/page.dart';
import 'models.dart';
import 'requests.dart';

/// Consumer REST billing. Provider onboarding, secrets, refunds and admin
/// recovery are not exposed. Mutations never retry automatically. If the result
/// is uncertain, reconcile by reading the known payment/intent before retrying.
final class PaymentsApi {
  const PaymentsApi(this._transport);
  final ApiTransport _transport;
  static const _base = ['integrations', 'anythinkpay'];

  Future<PaymentCheckout> createCheckout(
    PaymentCheckoutRequest request, {
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'POST',
      [..._base, 'payments'],
      body: request.toJson(),
      cancellation: cancellation,
    );
    return PaymentCheckout.fromJson(
      objectFromJson(response.data, 'payment checkout'),
    );
  }

  /// Requires anythink_payments:read. Backend permissions determine visibility.
  Future<Page<Payment>> list({
    int page = 1,
    int pageSize = 25,
    String? status,
    CancellationToken? cancellation,
  }) async {
    if (page < 1 ||
        page > 2147483647 ||
        pageSize < 1 ||
        pageSize > 1000 ||
        status?.trim().isEmpty == true) {
      throw ArgumentError('Invalid payment pagination or status.');
    }
    final response = await _transport.request(
      'GET',
      [
        ..._base,
        'payments',
        if (status != null) ...['status', status],
      ],
      query: {'page': '$page', 'pageSize': '$pageSize'},
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return Page.fromJson(response.data, Payment.fromJson);
  }

  Future<Payment> get(String id, {CancellationToken? cancellation}) async {
    final response = await _transport.request(
      'GET',
      [..._base, 'payments', id],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return Payment.fromJson(objectFromJson(response.data, 'payment'));
  }

  Future<List<SavedPaymentMethod>> listMethods({
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'GET',
      [..._base, 'payment-methods'],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return List.unmodifiable(
      listFromJson(
        response.data,
        'payment methods',
      ).map((item) => SavedPaymentMethod.fromJson(objectFromJson(item))),
    );
  }

  /// [id] is Anythink's payment-method UUID, not Stripe's pm_ identifier.
  Future<SavedPaymentMethod> getMethod(
    String id, {
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'GET',
      [..._base, 'payment-methods', id],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return SavedPaymentMethod.fromJson(
      objectFromJson(response.data, 'payment method'),
    );
  }

  Future<SavedPaymentMethod> getMethodByStripeId(
    String stripePaymentMethodId, {
    CancellationToken? cancellation,
  }) async {
    if (stripePaymentMethodId.trim().isEmpty) {
      throw ArgumentError('A Stripe payment method ID is required.');
    }
    final response = await _transport.request(
      'GET',
      [..._base, 'payment-methods', 'query-by-stripe-id'],
      query: {'stripePaymentMethodId': stripePaymentMethodId},
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return SavedPaymentMethod.fromJson(
      objectFromJson(response.data, 'payment method'),
    );
  }

  Future<PaymentMethodSetup> createMethodSetup(
    PaymentMethodSetupRequest request, {
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'POST',
      [..._base, 'payment-methods', 'setup-intent'],
      body: request.toJson(),
      cancellation: cancellation,
    );
    return PaymentMethodSetup.fromJson(
      objectFromJson(response.data, 'payment method setup'),
    );
  }

  Future<void> removeMethod(
    String id, {
    CancellationToken? cancellation,
  }) async {
    await _transport.request('DELETE', [
      ..._base,
      'payment-methods',
      id,
    ], cancellation: cancellation);
  }

  /// Charges a saved method; requires anythink_payments:create.
  Future<PaymentIntent> chargeMethod(
    SavedMethodChargeRequest request, {
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'POST',
      [..._base, 'payments', 'charge-payment-method'],
      body: request.toJson(),
      cancellation: cancellation,
    );
    return PaymentIntent.fromJson(
      objectFromJson(response.data, 'payment intent'),
    );
  }

  Future<PaymentIntent> getIntent(
    String paymentIntentId, {
    CancellationToken? cancellation,
  }) => _intent('GET', paymentIntentId, null, null, cancellation);

  /// Requires anythink_payments:update; may cause an actual provider charge.
  Future<PaymentIntent> confirmIntent(
    String paymentIntentId, {
    CancellationToken? cancellation,
  }) => _intent('POST', paymentIntentId, 'confirm', null, cancellation);

  /// Captures an authorized payment. Omit [amountToCapture] for the backend's
  /// default full amount. No automatic replay occurs on timeout or a 401.
  Future<PaymentIntent> captureIntent(
    String paymentIntentId, {
    num? amountToCapture,
    CancellationToken? cancellation,
  }) {
    if (amountToCapture != null &&
        (!amountToCapture.isFinite || amountToCapture < 0)) {
      throw ArgumentError('Capture amount must be finite and nonnegative.');
    }
    return _intent(
      'POST',
      paymentIntentId,
      'capture',
      amountToCapture,
      cancellation,
    );
  }

  Future<PaymentIntent> _intent(
    String method,
    String id,
    String? operation,
    num? amount,
    CancellationToken? cancellation,
  ) async {
    final response = await _transport.request(
      method,
      [..._base, 'payments', 'payment-intent', id, ?operation],
      query: {'amountToCapture': ?amount?.toString()},
      retryOnUnauthorized: method == 'GET',
      cancellation: cancellation,
    );
    return PaymentIntent.fromJson(
      objectFromJson(response.data, 'payment intent'),
    );
  }
}
