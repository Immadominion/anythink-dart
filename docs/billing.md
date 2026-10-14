# Billing

Use `client.subscriptions` for plans, subscriptions and entitlements;
`client.payments` for one-off payments and saved methods. Native Apple purchases
use [anythink_flutter_purchases](../packages/anythink_flutter_purchases/README.md).
A checkout response, provider route or client secret does not grant paid access.

## Plans, checkout and access

```dart
final plans = await client.subscriptions.listPlans();
final activePlans = plans.where((plan) => plan.isActive).toList();
final access = await client.subscriptions.entitlement();
final routing = await client.subscriptions.paymentOptions(
  platform: 'ios',
  storefront: currentStorefront,
);
```

Use the actual App Store storefront for `currentStorefront`. Provider order comes
from the server; your app must explicitly support a returned provider. An
entitlement read can start the project's configured app trial.

Create checkout from the selected plan, signed-in user and configured return URLs:

```dart
final checkout = await client.subscriptions.createCheckout(
  SubscriptionCheckoutRequest.fromPlan(
    selectedPlan,
    customerEmail: signedInUser.email,
    subscriberId: signedInUser.id,
    successUrl: configuredSuccessUrl,
    cancelUrl: configuredCancelUrl,
  ),
);
```

The SDK copies the plan's price and cadence. Validate the returned checkout URL
against allowed provider origins before opening it. After checkout, refresh
backend entitlement; a return URL or checkout-created response is not proof of
payment.

`list`, `get`, `events` and `checkAccess` return caller-visible subscription data.
`listByStatus(status)` returns the server-sized page: that route ignores paging
parameters, so the method cannot promise complete traversal. Statuses remain
strings, including future values. Do not derive access policy from status alone.

`cancel` and `resume` change Stripe renewal for writable linked users. Apple
renewal is managed in the App Store.

## Saved methods and one-off payments

| Task | Method |
| --- | --- |
| Read saved methods | `listMethods`, `getMethod`, `getMethodByStripeId` |
| Start provider card setup | `createMethodSetup(PaymentMethodSetupRequest(...))` |
| Remove a saved method | `removeMethod` |
| Create one-off checkout | `createCheckout(PaymentCheckoutRequest(...))` |
| Reconcile payment or intent | `list`, `get`, `getIntent` |
| Perform an explicit financial operation | `chargeMethod`, `confirmIntent`, `captureIntent` |

Anythink method UUIDs and Stripe `pm_` identifiers are distinct. Send a setup
`clientSecret` only to your configured provider client. The SDK has no card/CVV
collection or Stripe UI. Removing a method does not cancel its subscription.

Prices and line items are explicit: the SDK does not sum, round or convert them
to minor units. A `requires_action` intent stays in that state with its next
action; your app handles the provider flow.

The project schema defines charge `capture_method` as a **boolean** but does not
explain its values. Omit it until your backend's meaning is established; it is
not Stripe's similarly named string field. Capture uses the exact query key
`amountToCapture`.

## Offers and balances

- `personalReferralCode`, `personalReferralCodes` and `referralStats` expose the
  current subscriber's data. The single-code GET creates a code on first use.
- `redeemOffer` can return HTTP 200 with `success: false`. Check the boolean.
  Unknown reward-summary, recent-entry and tier details remain immutable JSON.
- `balances` returns integer points or credit minor units. It neither spends
  balances nor changes charge amounts.

## Permissions and retries

| Operation | Required access |
| --- | --- |
| Plans, routing, entitlement, Apple verification, own offers/balances | `anythink_subscription_plans:read` |
| Own/linked subscriptions and saved methods | Authenticated user; backend ownership/link rules apply |
| Cancel/resume | Writable subscription link |
| Read payments | `anythink_payments:read` |
| Create/charge payment | `anythink_payments:create` |
| Confirm/capture intent | `anythink_payments:update` |

Use a dedicated application role with only needed permissions. The SDK has no
admin/API-key fallback.

Ordinary catalog/payment reads allow one auth recovery. Personal referral reads
avoid replay because codes can be created lazily. Checkout, setup, charge,
confirm, capture, method removal, renewal and redemption never replay
automatically. A timeout may follow a completed mutation: reconcile the known
subscription, payment or intent before retrying. A charge idempotency key is
forwarded unchanged and does not enable retries.

Diagnostic strings redact checkout, setup, intent and request contents. Raw
`data`, `toJson()`, client secrets, checkout URLs/session IDs and provider/customer
metadata may still be sensitive. Do not log them indiscriminately or interpret
unknown provider JSON as payment success.

## Contract and validation

The [billing matrix](api-contract-matrix.md#consumer-billing-completion-audit)
links exact routes and primary sources. Local HTTP tests cover serialization,
immutable snapshots, errors, cancellation, malformed responses and no mutation
replay. [Live checks](validation.md#live-backend-checks) cover ordinary-user
reads only. Payment execution still requires a configured test
provider, UI, webhooks and test transactions; no paid checkout or charge was
executed in this audit.
