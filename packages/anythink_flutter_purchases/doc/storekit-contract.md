# StoreKit contract

Inspected 14 October 2026: `in_app_purchase` 3.3.1 and
`in_app_purchase_storekit` 0.4.13+2. The workspace lockfile records archive hashes.

| Adapter operation | Inspected official implementation |
| --- | --- |
| Observe | `purchaseStream` distinguishes pending, error, cancelled, purchased and restored events. |
| Buy | `buyNonConsumable(purchaseParam: Sk2PurchaseParam(...))` forwards `applicationUserName` as StoreKit's `appAccountToken`. |
| Verify | `SK2PurchaseDetails` exposes the JWS in `verificationData.serverVerificationData` and the account token. Generic receipt data is not accepted as this proof. |
| Complete | `completePurchase(SK2PurchaseDetails)` finishes the native transaction separately from Anythink verification. Purchased events need completion; restored events may already be finished. |
| Restore | StoreKit restore does not rewrite an existing account token. Each restored transaction's actual token is checked. |

Official references:

- [Flutter purchase package 3.3.1](https://pub.dev/packages/in_app_purchase/versions/3.3.1)
- [StoreKit package 0.4.13+2](https://pub.dev/packages/in_app_purchase_storekit/versions/0.4.13+2)
- [SK2PurchaseDetails API](https://pub.dev/documentation/in_app_purchase_storekit/0.4.13+2/in_app_purchase_storekit/SK2PurchaseDetails-class.html)
- [Sk2PurchaseParam API](https://pub.dev/documentation/in_app_purchase_storekit/0.4.13+2/in_app_purchase_storekit/Sk2PurchaseParam-class.html)
- [Official Flutter source repository](https://github.com/flutter/packages/tree/main/packages/in_app_purchase)
- [Anythink Apple in-app purchases contract](https://docs.anythink.cloud/guides/payments/apple-in-app-purchases)

## Sandbox validation

Local tests do not establish a live purchase. Configure the exact bundle ID and
product-to-plan mappings, then test on supported iOS/macOS devices:

- Purchase, cancellation, pending approval and renewed transactions.
- Interrupted verification, app restart, backend outage and logout during verification.
- Restore with matching/mismatched accounts and unknown products.
- Native completion failure and retry.

Anythink must validate Apple's JWS/certificate chain and account binding. The
client does not replace those checks. See the [package usage](../README.md) for
the verify/deliver/complete flow and legacy-restore opt-in.
