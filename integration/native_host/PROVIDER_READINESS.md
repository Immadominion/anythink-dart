# Native provider setup

The normal host supports password sessions. It does not initialize Firebase,
native provider sign-in or purchases. Configure these integrations explicitly
in a dedicated test app before running their integration entrypoints.

The host identifiers are `dev.anythink.sdk.anythink_native_host` on Android and
`dev.anythink.sdk.anythinkNativeHost` on iOS. Client configuration and local
signing files are gitignored. No Apple team, provisioning profile, provider key
or backend administrator credential is committed.

## Prerequisites

| Integration | App configuration | Backend configuration |
| --- | --- | --- |
| Google Android | OAuth Android client matching package and signing SHA; server/web client ID | Enable Google and allow the intended audience; configure user registration/linking policy |
| Google iOS | OAuth iOS client, matching bundle ID, reversed-client-ID URL scheme and server audience | Allow the intended native audience |
| Apple sign-in | Explicit App ID, capability, entitlement and matching signed provisioning profile | Enable Apple and allow the bundle ID audience |
| Firebase Android | Firebase Android app, client configuration, notification permission and channels | Device-create permission and intended Firebase project |
| Firebase iOS | Firebase iOS app, APNs credentials in Firebase, push capability, required background modes and signed device | Matching server-side push configuration |
| Notification actions | Application-owned action UI and background handler | Category permission, configured workflow and genuine signed action credential |
| StoreKit 2 | App Store product IDs, signed app, sandbox account and required App Store agreements/configuration | Matching bundle ID and product-to-plan mapping; server credentials where restore requires them |

Server service-account, APNs and App Store private keys belong in the intended
server consoles, never in the SDK or app bundle. Client IDs do not replace
backend token verification.

## Remaining checks

See [validation](../../docs/validation.md) for completed checks. Still required:

- Successful Google and Apple exchange, cancellation, repeated sign-in,
  identity mismatch and account changes while native UI is pending.
- Physical iOS push delivery, token refresh, denial, dead tokens, action buttons
  and account-switch ownership behavior.
- StoreKit sandbox purchase, pending/cancel states, signed transaction
  verification, entitlement before completion, restore and interrupted delivery.
- Secure-storage lock/unlock, backup, upgrade and key-invalidation behavior.

## Contract boundaries

Anythink's native identity contract does not establish coordinated nonce
verification. Consumer push unregister/rebind is also undocumented, so logout
cannot guarantee removal of a token from the backend registry. A native purchase
result alone does not grant an entitlement. See
[upstream contracts](../../docs/upstream-contract-questions.md).

References: [Anythink sign-in](https://docs.anythink.cloud/guides/authentication/social-sign-in),
[Anythink push](https://docs.anythink.cloud/guides/workflows/push-notifications),
[Apple sandbox testing](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox).
