# Live auth and records contract validation

`tool/live_contract.dart` is an opt-in integration runner using the public
`anythink_dart` SDK against a real project. It signs in two ordinary application
users, rotates their sessions, creates three disposable notes, checks own-user
CRUD and cross-user isolation, and deletes only the IDs returned by this run's
creates. It does not provision users, change roles or schema, configure billing,
send email, or use administrator credentials.

**Current status:** actual live results and remaining gates are recorded in
[validation.md](validation.md). A successful local config check or ordinary
unit test is not a live API result.

## Exact prerequisites

1. A dedicated disposable Anythink project, with no production data, backed by
   the intended free plan. Confirm the project ID and its regional API origin
   from the dashboard. The runner does not verify billing or create a project.
2. A nonpublic entity named `notes` (or the configured `entity`) with writable
   text fields `title` and `body`. A `varchar` title and `text` body are suitable.
   The runner always supplies both on create. It does not supply owner fields.
   Any additional required field must have a server default; otherwise this
   runner's fixed schema does not fit the project.
3. Row-level security enabled on the entity, with ownership assigned by the
   server to the creating user and enforced for list/read/update/delete. Public
   reads must not expose the notes. Client-side filtering is not an access rule.
4. A dedicated role, `App User` by default, with API access and only the entity's
   `read`, `create`, `update` and `delete` permissions. Do not use the built-in
   Standard User role, which grants team-level management capabilities. The
   runner requires `isAdmin()` to be false, `hasRole(required_role)` to be true,
   `hasRole('Standard User')` to be false, and `/users/me.can_access_any_api` to
   be true before creating any fixtures. These runtime checks do not replace
   an administrator's prior audit of the dedicated role's complete permissions.
5. Two distinct ordinary test users assigned only that restricted role. Their
   password sign-in must work; complete email confirmation if the project
   requires it. Use controlled test identities. The runner creates no accounts
   and sends no confirmation or reset messages.
6. This workspace's dependencies resolved with Flutter, then a macOS or Linux
   host with Dart and Git available. The runner uses owner-only POSIX file modes
   and requires HTTPS. It intentionally cannot be pointed at an HTTP test server.
7. Do not modify these fixtures concurrently. The run uses unique random title
   prefixes, but concurrent data changes can invalidate pagination evidence.

Relevant upstream contracts:
[row-level security](https://docs.anythink.cloud/guides/authentication/groups-and-row-level-security),
[permissions](https://docs.anythink.cloud/reference/permissions), and
[roles](https://docs.anythink.cloud/guides/authentication/roles-and-permissions).

## Private configuration

Use a private editor or provisioner to write `.secrets/live-contract.json` under
this repository. Do not put passwords, tokens or complete JSON in shell command
arguments, shell history, source files or a commit. `.secrets/` is already Git
ignored. The file must have mode `0600`; keep its directory mode `0700`.

The JSON object has these properties. This table describes the schema without
embedding credential placeholders that could accidentally be used as accounts.

| Property | JSON type | Requirement |
| --- | --- | --- |
| `api_origin` | string | Actual regional HTTPS origin, without `/org`, any other path, query, fragment or URI credentials. |
| `project_id` | string | Actual disposable project's ID. |
| `disposable_project` | boolean | Must explicitly be `true`. |
| `users` | array | Exactly two objects, each containing only `email` and `password`, both strings. Values must be the actual test-user credentials. Emails must differ. |
| `entity` | string | Optional; defaults to `notes`. Must satisfy the schema above. |
| `required_role` | string | Optional; defaults to `App User`. Must be a dedicated ordinary role, not Standard User or administrator. |
| `verify_persistence` | boolean | Optional; defaults to `true`. Enables the temporary atomic file session-store check described below. |

Unknown configuration keys are rejected. The resolved config must be inside the
repository's `.secrets/` directory, be a regular file of at most 64 KiB, have mode
`0600`, and be confirmed ignored by `git check-ignore`. Credentials are never
printed, including on malformed-JSON failures. Keep these identities dedicated
to this disposable project; do not reuse production passwords.

From the repository root, after creating the private file:

```sh
chmod 700 .secrets
chmod 600 .secrets/live-contract.json
dart run tool/live_contract.dart --help
dart run tool/live_contract.dart --config .secrets/live-contract.json --check-config
```

`--help` does not read configuration. `--check-config` performs only local file,
Git-ignore and schema checks. Neither makes network requests. A config check
prints `LOCAL CONFIG VALID`, not a live contract pass.

## Deliberate live execution

Only run this after the prerequisites and config have been reviewed:

```sh
dart run tool/live_contract.dart --config .secrets/live-contract.json --ack-disposable-project
```

Both `disposable_project: true` in the config and the CLI acknowledgement are
required. The command uses the current project exactly as configured; it does
not obtain authority from a logged-in administrator's browser or CLI session.

The runner checks:

1. Password sign-in, current-user identity, non-admin status, dedicated role and
   API access for A and B. Both numeric IDs and global IDs must differ.
2. Explicit refresh for each user. The refresh token must rotate and the user
   identity must remain unchanged. Credentials are compared only in memory.
3. When requested, close A's client without logout, restore from the temporary
   session store with a new client, and fetch the same server identity.
4. A creates and reads two records. B creates, reads and updates its own record.
5. A partial `PUT` changes only `title`, preserving `body` on read-back.
6. A's starts-with filter returns exactly its two fixtures, split across two
   single-item pages with correct totals/navigation and ascending IDs. Descending
   order and an exact title filter are independently checked.
7. B's filtered run-prefix listing returns only B's fixture. A direct ID filter
   returns no A record. An unfiltered listing is traversed to its end, without A's
   IDs, proving the client filter is not the isolation mechanism. The traversal
   caps at 100 pages of 100 records; exceeding that bound fails as incomplete.
8. B's direct get and update of A's record each return **403 or 404**. A reads its
   record after the denied update to confirm unchanged contents. B's delete must
   return **403/404**, or exactly **204** followed by a mandatory successful
   owner read proving the same title/body remain unchanged. A 204 alone is never
   an isolation pass. A status-only real HTTP client observer captures the
   response code without logging credentials, URLs or bodies. Blanket denial is
   not accepted because B's own CRUD is independently required to succeed.
9. Both users can delete their own fixture, followed by a 404 read. Cleanup
   deletes A's remaining tracked fixture and verifies it is gone.

The [REST reference](https://docs.anythink.cloud/reference/rest-api) states that
delete returns 204 even when the record does not exist. Live testing confirmed a
record hidden by RLS also receives a 204 no-op: B cannot read it, and A reads the
same unchanged record after B's attempted deletion. The runner originally
required a denial code here and failed; a separate real fixture established
the no-op behavior before the guard was changed. Local HTTP regression tests
also require failure if a 204 actually deletes or modifies the owner's row, if
the successful status is not 204, or if the API returns an unexpected error.

The runner stops on the first failed contract check and enters cleanup. It prints
fixed check labels and redacted error categories/HTTP status codes, not emails,
passwords, tokens, record bodies, response payloads or stack traces. Each HTTP
operation has a 30-second request timeout. There is no server-mutation retry in
the test phases; the final cleanup may repeat deletion of a tracked ID.

## Persistence and cleanup boundaries

When enabled, the CLI-only session store creates an OS temporary directory with
mode `0700`. Each write creates a fresh sibling file, sets mode `0600` before
writing credentials, flushes it, and atomically renames it over the session
file. Core session envelopes retain their API-origin/project scope. This
short-lived test store is plaintext protected by file permissions, **not** the
production Flutter secure-storage implementation. It is removed at the end.

Setting `verify_persistence` to `false` narrows the requested scope to in-memory
auth/records validation. The output explicitly states persistence was not
requested; it never claims a persistence test passed.

Cleanup uses only exact IDs returned by this run's create calls. It never deletes
by prefix, scans and deletes existing notes, uses bulk deletion, or borrows an
administrator credential. It verifies deletion by an owning-user 404, attempts
remote logout of acquired sessions, closes clients, and removes the temporary
session directory even after a failed contract check.

A lost/invalid create response or server error can leave an untracked record
whose ID the runner never received. That condition is reported as incomplete;
there is no broad cleanup guess. An interrupted process can also leave records
or its protected temporary directory. Inspect the dedicated project and OS
temporary directory manually after such failures. Cancellation and transport
errors cannot prove a server mutation never committed.

If a refresh outcome becomes uncertain, cleanup may be unable to authenticate.
The runner reports the failure instead of retrying a single-use refresh token
or pretending remote revocation succeeded.

## Interpreting results

| Exit | Meaning |
| --- | --- |
| `0` | All requested live checks and cleanup passed, **or** the explicitly requested local help/config operation succeeded. Read the final output label to distinguish them. |
| `1` | Live execution, contract verification, response interpretation or cleanup is incomplete. |
| `64` | Arguments/private config failed validation; no live run began. |

Only the final live `PASS` line supports a live auth/records result for that
specific project, schema and role configuration. Record the execution time,
project's nonsecret ID/origin, SDK revision, requested persistence scope and
redacted check output alongside any claim. Partial `[PASS]` lines followed by
`INCOMPLETE` are not an overall pass.

Files, native Google/Apple sign-in, Apple purchase verification, push registration,
FCM/APNs delivery and notification actions are outside this runner's scope.
They require separate live permissions/credentials and explicit validation;
this script produces no skipped-as-success result for them.

## Separate executed file and read observations

Nine separate file/folder checks passed using tiny synthetic text files and
unique test folders. They cover uploads, metadata, signed/public streamed downloads,
folder operations, listing and exact-ID cleanup. The file role was expanded
only after the notes-only auth/records run completed.

Private file access is distinct from record RLS: another ordinary user with
the same file-read permission obtained the synthetic private file's metadata
and exact bytes (HTTP 200), while anonymous access through the public route
returned 404.
Do not use the notes' isolation result as a claim of per-user file ownership.

The initial additional live reads
separately verify the public SDK folder-by-ID method's authenticated response
envelope and breadcrumb decoding, plus authenticated/public search response
decoding. At that point no search index or fixture was configured; empty pages
do not prove indexed record visibility or search RLS. The later
[indexed search validation](search-validation.md) records the measured access
control limitations. Both initial payment-option queries returned 403 under
the restricted role. Adding the documented plan-read permission enabled the
later consumer billing reads.
No billing, purchase, entitlement, provider configuration or workflow mutation
was performed by those initial checks.
