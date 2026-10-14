# Validation

Checked 14 October 2026. Automated tests, live backend checks and device checks
cover different boundaries; none implies that every provider flow is ready.

## Automated checks

Run `bash tool/check.sh` with Flutter 3.44.2 / Dart 3.12.2. It checks formatting,
analysis, SDK and host tests, validation-runner tests, and CLI help paths. Tests
use local HTTP servers and controlled plugin boundaries. No live project or
payment is contacted by this command.

Each package also passed isolated checks on its declared minimum toolchain,
with latest-compatible and lowest-direct dependencies. See
[compatibility](compatibility.md) for commands and supported versions.

## Live backend checks

Checks used ordinary users and synthetic data in a dedicated disposable project.

| Area | Observed result |
| --- | --- |
| Auth and records | Password sign-in, identity/roles, refresh rotation, persistence, CRUD, partial updates, filtering, pagination and owner isolation passed. |
| Files and folders | Upload, metadata, byte-exact download, public/private anonymous access, folder operations and cleanup passed. Private files were also readable by another user with file permission; this is not per-user isolation. |
| Search | Owner-filtered hits, private-body search, highlighting and similarity passed. Counts/facets included hidden rows, and anonymous highlights/similarity exposed private synthetic fields. See [search limits](search-validation.md). |
| Consumer billing | Catalog, own-data, routing and access reads passed. No paid checkout, card setup, charge, redemption or sandbox purchase was executed. |
| Workflows | The ordinary test role could not retain the trigger permission; the API returned 403. Successful workflow execution is not verified. |
| Google sign-in | Android acquired a real credential, but Anythink rejected exchange because the project had no default role. Successful exchange and native cancellation remain unverified. |

## Native checks

Password sessions passed on Android 16, an iOS 26.5 simulator, and an iPhone on
iOS 27: sign-in, identity, secure persistence, process restart, refresh rotation,
logout and durable session removal. The physical iOS run used Flutter 3.47.7 /
Dart 3.13.5 with Xcode 26.5. Additional interruption checks passed on Android and
the simulator. Lock/unlock, backup and upgrade behavior still need device tests.

Android Firebase checks covered foreground delivery, background notification tap
and terminated launch. iOS APNs delivery, token rotation, permission denial,
notification actions and account-switch privacy need separate validation.

The normal native app builds and launches on Android and iOS. Provider sign-in,
push and purchases are opt-in integrations and are not enabled in its sign-in UI.
See [provider setup](../integration/native_host/PROVIDER_READINESS.md).

## Before a release

- Complete Google/Apple native sign-in and cancellation checks.
- Complete iOS push and Android lifecycle/ownership edge cases.
- Verify StoreKit sandbox purchase, restore, entitlement and account binding.
- Resolve or explicitly accept the documented backend contract limitations.
- Run strict package preflight and review changelogs.

Packages remain unpublished, with `publish_to: none`. Raw local reports,
credentials and account-console screenshots are not distributed with the SDK.
