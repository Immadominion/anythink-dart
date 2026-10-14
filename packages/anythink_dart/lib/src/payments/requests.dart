import '../json.dart';
import '../subscriptions/billing_models.dart';

final class PaymentLineItem {
  PaymentLineItem({
    required String name,
    required num unitAmount,
    required int quantity,
    String? description,
    Uri? imageUrl,
    JsonObject? metadata,
  }) : _json = billingObject({
         'name': name,
         'unit_amount': unitAmount,
         'quantity': quantity,
         'description': ?description,
         'image_url': ?imageUrl?.toString(),
         'metadata': ?metadata,
       }) {
    _nonempty(name);
    _amount(unitAmount);
    if (quantity < 1 || quantity > 2147483647) {
      throw ArgumentError('Quantity must be a positive int32.');
    }
  }
  final JsonObject _json;
  JsonObject toJson() => _json;
}

/// Creates a one-off checkout; amount is in the API's major currency units.
/// Monetary arithmetic, taxation, and trusted product pricing belong on the
/// application's backend. This SDK does not transform or calculate totals.
final class PaymentCheckoutRequest {
  PaymentCheckoutRequest({
    required String type,
    required num amount,
    required String currency,
    required String description,
    required String customerEmail,
    String? reference,
    int? payableEntityId,
    int? payableId,
    List<PaymentLineItem>? lineItems,
    Uri? successUrl,
    Uri? cancelUrl,
    JsonObject? metadata,
  }) : _json = billingObject({
         'type': type,
         'amount': amount,
         'currency': currency,
         'description': description,
         'customer_email': customerEmail,
         'reference': ?reference,
         'payable_entity_id': ?payableEntityId,
         'payable_id': ?payableId,
         'line_items': ?lineItems
             ?.map((i) => i.toJson())
             .toList(growable: false),
         'success_url': ?successUrl?.toString(),
         'cancel_url': ?cancelUrl?.toString(),
         'metadata': ?metadata,
       }) {
    for (final value in [type, currency, customerEmail]) {
      _nonempty(value);
    }
    _amount(amount);
    _returnUrl(successUrl);
    _returnUrl(cancelUrl);
  }
  final JsonObject _json;
  JsonObject toJson() => _json;
  @override
  String toString() => 'PaymentCheckoutRequest([redacted])';
}

/// Saves a payment method without charging it. The provider confirmation UI
/// is the host's responsibility; this package never collects card details.
final class PaymentMethodSetupRequest {
  PaymentMethodSetupRequest({
    required String customerEmail,
    String? customerName,
    String? customerPhone,
    String? usage,
    String? description,
    JsonObject? metadata,
  }) : _json = billingObject({
         'customer_email': customerEmail,
         'customer_name': ?customerName,
         'customer_phone': ?customerPhone,
         'usage': ?usage,
         'description': ?description,
         'metadata': ?metadata,
       }) {
    _nonempty(customerEmail);
    if (usage != null) _nonempty(usage);
  }
  final JsonObject _json;
  JsonObject toJson() => _json;
  @override
  String toString() => 'PaymentMethodSetupRequest([redacted])';
}

/// Explicit saved-method charge input. A caller-supplied idempotency key is
/// forwarded unchanged. The SDK itself never retries the charge automatically.
final class SavedMethodChargeRequest {
  SavedMethodChargeRequest({
    required String paymentMethodId,
    required num amount,
    required String currency,
    String? description,
    String? reference,
    bool? confirmImmediately,
    bool? captureMethod,
    String? statementDescriptor,
    int? payableEntityId,
    int? payableId,
    JsonObject? metadata,
    String? idempotencyKey,
  }) : _json = billingObject({
         'payment_method_id': paymentMethodId,
         'amount': amount,
         'currency': currency,
         'description': ?description,
         'reference': ?reference,
         'confirm_immediately': ?confirmImmediately,
         'capture_method': ?captureMethod,
         'statement_descriptor': ?statementDescriptor,
         'payable_entity_id': ?payableEntityId,
         'payable_id': ?payableId,
         'metadata': ?metadata,
         'idempotency_key': ?idempotencyKey,
       }) {
    _nonempty(paymentMethodId);
    _nonempty(currency);
    _amount(amount);
    if (idempotencyKey != null) _nonempty(idempotencyKey);
  }

  /// The project OpenAPI declares capture_method as boolean. This mirrors its
  /// wire type without inventing the undocumented true/false interpretation.
  /// Omit it unless the backend's configured semantics are known to the host.
  bool? get captureMethod => _json['capture_method'] as bool?;
  final JsonObject _json;
  JsonObject toJson() => _json;
  @override
  String toString() => 'SavedMethodChargeRequest([redacted])';
}

void _nonempty(String value) {
  if (value.trim().isEmpty) {
    throw ArgumentError('A nonempty billing value is required.');
  }
}

void _amount(num value) {
  if (!value.isFinite || value < 0) {
    throw ArgumentError('Amount must be finite and nonnegative.');
  }
}

void _returnUrl(Uri? uri) {
  if (uri != null && (!uri.isAbsolute || uri.userInfo.isNotEmpty)) {
    throw ArgumentError(
      'Return URLs must be absolute and contain no credentials.',
    );
  }
}
