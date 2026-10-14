# anythink_flutter_auth

Let people sign in to Anythink with their Google or Apple account. This package
opens the native provider screen, then sends its credential to Anythink for
verification and an app session.

**Unofficial, unpublished development package.** Google targets Android/iOS;
Apple targets iOS. Requires Flutter 3.44 and Dart 3.12 or newer. Configured
provider testing is still in progress; see the checkout's
`integration/native_host/PROVIDER_READINESS.md` for current results.

## Use

Reuse your app's `AnythinkClient`. For Google, add `google_sign_in` as a direct
app dependency and initialize its singleton exactly once during bootstrap:

```dart
import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_flutter_auth/anythink_flutter_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

Future<AnythinkNativeAuth> prepareGoogle(
  AnythinkClient client, {
  required String serverClientId,
  String? iosClientId,
}) async {
  await GoogleSignIn.instance.initialize(
    clientId: iosClientId,
    serverClientId: serverClientId,
  );
  return AnythinkNativeAuth(auth: client.auth);
}
```

Initialize Flutter bindings first. If Google is already initialized, just create
`AnythinkNativeAuth(auth: client.auth)`. An Apple-only app needs no Google setup.
Call `native.signInWithGoogle()` or `native.signInWithApple()` from the appropriate
foreground sign-in button. The [example](example/native_sign_in.dart) includes
cancellation handling.

## Configure the provider

| Provider | Required setup |
| --- | --- |
| Google Android | OAuth client for the app package and signing SHA; web OAuth client ID as `serverClientId` |
| Google iOS | iOS OAuth client ID, reversed-client-ID URL scheme and the intended server audience |
| Apple iOS | Sign in with Apple capability, entitlement and matching signing profile |
| Anythink | Provider enabled, matching native audiences and an appropriate default signup role |

Follow [Google's setup](https://pub.dev/packages/google_sign_in),
[Apple's plugin setup](https://pub.dev/packages/sign_in_with_apple), and
[Anythink's provider guide](https://docs.anythink.cloud/guides/authentication/social-sign-in).
Provider secrets belong on the backend, not in the app.

## Handle results

A returned session means the Anythink exchange succeeded; local token decoding
is not identity verification. `NativeSignInException.failure` distinguishes
cancellation, configuration, missing credentials and other native failures.
Backend failures retain the core SDK's error types.

Only one native sign-in can run at a time. Logout or another login invalidates
late results. The adapter does not close your client, revoke provider consent or
control Google's selected account. Browser OAuth is a separate core SDK flow.
The backend's nonce/replay contract remains an open validation question.

Run `flutter test` in this package. See `docs/compatibility.md` and
`integration/native_host/VALIDATION.md` in the checkout for compatibility and
live-provider evidence.
