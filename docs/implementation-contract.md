# Module contract

Use this contract when adding or changing a service. Public methods call real
APIs. Missing backend contracts belong in [coverage](consumer-api-coverage.md),
not placeholder methods or invented success results.

## Ownership

`AnythinkClient` composes auth, transport, records, files, search, workflows,
subscriptions, payments and push. Feature modules own their wire models and
endpoint semantics. Shared transport owns request lifetime, authentication and
account-generation checks. Services explicitly select repeat-safe operations.

The four Flutter adapters own storage/lifecycle, identity, Firebase and StoreKit
integration. They do not own the client's lifetime or replace backend decisions.
The native host and future demo consume the SDK; they do not define its API.

## Persistence and lifecycle

The core works in memory when `SessionStore` is omitted. A store implements:

```dart
Future<String?> read();
Future<void> write(String value);
Future<void> clear();
```

Storage holds one opaque envelope. Core auth owns serialization, refresh ordering
and identity changes. Flutter lifecycle calls `refreshIfNeeded()` and reports
failures; application startup calls `restoreSession()` explicitly. Applications
dispose adapters, then close their client. See [session lifetime](architecture.md#session-lifetime).

## Service rules

- Snapshot mutable input before asynchronous auth or transport work. Preserve
  unknown response fields where supported; never interpret them as success.
- Use shared transport for cancellation, response limits and account checks.
  Public calls omit credentials and auth recovery.
- Opt into 401 replay only when the endpoint is repeat-safe, such as Apple
  verification. Other mutations and lazy referral-code reads do not replay.
- Decode the actual success shape, including empty responses. Workflow `204`
  means queued, not completed; do not invent job polling.
- Keep sensitive values out of diagnostic strings. Raw JSON, checkout URLs and
  client secrets still need application-level handling.
- Verify requests and responses with real loopback HTTP. Keep provider/device
  claims tied to their separate [validation evidence](validation.md).

## Feature references

| Concern | Canonical reference |
| --- | --- |
| Paths, permissions and wire formats | [API matrix](api-contract-matrix.md) |
| Refresh, retries, redirects and streams | [Architecture](architecture.md) |
| Checkout, entitlement and payment safety | [Billing](billing.md) |
| Search projection defects and client restrictions | [Search validation](search-validation.md) |
| Supported surface and unresolved contracts | [Coverage](consumer-api-coverage.md) |

Search expressions remain separate from record filters. Highlighted content is
untrusted HTML, resource paths are hints rather than fetch targets, and server
counts are not authorization evidence. Preserve the public-highlight guard and
withheld public-similarity method until the documented backend defects are fixed.
