import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_flutter_auth/anythink_flutter_auth.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Application bootstrap. Call exactly once when the app owns Google SDK setup.
/// If the app already initializes GoogleSignIn.instance, reuse that setup and
/// construct AnythinkNativeAuth(auth: client.auth) directly instead.
Future<AnythinkNativeAuth> prepareNativeSignIn({
  required AnythinkClient client,
  required String googleServerClientId,
  String? googleIosClientId,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  await GoogleSignIn.instance.initialize(
    clientId: googleIosClientId,
    serverClientId: googleServerClientId,
  );
  return AnythinkNativeAuth(auth: client.auth);
}

/// Invoke from the user's Google button, after prepareNativeSignIn completes.
/// A null result means the provider reported cancellation; show other failures
/// in the app's normal error UI without logging raw provider credentials.
Future<Session?> onGoogleSignInPressed(AnythinkNativeAuth native) async {
  try {
    return await native.signInWithGoogle();
  } on NativeSignInException catch (error) {
    if (error.failure == NativeSignInFailure.canceled) return null;
    rethrow;
  }
}

/// Invoke from an Apple-compliant sign-in button on iOS.
Future<Session?> onAppleSignInPressed(AnythinkNativeAuth native) async {
  try {
    return await native.signInWithApple();
  } on NativeSignInException catch (error) {
    if (error.failure == NativeSignInFailure.canceled) return null;
    rethrow;
  }
}
