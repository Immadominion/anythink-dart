import 'package:anythink_dart/anythink_dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'native_sign_in_exception.dart';

/// Obtains native credentials and exchanges them through an existing client.
///
/// This adapter does not own [auth] or the provider SDKs. Initialize
/// [GoogleSignIn.instance] exactly once in the application and await completion
/// before calling [signInWithGoogle]. Invoke sign-in from a foreground user
/// interaction. Apple is supported on iOS; Google on Android and iOS.
///
/// The Anythink backend verifies the ID token and checks the provider identifier
/// against its subject. No client-side token decoding is used as authentication.
final class AnythinkNativeAuth {
  AnythinkNativeAuth({required this.auth});

  final AnythinkAuth auth;

  // The provider SDKs have process-global state. Serialize UI/exchanges across
  // adapter instances in this isolate, not merely within one client instance.
  static bool _operationPending = false;

  /// Acquires an ID token and Google account ID through the initialized plugin.
  ///
  /// Cancellation does not clear the current Anythink session. This method does
  /// not sign out or revoke a Google grant; account selection is app-owned.
  Future<Session> signInWithGoogle({Map<String, String>? signupContext}) =>
      _signIn(NativeProvider.google, _googleCredential, signupContext);

  /// Acquires an Apple ID token and subject through the native iOS UI.
  ///
  /// First-authorization names are forwarded when supplied by Apple. Email is
  /// never substituted for the subject. Apple's web flow requires a different
  /// configuration and is deliberately outside this native adapter.
  Future<Session> signInWithApple({Map<String, String>? signupContext}) =>
      _signIn(NativeProvider.apple, _appleCredential, signupContext);

  Future<Session> _signIn(
    NativeProvider provider,
    Future<_Credential> Function(void Function() ensureCurrent) acquire,
    Map<String, String>? signupContext,
  ) async {
    _requirePlatform(provider);
    if (_operationPending) {
      throw NativeSignInException(
        provider: provider,
        failure: NativeSignInFailure.operationInProgress,
      );
    }
    final context = signupContext == null
        ? null
        : Map<String, String>.unmodifiable(signupContext);
    final generation = auth.generation;
    void ensureCurrent() {
      if (auth.generation != generation) {
        throw const SessionChangedException();
      }
    }

    _operationPending = true;
    try {
      final credential = await acquire(ensureCurrent);
      // Logout or another login while the provider UI was open wins. Never
      // resurrect that session with a late result from the native dialog.
      ensureCurrent();
      return await auth.signInWithNativeToken(
        provider: provider,
        identityToken: credential.identityToken,
        userIdentifier: credential.userIdentifier,
        givenName: credential.givenName,
        familyName: credential.familyName,
        signupContext: context,
      );
    } finally {
      _operationPending = false;
    }
  }

  static void _requirePlatform(NativeProvider provider) {
    final supported =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            (provider == NativeProvider.google &&
                defaultTargetPlatform == TargetPlatform.android));
    if (!supported) {
      throw NativeSignInException(
        provider: provider,
        failure: NativeSignInFailure.unsupportedPlatform,
      );
    }
  }

  static Future<_Credential> _googleCredential(
    void Function() ensureCurrent,
  ) async {
    const provider = NativeProvider.google;
    try {
      final google = GoogleSignIn.instance;
      if (!google.supportsAuthenticate()) {
        throw const NativeSignInException(
          provider: provider,
          failure: NativeSignInFailure.unavailable,
        );
      }
      ensureCurrent();
      final account = await google.authenticate();
      // Older Android plugin versions can fall back to email when they cannot
      // extract a subject. Anythink requires the subject, not an email fallback.
      if (account.id == account.email) {
        throw const NativeSignInException(
          provider: provider,
          failure: NativeSignInFailure.missingUserIdentifier,
        );
      }
      return _Credential.validated(
        provider: provider,
        identityToken: account.authentication.idToken,
        userIdentifier: account.id,
      );
    } on NativeSignInException {
      rethrow;
    } on SessionChangedException {
      rethrow;
    } on GoogleSignInException catch (error) {
      throw NativeSignInException(
        provider: provider,
        failure: switch (error.code) {
          GoogleSignInExceptionCode.canceled => NativeSignInFailure.canceled,
          GoogleSignInExceptionCode.interrupted =>
            NativeSignInFailure.interrupted,
          GoogleSignInExceptionCode.clientConfigurationError ||
          GoogleSignInExceptionCode.providerConfigurationError =>
            NativeSignInFailure.invalidConfiguration,
          GoogleSignInExceptionCode.uiUnavailable =>
            NativeSignInFailure.unavailable,
          _ => NativeSignInFailure.providerFailure,
        },
      );
    } on MissingPluginException {
      throw const NativeSignInException(
        provider: provider,
        failure: NativeSignInFailure.unavailable,
      );
    } catch (_) {
      throw const NativeSignInException(
        provider: provider,
        failure: NativeSignInFailure.providerFailure,
      );
    }
  }

  static Future<_Credential> _appleCredential(
    void Function() ensureCurrent,
  ) async {
    const provider = NativeProvider.apple;
    try {
      if (!await SignInWithApple.isAvailable()) {
        throw const NativeSignInException(
          provider: provider,
          failure: NativeSignInFailure.unavailable,
        );
      }
      ensureCurrent();
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      return _Credential.validated(
        provider: provider,
        identityToken: credential.identityToken,
        userIdentifier: credential.userIdentifier,
        givenName: credential.givenName,
        familyName: credential.familyName,
      );
    } on NativeSignInException {
      rethrow;
    } on SessionChangedException {
      rethrow;
    } on SignInWithAppleAuthorizationException catch (error) {
      throw NativeSignInException(
        provider: provider,
        failure: switch (error.code) {
          AuthorizationErrorCode.canceled => NativeSignInFailure.canceled,
          AuthorizationErrorCode.notInteractive =>
            NativeSignInFailure.unavailable,
          _ => NativeSignInFailure.providerFailure,
        },
      );
    } on SignInWithAppleNotSupportedException {
      throw const NativeSignInException(
        provider: provider,
        failure: NativeSignInFailure.unavailable,
      );
    } on MissingPluginException {
      throw const NativeSignInException(
        provider: provider,
        failure: NativeSignInFailure.unavailable,
      );
    } catch (_) {
      throw const NativeSignInException(
        provider: provider,
        failure: NativeSignInFailure.providerFailure,
      );
    }
  }
}

final class _Credential {
  _Credential.validated({
    required NativeProvider provider,
    required String? identityToken,
    required String? userIdentifier,
    this.givenName,
    this.familyName,
  }) : identityToken = _requiredCredential(
         provider,
         identityToken,
         NativeSignInFailure.missingIdentityToken,
       ),
       userIdentifier = _requiredCredential(
         provider,
         userIdentifier,
         NativeSignInFailure.missingUserIdentifier,
       );

  final String identityToken;
  final String userIdentifier;
  final String? givenName;
  final String? familyName;

  static String _requiredCredential(
    NativeProvider provider,
    String? value,
    NativeSignInFailure failure,
  ) {
    if (value == null || value.trim().isEmpty) {
      throw NativeSignInException(provider: provider, failure: failure);
    }
    return value;
  }
}
