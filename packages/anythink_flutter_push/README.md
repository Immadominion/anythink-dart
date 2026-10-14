# anythink_flutter_push

Register a phone for Anythink notifications through Firebase Messaging. The
adapter tracks the current user and token, checks registration when the app
resumes, and exposes incoming messages and notification taps.

**Unofficial, unpublished development package.** Targets Android/iOS with Flutter
3.38.1 and Dart 3.10 or newer. Real Android/iOS foreground delivery and token
rotation have passed, plus Android background taps and terminated launches.
See the checkout's `integration/native_host/VALIDATION.md` for remaining checks,
including iOS background delivery and Anythink-originated sending.

## Set up Firebase

Follow [Firebase's Flutter setup](https://firebase.google.com/docs/cloud-messaging/flutter/get-started).
Add `firebase_core` and `firebase_messaging` to the app, configure its Firebase
registration, and initialize Firebase before creating this adapter.

Android needs API 23+ and a compatible Google Play services device. iOS needs
15+, Push Notifications and background configuration, APNs credentials in Firebase,
and the required method swizzling. Your app owns notification channels, foreground
display and Firebase auto-initialization policy.

If your app disables Firebase auto-initialization, explicitly enable it after
the user opts in with `await FirebaseMessaging.instance.setAutoInitEnabled(true)`.
On iOS, FlutterFire defers APNs registration until then; the adapter reports
`apnsPending` while no APNs token is available.

Sign in to Anythink with an application user that has API access and
`anythink_tenant_devices:create`. For sending **from Anythink**, also configure
FCM server credentials in Anythink and use its managed device source. Those
credentials are unnecessary for registration or Firebase Console test messages
and never belong in the mobile app.

## Register and request permission

After Firebase initialization and Anythink sign-in/restoration:

```dart
import 'package:anythink_flutter_push/anythink_flutter_push.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

final push = AnythinkFirebasePush(
  client: client,
  messaging: FirebaseMessaging.instance,
);
await push.start(); // Checks registration without showing a permission prompt.

// From your app's Enable notifications button:
await push.requestPermission();
final result = await push.synchronize();
```

Use `result.status` or the `results` stream to handle denied permission, pending
APNs registration, unavailable tokens and successful registration. Explicit calls
return errors; automatic synchronization failures go to `onError` when supplied,
or Flutter's error reporter. Native failures are redacted `PushNativeException`s.

## Receive messages

| API | Event |
| --- | --- |
| `messages` | Message received in the foreground |
| `openedMessages` | Notification tapped while the app was in the background |
| `getInitialMessage()` | Notification that launched a terminated app |

Keep one adapter per app session. `getInitialMessage()` returns at most one
nonnull launch message per adapter. Your app owns stream subscriptions, routing,
background handlers and notification action buttons. Validate routing against
the current account; message contents are not proof of authorization.

Cancel your subscriptions and call `await push.dispose()` when finished.
**Logout/disposal does not unregister the phone or stop already-targeted messages.**
Anythink has no documented consumer unregister/rebind API; shared-account apps
need a backend cleanup design before sending private notifications.

See [Firebase message handling](https://firebase.google.com/docs/cloud-messaging/flutter/receive)
and the [Anythink push guide](https://docs.anythink.cloud/guides/workflows/push-notifications)
for delivery and signed action reporting. The checkout's
`integration/native_host/PROVIDER_READINESS.md` lists remaining setup and contract gaps.
Run `flutter test` in this package for the automated boundary tests.
