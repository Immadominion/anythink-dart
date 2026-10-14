# Anythink endpoint and wire-format matrix

Reviewed 14 October 2026. Paths are relative to `{apiOrigin}/org/{projectId}`;
use the origin from project configuration. **D** means documented; **U** means
unspecified. Neither marker proves a live test passed. See [validation](validation.md)
for executed checks and [coverage](consumer-api-coverage.md) for SDK scope.

Auth: **public** = no bearer; **user** = bearer token; **admin** = project
administrator; **key** = server-only `x-api-key`. Admin/key rows describe upstream
boundaries, not mobile credentials. JSON bodies use `application/json`; path
segments require encoding and validation.

## Sessions and users

Source: [sign-in guide](https://docs.anythink.cloud/guides/authentication/sign-in).

| Method/path | Auth | Documented request | Documented result / important distinction | Status |
| --- | --- | --- | --- | --- |
| `POST /auth/v1/register` | public | `first_name`, `last_name`, `email`, `password`; optional `referral_code`, `signup_context` | 200 text success; **not tokens**. Registration setting and default role required. 400 setting/validation failures. | D |
| `POST /auth/v1/confirm-email` | public | `email`, `token` | 200 text; 400 invalid/expired confirmation; token lifetime 24h. | D |
| `POST /auth/v1/resend-confirm-email?email=…` | public | Email in query | Always 204 to avoid account enumeration; at most one email/minute/user. | D |
| `POST /auth/v1/token` | public | `email`, `password` | 200 `{access_token,refresh_token,expires_in}`; 401 wrong credentials/unconfirmed/inactive account. | D |
| `POST /auth/v1/refresh` | public | `{token: refreshToken}` | 200 new pair + `expires_in`; consumes old refresh token. 401 on invalid/expired/revoked/wrong-project/reused token. | D |
| `POST /auth/v1/logout` | public | `{token: refreshToken}` | 200; invalidates that refresh token. Exact response body and invalid-token repeat behaviour are not specified. | D/U |
| `GET /users/me` | user | None | 200 user object; numeric `id`, GUID `gid`, names/email, role fields, active/confirmation/login/provider/permissions; guide example incomplete. 401 invalid auth. | D |
| `GET /users/me/permissions` | user | None | Permission list. Full typed permission contract to verify in project spec. | D |
| `GET /users/me/has-permission?permissionName=…` | user | Name query | Boolean. | D |
| `GET /users/me/has-role?roleName=…` | user | Name query | Boolean. | D |
| `GET /users/me/is-admin` | user | None | Boolean. | D |
| `PUT /users/me` | user | `first_name`, `last_name` | 204. | D |
| `POST /auth/v1/send-password-reset?email=…` | public | Email query | Always 204; one email/minute/user. | D |
| `POST /auth/v1/confirm-password-reset` | public | `email`, `token`, `password` | 204; reset code one use, one hour; new request replaces previous code. 400 invalid/expired/validation. | D |
| `PUT /users/me/password` | user | `current_password`, `new_password` | 204. Effects on other sessions are not documented. | D/U |
| `GET /users/invites/{inviteToken}` | public | Token path | Invited names/email/role; 404 invalid/expired token. Invite lasts seven days. | D |
| `POST /users/invites/{inviteToken}` | public | `first_name`, `last_name`, `password` | 204 then separate sign-in; 400 invalid token. | D |
| Magic-link request / consumption | unknown | No documented endpoint or wire shape found | Marketing/role capability only; full docs search did not establish contract. Do not expose guessed SDK methods. | U |

Signup names are required and max 50 characters; email max 255; password at least eight characters with upper/lower/digit/special character. Validation can return a problem-like JSON `errors` map keyed by field, distinct from plain text business failures. Signup context keys are `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content`, `referrer`, `signup_country`.

`expires_in` is seconds (documented 1800); refresh lifetime is 30 days.
For persistence, concurrency and uncertain rotation, see
[session lifetime](architecture.md#session-lifetime).

## Social identity

Source: [social guide](https://docs.anythink.cloud/guides/authentication/social-sign-in).

| Method/path | Auth | Request | Result / limitation | Status |
| --- | --- | --- | --- | --- |
| `GET /auth/v1/providers` | public | None | Array of `{provider,display_name,icon}`; **web-enabled** providers only, not native-only capabilities. | D |
| `GET /auth/v1/{provider}/authorize?redirectUri=…` | public | Exact provider redirect URI, optional attribution query | `{authorization_url}`; allowed origin + provider redirect registration required; state one-use/10min. | D |
| `GET /auth/v1/{provider}/callback?code=…&state=…` | public | Code/state | Session pair. Google/GitHub/LinkedIn web flow; Apple has special flow below. | D |
| Apple web callback | provider form POST | Apple form result | Must be routed through app-origin callback forwarded to Anythink; redirects to `/org/{projectId}/auth/apple/callback?code=…`. Exact raw form schema not fully enumerated. | D/U |
| `POST /auth/v1/exchange` | public | `{code: oneTimeCode}` | Session pair; Apple one-time code expires in 2min. | D |
| `POST /auth/v1/native/apple` | public | `identity_token`, `user_identifier`; optional `given_name`, `family_name`, `signup_context` | Session pair. Native Apple iOS; bundle ID must be allowed. | D |
| `POST /auth/v1/native/google` | public | Same native body | Session pair. Google iOS/Android audiences configured in backend; Android token uses server/web client ID. | D |
| `POST /auth/v1/native/linkedin` | public | Same native body | LinkedIn OIDC ID token, native audience configured. | D |
| Native GitHub | unsupported | N/A | 400 unsupported provider. | D |
| `GET/PUT /integrations/definitions/{provider}/oauth` | user with `anythink_integrations:update` for write | Provider-specific settings | Provisioning/admin surface, outside the runtime SDK; never pass client secrets/private keys through mobile. PUT can replace native+web settings together. | D |

Native errors include unconfigured provider (400) and invalid audience, token,
subject, email or account (401). The backend checks signature, issuer, expiry
(60s skew), audience and subject; documented JWKS caching is 10min. Nonce/replay
guarantees are unspecified. Native matching uses provider subject then email;
web matching uses email. Clients must not merge accounts themselves.

## Records and query formats

Sources: [REST reference](https://docs.anythink.cloud/reference/rest-api), [filter reference](https://docs.anythink.cloud/reference/filter-operators), [field types](https://docs.anythink.cloud/reference/field-types).

Every authenticated record operation also requires role **API Access**, its entity permission, and applicable RLS/field access. API keys are server-only and subject to creator-context RLS.

| Method/path | Permission | Request | Result | Status |
| --- | --- | --- | --- | --- |
| `GET /entities/{entity}/items` | `{entity}:read` | Query below | 200 paginated envelope | D |
| `GET /entities/{entity}/items/{id}` | read | Optional `fields` | 200 record, no envelope; 404 absent or invisible | D |
| `POST /entities/{entity}/items` | create | Entity field map | 201 new record + Location header | D |
| `POST /entities/{entity}/items/bulk` | create | Array of maps | 200 created-record array; transactionality not documented | D/U |
| `POST /entities/{entity}/items/import` | create | Array of maps | 204 | D |
| `PUT /entities/{entity}/items/{id}` | update | Partial field map | 204; omitted fields preserved | D |
| `PATCH /entities/{entity}/items/{id}` | N/A | Unsupported | 405 | D |
| `DELETE /entities/{entity}/items/{id}` | delete | None | 204, including missing record; locked record errors | D |
| `POST` or `DELETE /entities/{entity}/items/delete-many` | delete | Array of IDs | 204; inaccessible/read-only RLS rows can be skipped | D |
| `POST /entities/{entity}/items/{id}/set-lock-status?locked=…` | update | `true`/`false` query | 204 | D |
| `GET /entities/{entity}/public/items` | public | Same list query | Only public entity/fields; nonpublic entity 404 | D |
| `GET /entities/{entity}/public/items/{id}` | public | ID path | Only public fields; 404 inaccessible/missing | D |
| `GET /docs` | `anythink_documentation:read` | None | Two nested OpenAPI documents, not full API inventory | D |

Page query: `page` >= 1 (default 1), `pageSize` 1..1000 (default 25), `sortBy` actual field (default `id`), `sortDirection` `asc`/`desc` (default asc), `fields` comma-separated names/dotted relationships; optional `group_scope` requires matching group role. Response: `items`, `page`, `page_size`, `total_items`, `total_pages`, `has_next_page`, `has_previous_page`, `retrieval_time` (ms).

Filter forms: bare equality, `!` not equal, `GT:`, `GTE:`, `LT:`, `LTE:`, `C:`, `NC:`, `SW:`, `EW:`, `IN:`. Prefix case-insensitive. Conditions across fields use AND; same-field range `GTE:6,LT:30`; membership `IN:paid,shipped`. Equality case-sensitive, contains/starts/ends case-insensitive. Null values do not match negative/comparison operators. Unknown fields and invalid typed values can be ignored; there is no cross-field OR on record lists. Escaping reserved literal prefixes/commas is unspecified.

Serialization hazards: relationship input IDs differ from expanded output; one/many uses objects versus `{__count,__data}`; expansion max four levels; `jsonb` and geo output is stringified JSON; date-only output midnight string has no zone; timestamp output UTC; decimal and bigint wire values need lossless policy. Server-managed fields include `id`, `locked`, `__name`, `created_at`, `updated_at`. A partial `fields` selection can omit user fields; decoded model fields cannot all be unconditionally required.

## Files

Source: [file guide](https://docs.anythink.cloud/guides/database/files). All paths require `anythink_files:{action}` except public download.

| Method/path | Permission | Request | Result | Status |
| --- | --- | --- | --- | --- |
| `POST /files` | create | Multipart **one** part named `file`; optional query `isPublic`, `folderId`, `entityId`, `fieldName` | 201 new file metadata including ID; only first file saved; 50MB cap | D |
| `GET /files` | read | `search`, `fileType`, `folderId`, `sortBy`, `sortDirection`, `page`, `pageSize` | Paginated file envelope; page size 1..1000 | D |
| `GET /files/{id}` | read | None | Metadata; async media probe means media fields may initially be empty | D |
| `GET /files/{id}/get` | read | None | 302 signed-download redirect, valid 1min | D |
| `GET /files/{id}/url` | read | None | `{url,expires_at}`, valid 5min | D |
| `GET /files/{id}/public` | public | None | Redirect to CDN, 404 for private/absent | D |
| `PUT /files/{id}` | update | Partial metadata e.g. `description`, `alt_text`, `tags`, `folder_id` | Exact response/status not stated in guide | D/U |
| `POST /files/{id}/reprobe` | update | None | 202, async media probe | D |
| `DELETE /files/{id}` | delete | None | 204, absent 404 | D |
| `DELETE /files` | delete | `{file_ids:[…]}` | Per-item successful/failed arrays + totals; empty list 400 | D |
| `GET /files/folders` | read | None | Top-level shared and own personal folders; flat array | D |
| `GET /files/folders/tree` | read | None | All accessible folders, flat array sorted by path; `parent_folder_id:null` identifies roots | D |
| `GET /files/folders/{id}` | read | None | Envelope `{folder,sub_folders,breadcrumb}`; folder/subfolders use folder metadata, breadcrumb rows contain `{id,name}`. Endpoint present in project API docs; shape confirmed live. | D / live |
| `POST /files/folders` | create | `{name}` | Mutation response body/status not specified; SDK returns completion only | D/U |
| `PUT /files/folders/{id}` | update | `{name}` to rename, `{parent_folder_id}` to move | Mutation response body/status and root-move write sentinel not specified | D/U |
| `DELETE /files/folders/{id}` | delete | Optional `deleteContents=true` | Default moves files to parent; explicit flag deletes contents; response body/status not specified | D/U |

Record file fields accept ID arrays and return relationships. Private files are
not necessarily isolated per user. No resumable/chunk upload contract was found;
see [transport rules](architecture.md#requests-and-data) for streaming and redirects.

Folders contain `id`, `name`, nullable `parent_folder_id`/`user_id`, `path`,
`file_count` (all descendants) and `sub_folder_count` (direct children). A null
parent in reads does not define how to move a folder to root. Moving a **file**
to root separately uses `folder_id:0` on `PUT /files/{id}`.

## Entitlements and Apple transaction verification

Sources: [Apple IAP](https://docs.anythink.cloud/guides/payments/apple-in-app-purchases), [entitlements](https://docs.anythink.cloud/guides/payments/offers-trials-and-entitlements).

| Method/path | Auth/permission | Request | Result / nuance | Status |
| --- | --- | --- | --- | --- |
| `GET /integrations/anythinkpay/subscriptions/me/entitlement` | user, `anythink_subscription_plans:read` | None | `has_access`, nullable subscription/provider/plan/status/expiry/cancellation/trial/pending fields. Can initiate configured one-time app trial on first read. | D |
| `POST /integrations/anythinkpay/subscriptions/apple/verify` | user, same permission | Either `signed_transaction` JWS or `original_transaction_id` | Subscription ID, bound user, Apple product, plan IDs/name, status/expiry, `has_access`, `matched_known_plan`. Repeat-safe for same transaction. | D |
| `GET/PUT /integrations/anythinkpay/apple-iap/credentials` | admin | Bundle/environment/issuer/key/private key provisioning | Read omits key; reports configured flags/notification URL. Not runtime SDK scope. | D |
| `POST /integrations/anythinkpay/apple-iap/test-notification` | admin | Optional environment query | Token; test delivery with following status route. Not runtime SDK scope. | D |
| `POST /integrations/anythinkpay/apple-iap/test-notification/{token}/status` | admin | Optional environment query | Delivery test status | D |
| Google Play purchase verification | unknown/unsupported in reviewed docs | None | Current docs say Android/web use Stripe; no documented Play verify path. | U |

Apple verification binds the transaction to its first caller: another user gets
409, and a mismatched `appAccountToken` gets 403. Access requires a known plan;
`has_access` alone is insufficient when `matched_known_plan` is false. Verify's
`product_id` is Apple's ID; entitlement's is the subscription/plan name. See the
[StoreKit contract](../packages/anythink_flutter_purchases/doc/storekit-contract.md)
for proof, restore and completion details.

## Push consumer endpoints

Sources: [push guide](https://docs.anythink.cloud/guides/workflows/push-notifications), [permissions](https://docs.anythink.cloud/reference/permissions).

| Method/path | Auth/permission | Request | Result / nuance | Status |
| --- | --- | --- | --- | --- |
| `POST /push/devices` | user, `anythink_tenant_devices:create` | `provider` (`fcm`/`web_push`), `token`; optional metadata; ordinary caller can only own self | `{id,registered_at}`; existing same token refreshes last seen; other owner 409; attempts to name other user 403 | D |
| `GET /push/devices` | admin per push guide | None | Device rows, token preview and last-seen/unregistered metadata | D |
| `DELETE /push/devices/{id}` | admin per push guide | None | User-scoped unregister is not documented | D/U |
| `POST /push/categories/sync` | user/key with `anythink_tenant_push_categories:update` | `app_version`, `categories:[{id,actions:[{id,label}]}]` | Saved groups/actions; syncing replaces actions for each group | D |
| `POST /push/action-events` | signed `notification_id` body credential, **no access token** | `notification_id`, `category`, `action_id`; optional timestamps/data as illustrated | 202 `{received:true}` or `{duplicate:true}`; 400 missing; 401 bad/expired/project/category/action token validation | D |
| `GET /push/vapid-public-key` | public | None | Web push public key | D |

Action credentials expire one hour after send; notification/action pairs are
deduplicated. The host owns FCM/APNs setup, buttons, background handling and
routing. Delivery does not guarantee wake-up or offline execution. Consumer
unregister/rebind remains an [unresolved contract](consumer-api-coverage.md#unresolved-consumer-contracts).

## Errors, headers and replay policy inputs

Sources: [REST reference](https://docs.anythink.cloud/reference/rest-api), [limits](https://docs.anythink.cloud/deploy/limits-and-quotas).

| Wire condition | Contract | SDK consequence |
| --- | --- | --- |
| 400 | Often text; signup may field-error JSON | Tolerant decode, preserve status/message/field errors |
| 401 | Problem JSON or text depending endpoint | Only authenticated operations may invoke session refresh; avoid refreshing public sign-in failures |
| 403 | Permission failure often empty; storage quota can have message | Distinguish as far as evidence allows; do not erase session merely because forbidden |
| 404 | Unknown entity text; missing/hidden record may problem JSON | Do not leak existence inference to app |
| 405 | Empty for unsupported method | No PATCH fallback without deliberate API contract |
| 409 | Feature-specific ownership conflict | Preserve status; caller handles IAP/push ownership failure |
| 429 | JSON `{error,message,retry_after,route_type}` | Expose bounded `retryAfter` metadata; no automatic rate-limit retry |
| 500 | Message; may have traceId | Preserve trace ID; no automatic arbitrary write replay |
| 204 | Empty successful result | Never unconditionally JSON-decode every success |
| `X-RateLimit-Limit/Remaining/Reset` | Documented response headers; deployment-specific limits | Headers are optional in practice; Reset units remain unconfirmed |
| General idempotency/version headers | Not documented for records/uploads | Do not promise replay-safe mutation, ETag conflict handling, exactly-once writes or offline sync |

## Consumer workflow invocation and payment routing

Sources: [workflow triggers](https://docs.anythink.cloud/guides/workflows/triggers),
[webhooks](https://docs.anythink.cloud/guides/rest-api/webhooks),
[payment options](https://docs.anythink.cloud/guides/payments/how-payments-work#payment-options-and-platform-routing)
and [mobile recipe](https://docs.anythink.cloud/guides/payments/recipes#check-access-from-a-mobile-app).

| Method/path | Auth/permission | Request | Result / nuance | Status |
| --- | --- | --- | --- | --- |
| `POST /workflows/api/{route}` | user/key, `anythink_workflows:trigger`; mobile SDK uses user bearer only | One route segment, no slashes; optional `id` and `entity_name` query; JSON body becomes trigger data, empty body means empty data | `204` once queued, not completed; case-insensitive route matching; unknown/disabled route `404` | D |
| `POST /workflows/{id}/trigger` | user/key, `anythink_workflows:trigger`; mobile SDK uses user bearer only | Optional `entity_name`, `entity_id`, `data`; `data` is a JSON-encoded **string**, not a JSON object. Entity is required for configured Manual triggers and checked by server | `204` once queued; no job ID/completion result specified | D |
| `GET /integrations/anythinkpay/payment-options` | signed-in user, `anythink_subscription_plans:read` | `platform`, optional App Store `storefront` query | `primary_provider`, ordered `providers`, `web_checkout_allowed`, storefront; routing policy remains server-owned | D |

SDK methods: `client.workflows.triggerApi`, `client.workflows.trigger` and
`client.subscriptions.paymentOptions`. Workflow calls never replay automatically.
Unexpected success statuses raise a protocol error without proving a retry is
safe. To observe completion, read the workflow's output record; no polling API
is invented. For provider selection, see [billing](billing.md).

## Full-text and similarity search

Sources: [search guide](https://docs.anythink.cloud/guides/database/search) and
the project-generated authenticated/public API reference. The guide's hit examples define
the model; the generic `items: ["string"]` placeholder does not.

| Method/path | Auth | Request | Result / limitation | Status |
| --- | --- | --- | --- | --- |
| `GET /search` | user | `q`, `e`, `s`, `fl`, `f`, `hl`, `page`, `pageSize` | Paginated hits plus nullable `facet_distribution`; signed-in results include full records and apply RLS | D |
| `GET /search/public` | public | Same query parameters; SDK explicitly rejects `hl=true` | Plain query projection passed live. Highlighted `_formatted` exposed private fields; see search validation. SDK sends no bearer | D, live defect |
| `GET /search/similar` | user | `e` entity name, `id` int32, `limit` int32 (default 10) | Bare hit array, not an envelope; source excluded, unknown entity/unindexed source `404`; RLS may reduce result count | D |
| `GET /search/public/similar` | public | `e` string, `id` int32, `limit` int32 | Bare array verified in official CLI and live response, but private fields leaked even with public flags removed. SDK method excluded pending upstream repair | D, live defect |

Search has its own grammar. Omitted `q` or `*` matches all records; `field:text` is explicit field search, and literal colon escaping is undocumented. `e` and `f` contain comma-separated names. `s` contains comma-separated `field:asc|desc` terms or `_geoPoint(lat, lng):asc|desc`. `fl` is an explicitly supplied Meilisearch expression, not a record-list `RecordFilter`. Query pagination is one-based, with default page size 20 and maximum 100. Similarity does not document a separate result-count maximum; positive int32 inputs are enforced without borrowing the query page-size cap.

Search hits preserve their **string** `id`, required `__entity` and `__url`, optional `__name`, and immutable record data. The resource path is a server-supplied hint and is never opened by the SDK. `_formatted` is exposed as `untrustedFormatted`: highlighted copies may contain record-supplied HTML and must be sanitized before rendering markup. Facet counts are nonnegative integers keyed by field and value. RLS can produce shorter pages than `pageSize`; pagination metadata is preserved rather than recomputed from visible items. Index updates are asynchronous, and the guide documents at most 1,000 reachable results per query per entity.

SDK methods: `client.search.query`, `queryPublic` and `similar`. Signed-in reads
allow one 401 recovery; public reads send no credentials. [Live tests](search-validation.md)
found owner-filtered hits but cross-owner totals/facets, plus the public-field
leaks above. SDK restrictions do not secure these backend routes for other clients.

## Consumer billing completion audit

Sources: project-generated OpenAPI,
[official CLI DTOs](https://github.com/Anythink-Ltd/anythink-cli/blob/fe0bae2cda9f536ea08e4a3caa2cb74d8312b9fa/src/Models/ApiModels.cs),
[plans/subscriptions guide](https://docs.anythink.cloud/guides/payments/plans-and-subscriptions),
[Stripe guide](https://docs.anythink.cloud/guides/payments/stripe), and
[offers/balances guide](https://docs.anythink.cloud/guides/payments/offers-trials-and-entitlements).
Every path below starts `/integrations/anythinkpay` and uses an ordinary user's
bearer token.

| Method/path | SDK accessor | Exact contract / distinction |
| --- | --- | --- |
| `GET /subscription-plans`, `GET /subscription-plans/{id}` | `subscriptions.listPlans`, `getPlan` | Bare plan list / single plan. Numeric ID; price/currency/cadence, active flag and optional Apple product/tier fields. |
| `GET /subscriptions?page=&pageSize=` | `subscriptions.list` | Full page envelope, matching the actual project schema and live empty page. |
| `GET /subscriptions/status/{status}` | `subscriptions.listByStatus` | No paging parameters in actual OpenAPI. Live page2/size3 query was ignored, returning page1/size100. No SDK promise of pagination here. |
| `GET /subscriptions/{id}` | `subscriptions.get` | UUID subscription; provider/status strings preserved, nullable period/trial fields, timestamps parsed strictly. |
| `GET /subscriptions/{id}/events` | `subscriptions.events` | Bare event list, UUID event ID and timestamp; unknown event/source strings retained. |
| `GET /subscriptions/check-access?subscription_name=&status=` | `subscriptions.checkAccess` | Required boolean `has_access`, nullable `{id,name,status}` subscription. |
| `POST /subscriptions` | `subscriptions.createCheckout` | Typed catalog-derived values plus customer/subscriber/return metadata; `{anythink_pay_id,checkout_url,session_id}`. Checkout is not entitlement. |
| `POST /subscriptions/{id}/cancel`, `/resume` | `subscriptions.cancel`, `resume` | Explicit Stripe renewal mutation, writable user link. Void HTTP acknowledgement because no reliable response-body schema exists. |
| `GET /payment-methods` | `payments.listMethods` | Bare list of Anythink UUID method records, distinct `stripe_payment_method_id` and optional card metadata. |
| `GET /payment-methods/{paymentMethodId}`, `/payment-methods/query-by-stripe-id?stripePaymentMethodId=` | `payments.getMethod`, `getMethodByStripeId` | Single method; camel-case lookup query preserved exactly. |
| `POST /payment-methods/setup-intent` | `payments.createMethodSetup` | Customer details, usage, description/metadata; `setup_intent_id`, sensitive `client_secret`, `customer_id`, opaque `stripe_object`. |
| `DELETE /payment-methods/{id}` | `payments.removeMethod` | Removes a saved method, not its subscription. |
| `GET /payments`, `/payments/status/{status}`, `/payments/{id}` | `payments.list`, `get` | Normal/status lists accept page/pageSize; single payment contains server state and amount, not local settlement inference. |
| `POST /payments` | `payments.createCheckout` | Exact CreatePaymentRequest including line items and return URLs; checkout creation result. |
| `POST /payments/charge-payment-method` | `payments.chargeMethod` | Anythink method UUID, amount/currency, optional idempotency key and fields. OpenAPI defines `capture_method` as boolean; SDK does not invent its semantics. |
| `GET /payments/payment-intent/{id}` | `payments.getIntent` | Intent status/amount, optional sensitive client secret/next action/provider object. |
| `POST /payments/payment-intent/{id}/confirm`, `/capture?amountToCapture=` | `payments.confirmIntent`, `captureIntent` | Explicit financial operations, no request body; capture query spelling is exact. |
| `GET /offers/me/code`, `/offers/me/codes`, `/offers/me/referrals` | `subscriptions.personalReferralCode`, `personalReferralCodes`, `referralStats` | Exact code/list/stats shape observed in dedicated ordinary account. Single-code GET lazily creates a code; automatic replay disabled. Nonempty recent/tier detail preserved as opaque immutable JSON. |
| `POST /offers/me/redeem/{slug}?subscription_id=` | `subscriptions.redeemOffer` | No invented body. HTTP200 can be rejection: required `success` and `referrer_reward_queued` booleans; caller must inspect success. Reward-summary schema unspecified, preserved as JSON. |
| `GET /balances/me` | `subscriptions.balances` | Bare list `{unit_type,currency,total}`; integer points/credit minor units. No automatic credit spending. |

The [payment guide](https://docs.anythink.cloud/guides/payments/how-payments-work)
requires `anythink_subscription_plans:read` for routing, entitlement, catalog,
Apple verification, offers/me and balances/me. See [billing](billing.md) for
permissions, retries, sensitive output and live validation limits.
