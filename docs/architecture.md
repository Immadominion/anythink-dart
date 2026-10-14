# Architecture

The Dart core owns authentication, HTTP and feature services. Optional Flutter
packages add secure storage, native sign-in, Firebase Messaging and StoreKit.
Applications own the client, native configuration and UI.

| Component | Responsibility |
| --- | --- |
| `AnythinkClient` | Compose services for one project and session |
| Core auth | Session state, refresh, persistence ordering and account changes |
| HTTP transport | Destination checks, bearer attachment, cancellation, response limits and selected auth recovery |
| Feature services | Endpoint paths, request encoding and response models |
| Flutter adapters | Native storage and provider APIs; Anythink still validates identity, device ownership and access |

Native dependencies live in separate packages so applications can omit them.
See the [module contract](implementation-contract.md) for contributor rules and
the [wire reference](api-contract-matrix.md) for endpoint details.

## Session lifetime

Use one client owner per persisted session. Cross-isolate and cross-process
coordination is not provided. Auth events contain status and identity, not tokens.

Every identity change increments a generation. Requests capture it before auth
waits and check it before sending or returning user data. Sign-out clears the
in-memory identity immediately. Late sign-in or refresh results cannot commit;
returned stale token pairs receive best-effort revocation.

Only one refresh runs per generation. A late 401 checks whether another request
already replaced its access token. Cancelling one waiter leaves shared refresh
work available to other callers.

### Refresh and durable storage

Anythink rotates single-use refresh tokens without a documented recovery grace
period. Persistent clients use this sequence:

1. Store the old pair with `rotation_pending: true`.
2. Send the refresh request once.
3. Store the new pair and clear the marker together.

An interrupted or uncertain refresh requires reauthentication. Restore never
replays a possibly consumed token. If the new pair arrives but storage fails, it
stays in memory and the error reaches the caller. The next authenticated operation
retries persistence first; the disk marker still protects a process restart.

Store operations are awaited and must report failures. This ordering does not
guarantee transactional crash durability on every storage platform. Sign-out
reports a failed store clear; it does not claim durable logout. `close()` cancels
HTTP and invalidates pending results without revoking the persisted session.

## Requests and data

- Origins require HTTPS; explicit loopback HTTP is available for tests. Origins
  cannot contain credentials, and paths cannot traverse outside the project.
- Authenticated API redirects are rejected. Public-file downloads may follow up
  to five validated, credential-free redirects without an HTTPS downgrade.
  Signed downloads reject redirects by default.
- JSON/text responses are size bounded. Files stream without full buffering.
  Timeouts cover request and body activity; callers must consume or cancel
  downloads. Progress measures local bytes, not server acknowledgement.
- Writes have no general retry. A lost response leaves the outcome uncertain.
  Selected reads and Apple verification allow one 401 recovery; 403 never
  triggers refresh.
- Error strings redact response bodies and personal details. Structured error
  fields remain available and may be sensitive.

Record queries are immutable and use application-supplied decoders. Ambiguous
filter literals are rejected, but the server may ignore schema-invalid filters:
filters are not an authorization boundary. Relationships remain schema-specific;
unknown response fields are retained.

## Design references

Official source informed the design; no production implementation was copied.
Anythink's contracts determine wire behavior, not other backends' token rules,
query languages or upload protocols.

| Reference | Inspected revision | Applied pattern |
| --- | --- | --- |
| [Supabase GoTrue 2.23.0](https://github.com/supabase/supabase-flutter/tree/e1afcbaa0cfc3c1fb013f546d4997dc562378166) | `e1afcba` | Core/platform separation, shared refresh and stale-result checks |
| [PocketBase Dart 0.25.2](https://github.com/pocketbase/dart-sdk/tree/56211c5cd266903aa7f25716207dec48b99b8993) | `56211c5` | Small services, decoders and pagination |
| [Appwrite Dart 29.3.1](https://github.com/appwrite/sdk-for-dart/tree/a36edb111a6c6cd11a9877a0e9f4d7b826d3f1df) | `a36edb1` | Consistent typed service boundaries |

For native setup and executed device/provider checks, see
[provider readiness](../integration/native_host/PROVIDER_READINESS.md) and
[validation](validation.md).
