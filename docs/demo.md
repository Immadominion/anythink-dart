# Flutter notes demo

A small app using the SDK to sign in, read the user's notes and create a note
against a real Anythink project. Restart it to restore the securely stored
session. The standard session-validation entrypoint remains separate.

From `integration/native_host`:

```sh
flutter run -t lib/demo_main.dart \
  --dart-define=ANYTHINK_API_ORIGIN=https://your-region.anythink.cloud \
  --dart-define=ANYTHINK_PROJECT_ID=your-project-id
```

Create a `notes` entity with `title` and `body` text fields. Enable row-level
security and give an ordinary app user API access plus read/create permissions
for that entity. Use that user to sign in. An administrator bypasses row-level
security and cannot demonstrate user isolation.

## Walkthrough

1. Sign in. Notes load from the REST API.
2. Open a note, then create one with **New note**.
3. Tap **Reload notes** to fetch it again.
4. Close and reopen the app. Tap **Use saved session**.
5. Sign out. The notes disappear and the saved session is cleared.

The app does not embed credentials, prefill records or substitute sample results
when requests fail. It supports paginated reads; write requests are not retried
automatically. Native social sign-in, purchases and push are outside this demo.

## What the package handles

The app owns its note model and UI. The SDK handles request headers, response
parsing, session refresh, errors and pagination parameters. Flutter integration
adds secure session storage and lifecycle refresh checks. Permissions and
record ownership are enforced in the backend.
