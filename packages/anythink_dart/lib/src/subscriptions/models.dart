import '../errors.dart';
import '../json.dart';
import '../wire_timestamp.dart';

/// Server-provided purchase routing, not an entitlement or payment result.
/// Provider identifiers remain strings so future providers can be represented.
/// Applications must explicitly support a provider before opening its flow.
final class PaymentOptions {
  PaymentOptions.fromJson(JsonObject json)
    : primaryProvider = stringFromJson(
        json['primary_provider'],
        'primary_provider',
      ),
      providers = List<String>.unmodifiable(
        listFromJson(
          json['providers'],
          'payment providers',
        ).map((provider) => stringFromJson(provider, 'payment provider')),
      ),
      webCheckoutAllowed = boolFromJson(
        json['web_checkout_allowed'],
        'web_checkout_allowed',
      ),
      storefront = optionalStringFromJson(json['storefront'], 'storefront'),
      data = _paymentSnapshot(json, Set<Object>.identity()) as JsonObject {
    if (primaryProvider.trim().isEmpty ||
        providers.isEmpty ||
        providers.any((provider) => provider.trim().isEmpty) ||
        !providers.contains(primaryProvider)) {
      throw const ProtocolException('Invalid payment provider routing.');
    }
  }

  final String primaryProvider;

  /// Preserves server ordering; the SDK does not select a fallback itself.
  final List<String> providers;
  final bool webCheckoutAllowed;
  final String? storefront;
  final JsonObject data;

  @override
  String toString() => 'PaymentOptions(providerCount: ${providers.length})';
}

Object? _paymentSnapshot(Object? value, Set<Object> ancestors) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List<Object?>) {
    if (!ancestors.add(value)) {
      throw const ProtocolException('Cyclic payment options JSON.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((item) => _paymentSnapshot(item, ancestors)),
      );
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is Map<String, Object?>) {
    if (!ancestors.add(value)) {
      throw const ProtocolException('Cyclic payment options JSON.');
    }
    try {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key: _paymentSnapshot(entry.value, ancestors),
      });
    } finally {
      ancestors.remove(value);
    }
  }
  throw const ProtocolException('Payment options contain non-JSON values.');
}

/// Server-owned access decision across Apple, Stripe and configured app trials.
/// A first read can start the user's one-time app trial if the project enables it.
final class Entitlement {
  Entitlement.fromJson(JsonObject json)
    : hasAccess = boolFromJson(json['has_access'], 'has_access'),
      subscriptionId = _string(json, 'subscription_id'),
      provider = _string(json, 'provider'),
      productId = _string(json, 'product_id'),
      status = _string(json, 'status'),
      expiresAt = _date(json, 'expires_at'),
      isTrial = json['is_trial'] == null
          ? null
          : boolFromJson(json['is_trial'], 'is_trial'),
      trialEndsAt = _date(json, 'trial_ends_at'),
      trialDaysRemaining = _integer(json, 'trial_days_remaining'),
      trialLengthDays = _integer(json, 'trial_length_days'),
      trialBaseDays = _integer(json, 'trial_base_days'),
      trialBonusDays = _integer(json, 'trial_bonus_days'),
      autoCancelAt = _date(json, 'auto_cancel_at'),
      cancelledAt = _date(json, 'cancelled_at'),
      pendingProductId = _string(json, 'pending_product_id'),
      pendingAt = _date(json, 'pending_at'),
      data = Map.unmodifiable(json);

  final bool hasAccess;
  final String? subscriptionId;
  final String? provider;

  /// This endpoint calls the plan/subscription name product_id, not Apple's ID.
  final String? productId;
  final String? status;
  final DateTime? expiresAt;
  final bool? isTrial;
  final DateTime? trialEndsAt;
  final int? trialDaysRemaining;
  final int? trialLengthDays;
  final int? trialBaseDays;
  final int? trialBonusDays;
  final DateTime? autoCancelAt;
  final DateTime? cancelledAt;
  final String? pendingProductId;
  final DateTime? pendingAt;
  final JsonObject data;

  @override
  String toString() => 'Entitlement(hasAccess: $hasAccess)';
}

/// The verification result retains backend fields instead of interpreting
/// StoreKit status locally. An unrecognized product must not unlock a feature.
final class AppleVerification {
  AppleVerification.fromJson(JsonObject json)
    : subscriptionId = stringFromJson(
        json['subscription_id'],
        'subscription_id',
      ),
      boundUserId = intFromJson(json['bound_user_id'], 'bound_user_id'),
      provider = stringFromJson(json['provider'], 'provider'),
      productId = stringFromJson(json['product_id'], 'product_id'),
      planName = _string(json, 'plan_name'),
      planId = _integer(json, 'plan_id'),
      status = stringFromJson(json['status'], 'status'),
      expiresAt = _date(json, 'expires_at'),
      hasAccess = boolFromJson(json['has_access'], 'has_access'),
      matchedKnownPlan = boolFromJson(
        json['matched_known_plan'],
        'matched_known_plan',
      ),
      data = Map.unmodifiable(json) {
    if (boundUserId < 1 ||
        subscriptionId.trim().isEmpty ||
        provider.trim().isEmpty ||
        productId.trim().isEmpty ||
        status.trim().isEmpty) {
      throw const ProtocolException('Incomplete Apple verification result.');
    }
  }
  final String subscriptionId;
  final int boundUserId;
  final String provider;

  /// Apple's actual product identifier in this response.
  final String productId;
  final String? planName;
  final int? planId;
  final String status;
  final DateTime? expiresAt;
  final bool hasAccess;
  final bool matchedKnownPlan;
  final JsonObject data;

  /// Conservative verification gate; the app must also choose the correct plan
  /// for its feature. A raw has_access alone is insufficient for unknown plans.
  bool get hasKnownPlanAccess => hasAccess && matchedKnownPlan;

  @override
  String toString() =>
      'AppleVerification(hasKnownPlanAccess: $hasKnownPlanAccess)';
}

String? _string(JsonObject json, String field) =>
    json[field] == null ? null : stringFromJson(json[field], field);
int? _integer(JsonObject json, String field) =>
    json[field] == null ? null : intFromJson(json[field], field);
DateTime? _date(JsonObject json, String field) {
  if (json[field] == null) return null;
  return timestampFromJson(json[field], field);
}
