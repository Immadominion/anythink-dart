import '../json.dart';
import 'billing_models.dart';

/// The caller's personal referral code. The single-code endpoint creates it
/// lazily; this DTO does not imply that any reward has been redeemed.
final class PersonalReferralCode {
  PersonalReferralCode.fromJson(JsonObject json)
    : slug = stringFromJson(json['slug'], 'slug'),
      offerId = stringFromJson(json['offer_id'], 'offer_id'),
      redemptionCount = intFromJson(
        json['redemption_count'],
        'redemption_count',
      ),
      offerName = optionalStringFromJson(json['offer_name'], 'offer_name'),
      data = billingObject(json);
  final String slug;
  final String offerId;
  final int redemptionCount;
  final String? offerName;
  final JsonObject data;
  @override
  String toString() => 'PersonalReferralCode([redacted])';
}

/// Subscriber-level referral totals. Nonempty recent entries and tier-progress
/// details have no complete published schema; their immutable JSON is retained
/// without inventing field names or locally computing reward eligibility.
final class ReferralStats {
  ReferralStats.fromJson(JsonObject json)
    : personalCodeSlug = optionalStringFromJson(
        json['personal_code_slug'],
        'personal_code_slug',
      ),
      redemptionCount = intFromJson(
        json['redemption_count'],
        'redemption_count',
      ),
      rewardsApplied = intFromJson(json['rewards_applied'], 'rewards_applied'),
      rewardsPending = intFromJson(json['rewards_pending'], 'rewards_pending'),
      data = billingObject(json) {
    listFromJson(data['recent'], 'recent referrals');
  }
  final String? personalCodeSlug;
  final int redemptionCount;
  final int rewardsApplied;
  final int rewardsPending;
  List<Object?> get recent => data['recent']! as List<Object?>;
  Object? get tierProgress => data['tier_progress'];
  final JsonObject data;
  @override
  String toString() => 'ReferralStats([redacted])';
}
