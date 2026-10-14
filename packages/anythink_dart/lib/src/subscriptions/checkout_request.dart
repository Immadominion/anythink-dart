import '../json.dart';
import 'billing_models.dart';

/// Subscription checkout input. Prefer [SubscriptionCheckoutRequest.fromPlan]
/// to copy server-owned price and cadence without maintaining a second catalog.
/// This initiates checkout only; successful return is not proof of payment.
final class SubscriptionCheckoutRequest {
  SubscriptionCheckoutRequest({
    required String name,
    required String description,
    required String type,
    required num amount,
    required String currency,
    required String billingInterval,
    required int intervalCount,
    required String customerEmail,
    int? trialPeriodDays,
    String? productName,
    String? productDescription,
    String? reference,
    String? customerName,
    String? customerPhone,
    int? subscriberEntityId,
    int? subscriberId,
    Uri? successUrl,
    Uri? cancelUrl,
    JsonObject? customerMetadata,
    JsonObject? metadata,
  }) : _body = billingObject({
         'name': name,
         'description': description,
         'type': type,
         'amount': amount,
         'currency': currency,
         'billing_interval': billingInterval,
         'interval_count': intervalCount,
         'customer_email': customerEmail,
         'trial_period_days': ?trialPeriodDays,
         'product_name': ?productName,
         'product_description': ?productDescription,
         'reference': ?reference,
         'customer_name': ?customerName,
         'customer_phone': ?customerPhone,
         'subscriber_entity_id': ?subscriberEntityId,
         'subscriber_id': ?subscriberId,
         'success_url': ?successUrl?.toString(),
         'cancel_url': ?cancelUrl?.toString(),
         'customer_metadata': ?customerMetadata,
         'metadata': ?metadata,
       }) {
    if ([
          name,
          type,
          currency,
          billingInterval,
          customerEmail,
        ].any((v) => v.trim().isEmpty) ||
        !amount.isFinite ||
        amount < 0 ||
        intervalCount < 1 ||
        intervalCount > 2147483647 ||
        (trialPeriodDays != null &&
            (trialPeriodDays < 0 || trialPeriodDays > 2147483647))) {
      throw ArgumentError('Invalid subscription checkout values.');
    }
    for (final uri in [successUrl, cancelUrl]) {
      if (uri != null && (!uri.isAbsolute || uri.userInfo.isNotEmpty)) {
        throw ArgumentError(
          'Checkout return URLs must be absolute and contain no credentials.',
        );
      }
    }
  }

  factory SubscriptionCheckoutRequest.fromPlan(
    SubscriptionPlan plan, {
    required String customerEmail,
    String? customerName,
    String? customerPhone,
    int? subscriberId,
    Uri? successUrl,
    Uri? cancelUrl,
    JsonObject? metadata,
  }) => SubscriptionCheckoutRequest(
    name: plan.name,
    description: plan.description,
    type: plan.type,
    amount: plan.amount,
    currency: plan.currency,
    billingInterval: plan.billingInterval,
    intervalCount: plan.intervalCount,
    trialPeriodDays: plan.trialPeriodDays,
    productName: plan.productName,
    productDescription: plan.productDescription,
    reference: plan.reference,
    customerEmail: customerEmail,
    customerName: customerName,
    customerPhone: customerPhone,
    subscriberId: subscriberId,
    successUrl: successUrl,
    cancelUrl: cancelUrl,
    metadata: metadata,
  );
  final JsonObject _body;
  JsonObject toJson() => _body;
  @override
  String toString() => 'SubscriptionCheckoutRequest([redacted])';
}
