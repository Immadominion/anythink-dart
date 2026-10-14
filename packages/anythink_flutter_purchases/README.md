# anythink_flutter_purchases

Connect Apple purchases to Anythink access checks. The package listens to
StoreKit 2 transactions, asks Anythink to verify them, and lets your app finish
the transaction after delivering the right feature.

**Unofficial, unpublished development package.** Targets subscriptions and
non-consumables on iOS 15+ and macOS 12+, using Flutter 3.41 / Dart 3.11 or newer.
Live Apple sandbox verification and macOS validation remain outstanding.
Google Play, consumables and StoreKit 1 are outside this package.

## Before you start

Configure the signed app's bundle ID and In-App Purchase capability, Apple
products and sandbox account. Apple requires its Paid Apps Agreement and the
associated account setup for server sandbox testing. In Anythink, save the same
bundle ID and map product IDs to plans. Original-transaction-ID restore also
needs App Store Connect credentials on the backend.

Sign in with your shared `AnythinkClient`. The adapter uses the user's Anythink
account GUID as Apple's `appAccountToken` to bind the purchase to that account.
See [Apple's sandbox setup](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox)
and [Anythink's verification guide](https://docs.anythink.cloud/guides/payments/apple-in-app-purchases).

## Purchase flow

Create `AnythinkApplePurchases(client: client)` and subscribe to `updates`
immediately. Query `products(...)`, check errors/missing IDs, then call
`purchase(product)` from the user's purchase action. Its boolean says whether
the store flow started. Purchased and restored events still need verification:

```dart
import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_flutter_purchases/anythink_flutter_purchases.dart';

Future<void> handlePurchase({
  required AnythinkApplePurchases purchases,
  required ApplePurchaseUpdate update,
  required Future<void> Function(AppleVerification) deliver,
}) async {
  if (!update.canVerify) return;
  final verified = await purchases.verify(update);
  if (!verified.hasKnownPlanAccess) return;
  await deliver(verified.verification); // Check the intended plan and feature.
  await purchases.complete(verified);
}
```

Handle pending, cancelled and failed updates in your UI. Catch errors from the
handler, and make delivery safe to repeat because store events can recur.
Never unlock a feature from native purchase status alone. Unknown plans remain
unfinished so their mapping can be corrected and verification retried.

`restore()` produces events for the same pipeline. Older restored transactions
without an account token need the explicit `allowLegacyUnboundRestore` opt-in.
For current access, query `client.subscriptions.entitlement()` instead of caching
a verification result indefinitely. Account changes invalidate pending results.

Cancel the update subscription and call `purchases.close()` when finished;
this leaves the shared client and outstanding store transactions alone.

Run `flutter test` in this package. The [StoreKit contract](doc/storekit-contract.md)
records plugin behavior and remaining integration tests. The checkout's
`integration/native_host/PROVIDER_READINESS.md` records actual setup blockers.
