import '../errors.dart';
import '../json.dart';
import '../records/page.dart';
import '../wire_timestamp.dart';

/// A catalog plan. Prices use the API's decimal major currency units; the SDK
/// forwards them and never computes a charge or rounds a provider's price.
final class SubscriptionPlan {
  SubscriptionPlan.fromJson(JsonObject json)
    : id = intFromJson(json['id'], 'id'),
      planName = stringFromJson(json['plan_name'], 'plan_name'),
      name = stringFromJson(json['name'], 'name'),
      description = stringFromJson(json['description'], 'description'),
      type = stringFromJson(json['type'], 'type'),
      amount = billingNumber(json['amount'], 'amount'),
      currency = stringFromJson(json['currency'], 'currency'),
      billingInterval = stringFromJson(
        json['billing_interval'],
        'billing_interval',
      ),
      intervalCount = intFromJson(json['interval_count'], 'interval_count'),
      trialPeriodDays = _int(json, 'trial_period_days'),
      productName = _string(json, 'product_name'),
      productDescription = _string(json, 'product_description'),
      reference = _string(json, 'reference'),
      isActive = boolFromJson(json['is_active'], 'is_active'),
      appleProductId = _string(json, 'apple_product_id'),
      appleSubscriptionGroupId = _string(json, 'apple_subscription_group_id'),
      tierRank = _int(json, 'tier_rank'),
      data = billingObject(json);

  final int id;
  final String planName;
  final String name;
  final String description;
  final String type;
  final num amount;
  final String currency;
  final String billingInterval;
  final int intervalCount;
  final int? trialPeriodDays;
  final String? productName;
  final String? productDescription;
  final String? reference;
  final bool isActive;
  final String? appleProductId;
  final String? appleSubscriptionGroupId;
  final int? tierRank;
  final JsonObject data;

  @override
  String toString() => 'SubscriptionPlan(id: $id)';
}

/// A subscription visible to the signed-in user. The backend's entitlement
/// decision, not the status string alone, should unlock app features.
final class UserSubscription {
  UserSubscription.fromJson(JsonObject json)
    : id = stringFromJson(json['id'], 'id'),
      type = stringFromJson(json['type'], 'type'),
      name = stringFromJson(json['name'], 'name'),
      description = _string(json, 'description'),
      amount = billingNumber(json['amount'], 'amount'),
      currency = stringFromJson(json['currency'], 'currency'),
      billingInterval = stringFromJson(
        json['billing_interval'],
        'billing_interval',
      ),
      intervalCount = intFromJson(json['interval_count'], 'interval_count'),
      status = stringFromJson(json['status'], 'status'),
      provider = _string(json, 'provider'),
      currentPeriodStartsAt = _date(json, 'current_period_starts_at'),
      currentPeriodEndsAt = _date(json, 'current_period_ends_at'),
      trialPeriodDays = _int(json, 'trial_period_days'),
      trialEndsAt = _date(json, 'trial_ends_at'),
      autoCancelAt = _date(json, 'auto_cancel_at'),
      cancelledAt = _date(json, 'cancelled_at'),
      reference = _string(json, 'reference'),
      checkoutUrl = _string(json, 'checkout_url'),
      lastSyncedAt = _date(json, 'last_synced_at'),
      createdAt = timestampFromJson(json['created_at'], 'created_at'),
      updatedAt = timestampFromJson(json['updated_at'], 'updated_at'),
      customerEmail = _string(json, 'customer_email'),
      customerName = _string(json, 'customer_name'),
      data = billingObject(json);

  final String id;
  final String type;
  final String name;
  final String? description;
  final num amount;
  final String currency;
  final String billingInterval;
  final int intervalCount;
  final String status;
  final String? provider;
  final DateTime? currentPeriodStartsAt;
  final DateTime? currentPeriodEndsAt;
  final int? trialPeriodDays;
  final DateTime? trialEndsAt;
  final DateTime? autoCancelAt;
  final DateTime? cancelledAt;
  final String? reference;

  /// Untrusted server URL; the host decides which checkout origins to open.
  final String? checkoutUrl;
  final DateTime? lastSyncedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? customerEmail;
  final String? customerName;
  final JsonObject data;

  @override
  String toString() => 'UserSubscription(status: $status)';
}

/// Billing list metadata verified from the project OpenAPI and a live page.
/// Item records remain constrained by the caller's backend permissions.
final class SubscriptionPage {
  SubscriptionPage.fromJson(JsonObject json)
    : _page = Page<UserSubscription>.fromJson(json, UserSubscription.fromJson),
      data = billingObject(json);
  final Page<UserSubscription> _page;
  List<UserSubscription> get items => _page.items;
  int get page => _page.page;
  int get pageSize => _page.pageSize;
  int get totalItems => _page.totalItems;
  int get totalPages => _page.totalPages;
  bool get hasNextPage => _page.hasNextPage;
  bool get hasPreviousPage => _page.hasPreviousPage;
  Duration? get retrievalTime => _page.retrievalTime;
  final JsonObject data;
}

final class SubscriptionEvent {
  SubscriptionEvent.fromJson(JsonObject json)
    : id = stringFromJson(json['id'], 'id'),
      eventType = stringFromJson(json['event_type'], 'event_type'),
      source = _string(json, 'source'),
      priorStatus = _string(json, 'prior_status'),
      newStatus = _string(json, 'new_status'),
      summary = _string(json, 'summary'),
      occurredAt = timestampFromJson(json['occurred_at'], 'occurred_at'),
      data = billingObject(json);
  final String id;
  final String eventType;
  final String? source;
  final String? priorStatus;
  final String? newStatus;
  final String? summary;
  final DateTime occurredAt;
  final JsonObject data;
}

final class NamedSubscriptionAccess {
  NamedSubscriptionAccess.fromJson(JsonObject json)
    : hasAccess = boolFromJson(json['has_access'], 'has_access'),
      subscription = json['subscription'] == null
          ? null
          : SubscriptionAccessItem.fromJson(
              objectFromJson(json['subscription']),
            ),
      data = billingObject(json);
  final bool hasAccess;
  final SubscriptionAccessItem? subscription;
  final JsonObject data;
}

final class SubscriptionAccessItem {
  SubscriptionAccessItem.fromJson(JsonObject json)
    : id = stringFromJson(json['id'], 'id'),
      name = stringFromJson(json['name'], 'name'),
      status = stringFromJson(json['status'], 'status'),
      data = billingObject(json);
  final String id;
  final String name;
  final String status;
  final JsonObject data;
}

/// Creates a Stripe checkout using the selected plan's own price/interval.
/// This is a checkout result, never proof of payment or entitlement.
final class SubscriptionCheckout {
  SubscriptionCheckout.fromJson(JsonObject json)
    : id = stringFromJson(json['anythink_pay_id'], 'anythink_pay_id'),
      checkoutUrl = _string(json, 'checkout_url'),
      sessionId = _string(json, 'session_id'),
      data = billingObject(json);
  final String id;

  /// Untrusted server URL; the host controls browser launching and return links.
  final String? checkoutUrl;
  final String? sessionId;
  final JsonObject data;
  @override
  String toString() => 'SubscriptionCheckout([redacted])';
}

/// Points are whole units; credit is in the currency's minor units. Reading a
/// balance does not spend credit or change how a provider charges a customer.
final class UserBalance {
  UserBalance.fromJson(JsonObject json)
    : unitType = stringFromJson(json['unit_type'], 'unit_type'),
      currency = _string(json, 'currency'),
      total = intFromJson(json['total'], 'total'),
      data = billingObject(json);
  final String unitType;
  final String? currency;
  final int total;
  final JsonObject data;
}

/// A rejected redemption is a successful HTTP response with [success] false.
/// Callers must inspect it before presenting any reward or refreshing access.
final class OfferRedemption {
  OfferRedemption.fromJson(JsonObject json)
    : success = boolFromJson(json['success'], 'success'),
      rejectionReason = _string(json, 'rejection_reason'),
      redemptionId = _string(json, 'redemption_id'),
      redeemerRewardSummary = billingObject({
        'value': json['redeemer_reward_summary'],
      })['value'],
      referrerRewardQueued = boolFromJson(
        json['referrer_reward_queued'],
        'referrer_reward_queued',
      ),
      data = billingObject(json);
  final bool success;
  final String? rejectionReason;
  final String? redemptionId;

  /// The guide does not specify the non-null reward summary's schema.
  /// Preserve its finite immutable JSON without inventing a string contract.
  final Object? redeemerRewardSummary;
  final bool referrerRewardQueued;
  final JsonObject data;
  @override
  String toString() => 'OfferRedemption(success: $success)';
}

// Shared by billing services, but intentionally not exported as public API.
JsonObject billingObject(Object? json) =>
    _snapshot(objectFromJson(json), Set<Object>.identity()) as JsonObject;

Object? _snapshot(Object? value, Set<Object> ancestors) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List<Object?> || value is Map<String, Object?>) {
    if (!ancestors.add(value)) {
      throw const ProtocolException('Cyclic billing JSON.');
    }
    try {
      if (value is List<Object?>) {
        return List<Object?>.unmodifiable(
          value.map((item) => _snapshot(item, ancestors)),
        );
      }
      final map = value as JsonObject;
      return Map<String, Object?>.unmodifiable({
        for (final entry in map.entries)
          entry.key: _snapshot(entry.value, ancestors),
      });
    } finally {
      ancestors.remove(value);
    }
  }
  throw const ProtocolException('Billing response contains non-JSON values.');
}

num billingNumber(Object? value, String field) {
  if (value is num && value.isFinite) return value;
  throw ProtocolException('Expected a finite number for $field.');
}

String? _string(JsonObject json, String field) =>
    optionalStringFromJson(json[field], field);
int? _int(JsonObject json, String field) =>
    json[field] == null ? null : intFromJson(json[field], field);
DateTime? _date(JsonObject json, String field) =>
    json[field] == null ? null : timestampFromJson(json[field], field);
