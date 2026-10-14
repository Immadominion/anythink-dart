import '../cancellation.dart';
import '../http/api_transport.dart';
import '../json.dart';
import 'billing_models.dart';
import 'checkout_request.dart';
import 'models.dart';
import 'offer_models.dart';

/// User-facing billing APIs. Catalog reads and checkout creation do not grant
/// entitlement; access remains a backend decision. No provider secret or
/// administrator plan/recovery operation belongs in this service.
final class SubscriptionsApi {
  const SubscriptionsApi(this._transport);
  final ApiTransport _transport;
  static const _base = ['integrations', 'anythinkpay', 'subscriptions'];

  /// Starts a provider checkout. Not automatically replayed: on an uncertain
  /// result, reconcile the caller's subscriptions before starting another one.
  Future<SubscriptionCheckout> createCheckout(
    SubscriptionCheckoutRequest request, {
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'POST',
      _base,
      body: request.toJson(),
      cancellation: cancellation,
    );
    return SubscriptionCheckout.fromJson(
      objectFromJson(response.data, 'subscription checkout'),
    );
  }

  /// Catalog access requires anythink_subscription_plans:read.
  Future<List<SubscriptionPlan>> listPlans({
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'GET',
      ['integrations', 'anythinkpay', 'subscription-plans'],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return List.unmodifiable(
      listFromJson(
        response.data,
        'subscription plans',
      ).map((item) => SubscriptionPlan.fromJson(objectFromJson(item))),
    );
  }

  Future<SubscriptionPlan> getPlan(
    int id, {
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'GET',
      ['integrations', 'anythinkpay', 'subscription-plans', '$id'],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return SubscriptionPlan.fromJson(
      objectFromJson(response.data, 'subscription plan'),
    );
  }

  /// Only the caller's own/linked subscriptions are visible to an ordinary user.
  Future<SubscriptionPage> list({
    int page = 1,
    int pageSize = 25,
    CancellationToken? cancellation,
  }) async {
    if (page < 1 || page > 2147483647 || pageSize < 1 || pageSize > 1000) {
      throw ArgumentError(
        'Positive int32 page and page size 1..1000 are required.',
      );
    }
    final response = await _transport.request(
      'GET',
      _base,
      query: {'page': '$page', 'pageSize': '$pageSize'},
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return SubscriptionPage.fromJson(
      objectFromJson(response.data, 'subscription page'),
    );
  }

  /// The status endpoint returns a server-sized page but accepts no paging
  /// parameters. Live validation confirmed extra page/pageSize are ignored.
  /// This method does not promise traversal beyond that returned page.
  Future<SubscriptionPage> listByStatus(
    String status, {
    CancellationToken? cancellation,
  }) async {
    if (status.trim().isEmpty) {
      throw ArgumentError('Status must not be empty.');
    }
    final response = await _transport.request(
      'GET',
      [..._base, 'status', status],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return SubscriptionPage.fromJson(
      objectFromJson(response.data, 'subscription status page'),
    );
  }

  Future<UserSubscription> get(
    String id, {
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'GET',
      [..._base, id],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return UserSubscription.fromJson(
      objectFromJson(response.data, 'subscription'),
    );
  }

  Future<List<SubscriptionEvent>> events(
    String id, {
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'GET',
      [..._base, id, 'events'],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return List.unmodifiable(
      listFromJson(
        response.data,
        'subscription events',
      ).map((item) => SubscriptionEvent.fromJson(objectFromJson(item))),
    );
  }

  Future<NamedSubscriptionAccess> checkAccess({
    required String subscriptionName,
    String? status,
    CancellationToken? cancellation,
  }) async {
    if (subscriptionName.trim().isEmpty || status?.trim().isEmpty == true) {
      throw ArgumentError(
        'The subscription name and optional status must not be empty.',
      );
    }
    final response = await _transport.request(
      'GET',
      [..._base, 'check-access'],
      query: {'subscription_name': subscriptionName, 'status': ?status},
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return NamedSubscriptionAccess.fromJson(
      objectFromJson(response.data, 'subscription access'),
    );
  }

  /// Turns off Stripe renewal. Requires a writable user link; Apple renewal
  /// remains managed in the App Store. A timeout is ambiguous: reconcile by
  /// reading the subscription instead of automatically repeating a mutation.
  /// Acknowledges the HTTP operation only; re-read to reconcile renewal state.
  Future<void> cancel(String id, {CancellationToken? cancellation}) =>
      _changeRenewal(id, 'cancel', cancellation);

  /// Re-enables Stripe renewal while its current period is still running.
  Future<void> resume(String id, {CancellationToken? cancellation}) =>
      _changeRenewal(id, 'resume', cancellation);

  Future<void> _changeRenewal(
    String id,
    String operation,
    CancellationToken? cancellation,
  ) async {
    await _transport.request(
      'POST',
      [..._base, id, operation],
      body: const <String, Object?>{},
      cancellation: cancellation,
    );
  }

  /// The backend lazily creates the default-program personal code on first
  /// access. This call is not automatically replayed, including after a401.
  Future<PersonalReferralCode> personalReferralCode({
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request('GET', [
      'integrations',
      'anythinkpay',
      'offers',
      'me',
      'code',
    ], cancellation: cancellation);
    return PersonalReferralCode.fromJson(
      objectFromJson(response.data, 'personal referral code'),
    );
  }

  /// Codes for active referral programs. No rewards are redeemed by this call.
  /// Conservatively avoids automatic replay because code creation is lazy.
  Future<List<PersonalReferralCode>> personalReferralCodes({
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request('GET', [
      'integrations',
      'anythinkpay',
      'offers',
      'me',
      'codes',
    ], cancellation: cancellation);
    return List.unmodifiable(
      listFromJson(
        response.data,
        'personal referral codes',
      ).map((v) => PersonalReferralCode.fromJson(objectFromJson(v))),
    );
  }

  Future<ReferralStats> referralStats({CancellationToken? cancellation}) async {
    final response = await _transport.request('GET', [
      'integrations',
      'anythinkpay',
      'offers',
      'me',
      'referrals',
    ], cancellation: cancellation);
    return ReferralStats.fromJson(
      objectFromJson(response.data, 'referral statistics'),
    );
  }

  Future<List<UserBalance>> balances({CancellationToken? cancellation}) async {
    final response = await _transport.request(
      'GET',
      ['integrations', 'anythinkpay', 'balances', 'me'],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return List.unmodifiable(
      listFromJson(
        response.data,
        'balances',
      ).map((item) => UserBalance.fromJson(objectFromJson(item))),
    );
  }

  /// A code can be rejected with HTTP200; inspect the result's success field.
  /// This mutation is never automatically replayed on auth or network failure.
  Future<OfferRedemption> redeemOffer(
    String slug, {
    String? subscriptionId,
    CancellationToken? cancellation,
  }) async {
    if (slug.trim().isEmpty || subscriptionId?.trim().isEmpty == true) {
      throw ArgumentError(
        'The code and optional subscription ID must not be empty.',
      );
    }
    final response = await _transport.request(
      'POST',
      ['integrations', 'anythinkpay', 'offers', 'me', 'redeem', slug],
      query: {'subscription_id': ?subscriptionId},
      cancellation: cancellation,
    );
    return OfferRedemption.fromJson(
      objectFromJson(response.data, 'offer redemption'),
    );
  }

  /// Reads the backend's provider ordering for the caller's platform/storefront.
  /// Does not create a payment, open checkout, or infer entitlement access.
  /// Supply the real App Store storefront on iOS; routing policy stays on the
  /// server and is not hardcoded into this client.
  Future<PaymentOptions> paymentOptions({
    required String platform,
    String? storefront,
    CancellationToken? cancellation,
  }) async {
    if (platform.trim().isEmpty || platform.trim() != platform) {
      throw ArgumentError('A nonempty platform is required.');
    }
    if (storefront != null &&
        (storefront.trim().isEmpty || storefront.trim() != storefront)) {
      throw ArgumentError('A supplied storefront must not be empty.');
    }
    final response = await _transport.request(
      'GET',
      ['integrations', 'anythinkpay', 'payment-options'],
      query: {'platform': platform, 'storefront': ?storefront},
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return PaymentOptions.fromJson(
      objectFromJson(response.data, 'payment options'),
    );
  }

  Future<Entitlement> entitlement({CancellationToken? cancellation}) async {
    final response = await _transport.request(
      'GET',
      [..._base, 'me', 'entitlement'],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return Entitlement.fromJson(objectFromJson(response.data, 'entitlement'));
  }

  /// Supply exactly one proof. [signedTransaction] is StoreKit 2 signed JWS,
  /// not a base64 StoreKit 1 receipt. A transaction-ID restore additionally
  /// requires App Store Connect credentials configured on the backend.
  ///
  /// The server documents repeat verification as safe for the same transaction.
  /// A single authentication replay is enabled; no network-error replay occurs.
  Future<AppleVerification> verifyApple({
    String? signedTransaction,
    String? originalTransactionId,
    CancellationToken? cancellation,
  }) async {
    if ((signedTransaction == null) == (originalTransactionId == null)) {
      throw ArgumentError('Supply exactly one Apple transaction proof.');
    }
    if (signedTransaction?.trim().isEmpty == true ||
        originalTransactionId?.trim().isEmpty == true) {
      throw ArgumentError('The Apple transaction proof must not be empty.');
    }
    final response = await _transport.request(
      'POST',
      [..._base, 'apple', 'verify'],
      body: {
        'signed_transaction': ?signedTransaction,
        'original_transaction_id': ?originalTransactionId,
      },
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return AppleVerification.fromJson(
      objectFromJson(response.data, 'Apple verification'),
    );
  }
}
