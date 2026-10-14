import '../json.dart';
import '../subscriptions/billing_models.dart';
import '../wire_timestamp.dart';

/// An Anythink one-off payment. Unknown provider/status strings are preserved.
/// Only the provider/server can determine whether money has actually settled.
final class Payment {
  Payment.fromJson(JsonObject json)
    : id = stringFromJson(json['id'], 'id'),
      type = stringFromJson(json['type'], 'type'),
      provider = optionalStringFromJson(json['provider'], 'provider'),
      amount = billingNumber(json['amount'], 'amount'),
      currency = stringFromJson(json['currency'], 'currency'),
      status = stringFromJson(json['status'], 'status'),
      description = optionalStringFromJson(json['description'], 'description'),
      reference = optionalStringFromJson(json['reference'], 'reference'),
      checkoutUrl = optionalStringFromJson(
        json['checkout_url'],
        'checkout_url',
      ),
      paidAt = _date(json, 'paid_at'),
      createdAt = timestampFromJson(json['created_at'], 'created_at'),
      updatedAt = _date(json, 'updated_at'),
      data = billingObject(json);
  final String id;
  final String type;
  final String? provider;
  final num amount;
  final String currency;
  final String status;
  final String? description;
  final String? reference;
  final String? checkoutUrl;
  final DateTime? paidAt;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final JsonObject data;
  @override
  String toString() => 'Payment(status: $status)';
}

/// Checkout creation does not prove payment. The host opens a trusted checkout
/// URL explicitly and waits for server reconciliation before unlocking access.
final class PaymentCheckout {
  PaymentCheckout.fromJson(JsonObject json)
    : id = stringFromJson(json['anythink_pay_id'], 'anythink_pay_id'),
      checkoutUrl = optionalStringFromJson(
        json['checkout_url'],
        'checkout_url',
      ),
      sessionId = optionalStringFromJson(json['session_id'], 'session_id'),
      data = billingObject(json);
  final String id;
  final String? checkoutUrl;
  final String? sessionId;
  final JsonObject data;
  @override
  String toString() => 'PaymentCheckout([redacted])';
}

/// A card setup result for use with an explicitly configured provider client.
/// [clientSecret] and [data] are sensitive; never log or persist them casually.
final class PaymentMethodSetup {
  PaymentMethodSetup.fromJson(JsonObject json)
    : setupIntentId = stringFromJson(
        json['setup_intent_id'],
        'setup_intent_id',
      ),
      clientSecret = stringFromJson(json['client_secret'], 'client_secret'),
      customerId = stringFromJson(json['customer_id'], 'customer_id'),
      data = billingObject(json);
  final String setupIntentId;
  final String clientSecret;
  final String customerId;
  final JsonObject data;
  @override
  String toString() => 'PaymentMethodSetup([redacted])';
}

/// A provider intent may require another action. Neither receipt of this
/// response nor presence of a client secret means a charge has succeeded.
final class PaymentIntent {
  PaymentIntent.fromJson(JsonObject json)
    : paymentId = stringFromJson(json['anythink_pay_id'], 'anythink_pay_id'),
      intentId = stringFromJson(json['payment_intent_id'], 'payment_intent_id'),
      status = stringFromJson(json['status'], 'status'),
      amount = billingNumber(json['amount'], 'amount'),
      currency = stringFromJson(json['currency'], 'currency'),
      clientSecret = optionalStringFromJson(
        json['client_secret'],
        'client_secret',
      ),
      nextAction = optionalStringFromJson(json['next_action'], 'next_action'),
      createdAt = _date(json, 'created_at'),
      updatedAt = _date(json, 'updated_at'),
      data = billingObject(json);
  final String paymentId;
  final String intentId;
  final String status;
  final num amount;
  final String currency;
  final String? clientSecret;
  final String? nextAction;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Includes the provider's opaque stripe_object, if returned; may be sensitive.
  final JsonObject data;
  @override
  String toString() => 'PaymentIntent([redacted])';
}

DateTime? _date(JsonObject json, String key) =>
    json[key] == null ? null : timestampFromJson(json[key], key);

/// Saved card metadata only; no card number or CVV is accepted by this SDK.
final class SavedPaymentMethod {
  SavedPaymentMethod.fromJson(JsonObject json)
    : id = stringFromJson(json['id'], 'id'),
      type = stringFromJson(json['type'], 'type'),
      stripePaymentMethodId = optionalStringFromJson(
        json['stripe_payment_method_id'],
        'stripe_payment_method_id',
      ),
      stripeCustomerId = optionalStringFromJson(
        json['stripe_customer_id'],
        'stripe_customer_id',
      ),
      status = optionalStringFromJson(json['status'], 'status'),
      brand = optionalStringFromJson(json['brand'], 'brand'),
      last4 = optionalStringFromJson(json['last4'], 'last4'),
      expiryMonth = json['exp_month'] == null
          ? null
          : intFromJson(json['exp_month'], 'exp_month'),
      expiryYear = json['exp_year'] == null
          ? null
          : intFromJson(json['exp_year'], 'exp_year'),
      customerEmail = optionalStringFromJson(
        json['customer_email'],
        'customer_email',
      ),
      createdAt = _date(json, 'created_at'),
      updatedAt = _date(json, 'updated_at'),
      data = billingObject(json);
  final String id;
  final String type;
  final String? stripePaymentMethodId;
  final String? stripeCustomerId;
  final String? status;
  final String? brand;
  final String? last4;
  final int? expiryMonth;
  final int? expiryYear;
  final String? customerEmail;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final JsonObject data;
  @override
  String toString() => 'SavedPaymentMethod([redacted])';
}
