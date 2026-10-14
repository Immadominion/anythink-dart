# Consumer SDK coverage

Reviewed 14 October 2026. This SDK serves applications, not the Anythink admin
console. The table records implemented scope and unresolved contracts;
[validation](validation.md) records what actually ran.

## Implemented surface

| Area | Included | Important boundary |
| --- | --- | --- |
| Password/session auth | Signup, confirmation/resend, sign-in, rotating refresh, sign-out, restore, current user, profile/password changes/reset, invitations, permission/role checks | Email delivery is project-configured. |
| Web/native identity | Provider discovery, authorization with attribution, callback/exchange, native proof exchange; optional Google/Apple adapter | Provider IDs, audiences and redirects require app/backend configuration. |
| Records | Typed/raw CRUD, partial PUT, pagination/filter/sort, bulk create/import/delete, lock, public list/get | Schema, roles and RLS are server-owned. DELETE 204 may be a hidden-row no-op. |
| Search | Authenticated/public plain query; authenticated similarity | Public highlights and similarity exposed private fields. Highlights are blocked; public similarity is withheld. Totals/facets can include hidden rows. See [search findings](search-validation.md). |
| Files | Streaming upload/download, progress/cancel, metadata, signed URLs, public download, list/filter, delete/bulk delete/reprobe | Private means unavailable anonymously, not isolated per user: another permitted user can read the file. |
| Folders | List/tree/details, create/rename/move/delete | Move accepts an explicit parent; undocumented move-to-root semantics are not guessed. |
| Subscriptions | Plans, own/linked subscriptions, status filter, events, access, entitlement, checkout, renewal controls, routing, Apple verification | Provider execution is separate from catalog/own-data reads. |
| Apple purchases | StoreKit 2 updates, signed-transaction verification, entitlement reconciliation, completion/recovery | Requires configured products and sandbox purchase validation. |
| Payments | One-off checkout, payment reads, saved methods/setup/removal, explicit charge and intent read/confirm/capture | App owns provider UI and trusted checkout navigation. |
| Offers/balances | Own codes/referral stats, balances and redemption | Code GET can create a code; redemption can return HTTP 200 with `success: false`. |
| Push | Token registration, category sync, signed action callback, public VAPID key; optional Firebase adapter | Provider delivery and action credentials are separate from registration. |
| Workflows | API-route and workflow-ID invocation | 204 acknowledges queueing, not completion. No automatic replay. |

See [billing](billing.md) for application use and the
[API matrix](api-contract-matrix.md) for paths, payloads and permissions.

## Unresolved consumer contracts

| Capability | Missing contract |
| --- | --- |
| Magic links | Mentioned in the role and email-template docs; no request/consume API in the auth guide, TS client, CLI or project OpenAPI. |
| Push unregister/rebind | Admin management is documented, and an existing token owned by another user returns 409. No consumer unregister/reassignment contract was found. Deleting a Firebase token does not prove backend ownership removal. |
| Consumer AI | Docs describe dashboard AI and external MCP/CLI operations, not a mobile chat/inference API. Provider keys and worker credentials are operational secrets. |

These need vendor clarification, not placeholder methods. No documented realtime
stream, offline conflict protocol, conditional-write contract or generic mutation
idempotency guarantee was found. The specific charge idempotency key is passed
through without enabling automatic retries.

## Outside application scope

Schema/role management, provider credentials, Stripe Connect, plan/offer
administration, subscription recovery/relinking, balance adjustments, workflow
editing/history, push sending/templates, search rebuilds and console dashboards
belong to setup or operations. The SDK never falls back to privileged access.

## Source provenance

The official TypeScript SDK covers authentication. The broader consumer surface
was checked against the platform documentation, CLI types and project OpenAPI.

| Source | Reviewed version |
| --- | --- |
| [TS public exports](https://github.com/Anythink-Ltd/anythink-sdk-typescript/blob/f7fe5349ca169844573ee0532dfd3e0293e452a6/src/index.ts) | Commit `f7fe5349ca169844573ee0532dfd3e0293e452a6`; npm `@anythink-cloud/sdk` 0.4.4 |
| [Official docs corpus](https://docs.anythink.cloud/llms-full.txt) | Fetched 2026-10-14 11:30:24 UTC; SHA-256 `47586b26698ce29f26a3256a2270335e2eda5b1be775eb8558fd05ccfed2dc6e` |
| [CLI client](https://github.com/Anythink-Ltd/anythink-cli/blob/fe0bae2cda9f536ea08e4a3caa2cb74d8312b9fa/src/Client/AnythinkClient.cs) and [DTOs](https://github.com/Anythink-Ltd/anythink-cli/blob/fe0bae2cda9f536ea08e4a3caa2cb74d8312b9fa/src/Models/ApiModels.cs) | Commit `fe0bae2cda9f536ea08e4a3caa2cb74d8312b9fa` |
| Project-generated OpenAPI | Ordinary-user `GET /org/{project_id}/docs` with `anythink_documentation:read` |

OpenAPI omits working plan/offer/balance routes and some required/nullability
metadata. Official guides, CLI types and live responses resolve those gaps;
missing schemas alone do not justify invented behavior.

## Evidence limits

[Validation](validation.md) separates local contracts, live backend calls and
native/provider tests. Empty live lists establish routes and envelopes, not
nonempty provider models or transactions.

Referral observations used an authorized
disposable account. Its code remains because no consumer deletion route is
documented. Live billing checks performed no redemption, paid checkout, card
setup, charge or trial enrollment. For unresolved backend questions, see
[upstream contracts](upstream-contract-questions.md).
