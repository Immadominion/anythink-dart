# anythink_dart

Connect a Dart app to Anythink: sign users in, work with records and files,
search data, run workflows, and use payment and subscription APIs.

**Unofficial, unpublished development package.** Requires Dart 3.8 or newer.
It has no Flutter or native-provider dependencies. Use the repository's local
installation instructions until publication.

## Start with a client

Use your project's HTTPS API origin and project ID. The user must have read
permission for the existing `notes` entity in this example.

```dart
import 'package:anythink_dart/anythink_dart.dart';

Future<List<JsonObject>> loadNotes(AnythinkClient client) async {
  final page = await client.records('notes').list(
    query: RecordQuery(pageSize: 20),
  );
  return page.items;
}
```

Create the client with `AnythinkClient(apiOrigin: origin, projectId: projectId)`
and sign in using `client.auth.signInWithPassword(email: email, password: password)`
before calling `loadNotes`. The [runnable example](example/anythink_dart_example.dart)
includes configuration, typed records, sign-in and cleanup.

## What is available

| API | Purpose |
| --- | --- |
| `auth` | Password, native and web sign-in; identity and rotating sessions |
| `records()` / `collection<T>()` | Read and write records, with optional app-defined types |
| `files` / `files.folders` | Streaming transfers, public links and folder operations |
| `search` / `workflows` | Search data and invoke configured workflows |
| `payments` / `subscriptions` | Checkout, payment methods, plans, access and Apple verification |
| `push` | Register devices and report signed notification actions |

Sessions stay in memory unless you supply a `SessionStore`. Call
`auth.restoreSession()` explicitly to restore one, `auth.getUser()` to load
identity, and `auth.signOut()` to clear it. `client.close()` releases resources;
it does not sign the user out. Flutter apps can add `anythink_flutter` for storage.

Writes are not automatically replayed after a network failure. An uncertain
result needs reconciliation before retrying. A queued workflow or checkout
response also does not mean the workflow or payment finished.

In this checkout, `docs/consumer-api-coverage.md` is the API map,
`docs/billing.md` covers payments, and `docs/validation.md` records live results.
Review `docs/search-validation.md` and the file-access results in
`docs/live-validation.md` before using confidential data. Public highlighting
and anonymous similarity are withheld because of observed backend disclosures.

Run `dart test` from this package after resolving workspace dependencies.
