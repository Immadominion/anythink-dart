# Upstream questions before release

These contracts need clarification before the corresponding features can be
release-tested. Observations used a disposable project and synthetic data.

1. **Magic links:** What are the public request/consume routes, request bodies,
   response envelopes, expiry, single-use and deep-link contracts? The role and
   email templates mention magic links, but the reviewed auth guide, TypeScript
   SDK, CLI and project OpenAPI do not define an application API for them.
2. **Native identity replay:** Does native Apple/Google exchange accept and verify
   a nonce? If so, specify its wire field and whether it expects a raw or hashed
   value. The current SDK does not invent a nonce field or claim replay binding.
   Also clarify whether verified native email activates a pending invitation,
   since the documented linking and inactive-user rules do not establish this.
3. **Device ownership at logout/account switch:** What consumer operation revokes
   or reassigns a registered push token? The documented register route can reject
   another owner's token with 409. Deleting a Firebase token is separate from
   removing its Anythink registry entry, which currently requires admin cleanup.
4. **Search confidentiality:** Anonymous highlighted results included a private
   searchable body in `_formatted.body`; anonymous similarity returned that body
   even after searchable fields were private. Authenticated result counts/facets
   included another owner's hidden records. See the exact setup, cleanup and
   observations in [search validation](search-validation.md). Public highlighting
   is blocked locally and anonymous similarity is not exposed by this SDK.
5. **Workflow trigger permission:** The dashboard's workflow-trigger checkbox did
   not persist for the ordinary App User, although other permissions saved.
   Both inspected permission names returned false and the API trigger returned
   403 without queueing a job. Which supported permission/configuration grants
   this access? The validation workflow is disabled pending resolution.
6. **Payment schema precision:** Confirm the semantics of the documented boolean
   `capture_method` on saved-method charge and publish the missing plan, offer
   and balance schemas in generated OpenAPI. The SDK follows the inspected wire
   type, does not substitute Stripe's string enum, and never retries a charge.
7. **Native sign-in with closed registration:** Real Google exchange for an
   already activated ordinary project user returned HTTP 400 with
   `Organisation does not have a default role for new users`. The dashboard only
   exposes that default when registrations are enabled. Selecting App User and
   saving with registrations disabled did not retain the role after navigation.
   How should an invitation-only application configure native login without
   opening new-user registration? Account activation alone did not resolve this
   prerequisite. No successful Google exchange is inferred from token acquisition.

These questions do not block use of already verified features. They do block
claims that the respective uncertain behavior is implemented or release-tested.
