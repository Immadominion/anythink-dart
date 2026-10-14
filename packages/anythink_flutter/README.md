# anythink_flutter

Keep an Anythink user signed in across app restarts, using the phone's protected
storage. A small lifecycle helper checks whether the session needs refreshing
when the app returns to the foreground.

**Unofficial, unpublished development package.** Requires Flutter 3.38.1 and
Dart 3.10 or newer. Android and iOS are the initial targets.

## Set up a persistent session

Initialize Flutter first. Use the same API origin and project ID for the store
and client, then restore the saved session explicitly.

```dart
import 'package:anythink_flutter/anythink_flutter.dart';
import 'package:flutter/widgets.dart';

Future<AnythinkClient> openClient(Uri origin, String projectId) async {
  WidgetsFlutterBinding.ensureInitialized();
  final client = AnythinkClient(
    apiOrigin: origin,
    projectId: projectId,
    sessionStore: SecureSessionStore(apiOrigin: origin, projectId: projectId),
  );
  try {
    await client.auth.restoreSession();
    return client;
  } catch (_) {
    await client.close();
    rethrow;
  }
}
```

Keep one client and store for that session. In the app scope that owns the client:

```dart
final lifecycle = AnythinkLifecycleBridge(auth: client.auth);
lifecycle.attach();

// When that scope ends:
lifecycle.dispose();
await client.close();
```

The bridge does not own the client or restore a session for you. To log out,
call `client.auth.signOut()`; closing the client alone keeps the saved session.

## Platform setup

Follow the [secure-storage plugin setup](https://pub.dev/packages/flutter_secure_storage):
Android needs API 23+ and backup exclusions for encrypted preferences; iOS needs
the appropriate Keychain entitlements and signing configuration.

The default iOS store is available only while unlocked and stays on that device.
A storage error is reported as `SecureSessionStoreException`, without exposing
tokens or falling back to plain text. Handle a locked-device failure as retryable,
not as proof the account was revoked.

Browser persistence is off by default. `allowWebPersistence: true` opts into the
plugin's browser storage, which has different protection from native Keychain.
Use a single session owner; storage ordering does not coordinate other isolates
or processes. Detailed session behavior is in the checkout's `docs/architecture.md`.

Run `flutter test` from this package. Native-device results and remaining checks
are recorded in `integration/native_host/VALIDATION.md`; toolchain results are
in `docs/compatibility.md`.
