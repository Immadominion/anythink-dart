import 'dart:async';
import 'dart:convert';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_flutter_auth/anythink_flutter_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart'
    as google;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sign_in_with_apple_platform_interface/sign_in_with_apple_platform_interface.dart'
    as apple;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final googlePlatform = _GooglePlatform();
  final applePlatform = _ApplePlatform();
  final originalGoogle = google.GoogleSignInPlatform.instance;
  final originalApple = apple.SignInWithApplePlatform.instance;
  late AnythinkClient client;
  late AnythinkNativeAuth native;
  late List<http.Request> requests;
  var backendStatus = 200;

  setUpAll(() async {
    google.GoogleSignInPlatform.instance = googlePlatform;
    apple.SignInWithApplePlatform.instance = applePlatform;
    // The real app-facing singleton is initialized exactly once, as required
    // by Google 7.x. Test doubles exist only at the platform/HTTP boundaries.
    await GoogleSignIn.instance.initialize(serverClientId: 'test-client-id');
  });

  tearDownAll(() {
    google.GoogleSignInPlatform.instance = originalGoogle;
    apple.SignInWithApplePlatform.instance = originalApple;
  });

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    googlePlatform.reset();
    applePlatform.reset();
    backendStatus = 200;
    requests = [];
    client = AnythinkClient(
      apiOrigin: Uri.parse('https://api.example.test'),
      projectId: 'native-test-project',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/revoke')) {
          return http.Response('{}', 200);
        }
        return http.Response(
          backendStatus == 200
              ? jsonEncode({
                  'access_token': 'synthetic-access',
                  'refresh_token': 'synthetic-refresh',
                  'expires_in': 3600,
                })
              : '{"message":"rejected"}',
          backendStatus,
          headers: {'content-type': 'application/json'},
        );
      }),
      closeHttpClient: true,
    );
    native = AnythinkNativeAuth(auth: client.auth);
  });

  tearDown(() async {
    await client.close();
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'Google passes SDK token and subject, not email or decoded claims',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final session = await native.signInWithGoogle(
        signupContext: {'invite': 'test-invite'},
      );
      expect(session.accessToken, 'synthetic-access');
      expect(
        requests.single.url.path,
        '/org/native-test-project/auth/v1/native/google',
      );
      expect(jsonDecode(requests.single.body), {
        'identity_token': 'synthetic-google-id-token',
        'user_identifier': 'google-subject',
        'signup_context': {'invite': 'test-invite'},
      });
      expect(requests.single.headers['authorization'], isNull);
      expect(googlePlatform.parameters!.scopeHint, isEmpty);
      expect(googlePlatform.signOutCalls, 0);
    },
  );

  test(
    'Apple sends first-authorization names and no invented nonce field',
    () async {
      await native.signInWithApple();
      expect(
        requests.single.url.path,
        '/org/native-test-project/auth/v1/native/apple',
      );
      expect(jsonDecode(requests.single.body), {
        'identity_token': 'synthetic-apple-id-token',
        'user_identifier': 'apple-subject',
        'given_name': 'Test',
        'family_name': 'Person',
      });
      expect(applePlatform.scopes, [
        apple.AppleIDAuthorizationScopes.email,
        apple.AppleIDAuthorizationScopes.fullName,
      ]);
      // Anythink has no documented raw/hashed nonce exchange field. This test
      // prevents an unsupported protocol from being silently invented.
      expect(applePlatform.nonce, isNull);
      expect(applePlatform.webOptions, isNull);
    },
  );

  test('repeat Apple authorization works without names or email', () async {
    applePlatform.acquire = () async => _appleCredential(names: false);
    await native.signInWithApple();
    expect(jsonDecode(requests.single.body), {
      'identity_token': 'synthetic-apple-id-token',
      'user_identifier': 'apple-subject',
    });
  });

  test('signup context is snapshotted before native UI completes', () async {
    final waiting = Completer<google.AuthenticationResults>();
    googlePlatform.acquire = () => waiting.future;
    final context = {'invite': 'original'};
    final result = native.signInWithGoogle(signupContext: context);
    context['invite'] = 'changed';
    waiting.complete(_googleCredential());
    await result;
    expect(jsonDecode(requests.single.body)['signup_context'], {
      'invite': 'original',
    });
  });

  test('Apple unavailable does not open UI or alter auth', () async {
    applePlatform.available = () async => false;
    final generation = client.auth.generation;
    await expectLater(
      native.signInWithApple(),
      throwsA(_failure(NativeProvider.apple, NativeSignInFailure.unavailable)),
    );
    expect(applePlatform.acquireCalls, 0);
    expect(client.auth.generation, generation);
    expect(requests, isEmpty);
  });

  test('Google unsupported interactive flow is rejected before UI', () async {
    googlePlatform.supported = false;
    await expectLater(
      native.signInWithGoogle(),
      throwsA(_failure(NativeProvider.google, NativeSignInFailure.unavailable)),
    );
    expect(googlePlatform.acquireCalls, 0);
    expect(requests, isEmpty);
  });

  test('unsupported platforms fail without touching plugins', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await expectLater(
      native.signInWithGoogle(),
      throwsA(
        _failure(
          NativeProvider.google,
          NativeSignInFailure.unsupportedPlatform,
        ),
      ),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await expectLater(
      native.signInWithApple(),
      throwsA(
        _failure(NativeProvider.apple, NativeSignInFailure.unsupportedPlatform),
      ),
    );
    expect(googlePlatform.acquireCalls, 0);
    expect(applePlatform.acquireCalls, 0);
    expect(requests, isEmpty);
  });

  test('Google cancellation preserves an existing Anythink session', () async {
    await client.auth.signInWithPassword(
      email: 'test@example.test',
      password: 'test',
    );
    requests.clear();
    final generation = client.auth.generation;
    googlePlatform.acquire = () async => throw const GoogleSignInException(
      code: GoogleSignInExceptionCode.canceled,
      description: 'private provider detail',
      details: 'synthetic-secret',
    );
    await expectLater(
      native.signInWithGoogle(),
      throwsA(_failure(NativeProvider.google, NativeSignInFailure.canceled)),
    );
    expect(client.auth.state.status, AuthStatus.authenticated);
    expect(client.auth.generation, generation);
    expect(requests, isEmpty);
    // A failed acquisition must release the shared guard.
    googlePlatform.acquire = () async => _googleCredential();
    await native.signInWithGoogle();
    expect(requests, hasLength(1));
  });

  test('Apple cancellation is typed and strips provider messages', () async {
    applePlatform.acquire = () async =>
        throw const apple.SignInWithAppleAuthorizationException(
          code: apple.AuthorizationErrorCode.canceled,
          message: 'synthetic-secret',
        );
    try {
      await native.signInWithApple();
      fail('Expected cancellation');
    } on NativeSignInException catch (error) {
      expect(error.failure, NativeSignInFailure.canceled);
      expect(error.toString(), isNot(contains('synthetic-secret')));
    }
    expect(requests, isEmpty);
  });

  for (final entry in {
    GoogleSignInExceptionCode.interrupted: NativeSignInFailure.interrupted,
    GoogleSignInExceptionCode.clientConfigurationError:
        NativeSignInFailure.invalidConfiguration,
    GoogleSignInExceptionCode.providerConfigurationError:
        NativeSignInFailure.invalidConfiguration,
    GoogleSignInExceptionCode.uiUnavailable: NativeSignInFailure.unavailable,
    GoogleSignInExceptionCode.userMismatch: NativeSignInFailure.providerFailure,
    GoogleSignInExceptionCode.unknownError: NativeSignInFailure.providerFailure,
  }.entries) {
    test(
      'Google ${entry.key.name} maps to redacted ${entry.value.name}',
      () async {
        googlePlatform.acquire = () async => throw GoogleSignInException(
          code: entry.key,
          description: 'synthetic-secret',
        );
        await expectLater(
          native.signInWithGoogle(),
          throwsA(_failure(NativeProvider.google, entry.value)),
        );
        expect(requests, isEmpty);
      },
    );
  }

  for (final token in <String?>[null, '', '  ']) {
    test(
      'Google missing or blank token fails before exchange: $token',
      () async {
        googlePlatform.acquire = () async => _googleCredential(token: token);
        await expectLater(
          native.signInWithGoogle(),
          throwsA(
            _failure(
              NativeProvider.google,
              NativeSignInFailure.missingIdentityToken,
            ),
          ),
        );
        expect(requests, isEmpty);
      },
    );
  }

  test(
    'Apple missing token is never replaced with authorization code',
    () async {
      applePlatform.acquire = () async => _appleCredential(token: null);
      await expectLater(
        native.signInWithApple(),
        throwsA(
          _failure(
            NativeProvider.apple,
            NativeSignInFailure.missingIdentityToken,
          ),
        ),
      );
      expect(requests, isEmpty);
    },
  );

  test('Google missing subject is never replaced with email', () async {
    googlePlatform.acquire = () async => _googleCredential(subject: '');
    await expectLater(
      native.signInWithGoogle(),
      throwsA(
        _failure(
          NativeProvider.google,
          NativeSignInFailure.missingUserIdentifier,
        ),
      ),
    );
    expect(requests, isEmpty);
  });

  test(
    'Google Android email fallback is rejected as a missing subject',
    () async {
      googlePlatform.acquire = () async =>
          _googleCredential(subject: 'different-from-subject@example.test');
      await expectLater(
        native.signInWithGoogle(),
        throwsA(
          _failure(
            NativeProvider.google,
            NativeSignInFailure.missingUserIdentifier,
          ),
        ),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'Apple missing subject is never extracted from unverified JWT',
    () async {
      applePlatform.acquire = () async => _appleCredential(subject: null);
      await expectLater(
        native.signInWithApple(),
        throwsA(
          _failure(
            NativeProvider.apple,
            NativeSignInFailure.missingUserIdentifier,
          ),
        ),
      );
      expect(requests, isEmpty);
    },
  );

  test('plugin faults become redacted failures', () async {
    applePlatform.acquire = () async => throw PlatformException(
      code: 'unknown-private-code',
      message: 'synthetic-secret',
      details: {'email': 'private@example.test'},
    );
    await expectLater(
      native.signInWithApple(),
      throwsA(
        _failure(NativeProvider.apple, NativeSignInFailure.providerFailure),
      ),
    );
    expect(requests, isEmpty);
  });

  test('missing plugin is an unavailable failure', () async {
    applePlatform.available = () async =>
        throw MissingPluginException('private detail');
    await expectLater(
      native.signInWithApple(),
      throwsA(_failure(NativeProvider.apple, NativeSignInFailure.unavailable)),
    );
  });

  test('backend rejection retains the core typed error', () async {
    backendStatus = 401;
    await expectLater(
      native.signInWithGoogle(),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
    expect(requests, hasLength(1));
  });

  test(
    'concurrent providers across adapter instances cannot open two UIs',
    () async {
      final waiting = Completer<google.AuthenticationResults>();
      googlePlatform.acquire = () => waiting.future;
      final first = native.signInWithGoogle();
      final other = AnythinkNativeAuth(auth: client.auth);
      await expectLater(
        other.signInWithApple(),
        throwsA(
          _failure(
            NativeProvider.apple,
            NativeSignInFailure.operationInProgress,
          ),
        ),
      );
      expect(applePlatform.acquireCalls, 0);
      waiting.complete(_googleCredential());
      await first;
    },
  );

  test(
    'logout during Google UI discards late credential without exchange',
    () async {
      final waiting = Completer<google.AuthenticationResults>();
      googlePlatform.acquire = () => waiting.future;
      final result = native.signInWithGoogle();
      final rejected = expectLater(
        result,
        throwsA(isA<SessionChangedException>()),
      );
      await client.auth.signOut();
      waiting.complete(_googleCredential());
      await rejected;
      expect(requests, isEmpty);
      expect(client.auth.state.status, AuthStatus.signedOut);
    },
  );

  test('another login during Apple UI wins over late credential', () async {
    final waiting = Completer<apple.AuthorizationCredentialAppleID>();
    final shown = Completer<void>();
    applePlatform.acquire = () {
      shown.complete();
      return waiting.future;
    };
    final result = native.signInWithApple();
    final rejected = expectLater(
      result,
      throwsA(isA<SessionChangedException>()),
    );
    await shown.future;
    await client.auth.signInWithPassword(
      email: 'other@example.test',
      password: 'test',
    );
    waiting.complete(_appleCredential());
    await rejected;
    expect(requests, hasLength(1));
    expect(requests.single.url.path, '/org/native-test-project/auth/v1/token');
    expect(client.auth.state.status, AuthStatus.authenticated);
  });

  test('logout during Apple availability check prevents opening UI', () async {
    final availability = Completer<bool>();
    applePlatform.available = () => availability.future;
    final result = native.signInWithApple();
    final rejected = expectLater(
      result,
      throwsA(isA<SessionChangedException>()),
    );
    await client.auth.signOut();
    availability.complete(true);
    await rejected;
    expect(applePlatform.acquireCalls, 0);
    expect(requests, isEmpty);
  });

  test(
    'closing client while native UI is open rejects its late result',
    () async {
      final waiting = Completer<google.AuthenticationResults>();
      googlePlatform.acquire = () => waiting.future;
      final result = native.signInWithGoogle();
      final rejected = expectLater(
        result,
        throwsA(isA<SessionChangedException>()),
      );
      await client.close();
      waiting.complete(_googleCredential());
      await rejected;
      expect(requests, isEmpty);
    },
  );
}

Matcher _failure(NativeProvider provider, NativeSignInFailure failure) =>
    isA<NativeSignInException>()
        .having((error) => error.provider, 'provider', provider)
        .having((error) => error.failure, 'failure', failure)
        .having(
          (error) => error.toString(),
          'redaction',
          isNot(contains('synthetic-secret')),
        );

google.AuthenticationResults _googleCredential({
  String? token = 'synthetic-google-id-token',
  String subject = 'google-subject',
}) => google.AuthenticationResults(
  user: google.GoogleSignInUserData(
    email: 'different-from-subject@example.test',
    id: subject,
    displayName: 'A Name That Must Not Be Split',
  ),
  authenticationTokens: google.AuthenticationTokenData(idToken: token),
);

apple.AuthorizationCredentialAppleID _appleCredential({
  String? token = 'synthetic-apple-id-token',
  String? subject = 'apple-subject',
  bool names = true,
}) => apple.AuthorizationCredentialAppleID(
  identityToken: token,
  userIdentifier: subject,
  givenName: names ? 'Test' : null,
  familyName: names ? 'Person' : null,
  email: names ? 'private-relay@example.test' : null,
  authorizationCode: 'synthetic-one-use-code-not-for-this-endpoint',
  state: null,
);

final class _GooglePlatform extends Fake
    with MockPlatformInterfaceMixin
    implements google.GoogleSignInPlatform {
  late Future<google.AuthenticationResults> Function() acquire;
  bool supported = true;
  int acquireCalls = 0;
  int signOutCalls = 0;
  google.AuthenticateParameters? parameters;

  void reset() {
    acquire = () async => _googleCredential();
    supported = true;
    acquireCalls = 0;
    signOutCalls = 0;
    parameters = null;
  }

  @override
  Future<void> init(google.InitParameters params) async {}

  @override
  Stream<google.AuthenticationEvent>? get authenticationEvents => null;

  @override
  bool supportsAuthenticate() => supported;

  @override
  Future<google.AuthenticationResults> authenticate(
    google.AuthenticateParameters params,
  ) {
    acquireCalls++;
    parameters = params;
    return acquire();
  }

  @override
  Future<void> signOut(google.SignOutParams params) async {
    signOutCalls++;
  }
}

final class _ApplePlatform extends apple.SignInWithApplePlatform {
  late Future<apple.AuthorizationCredentialAppleID> Function() acquire;
  late Future<bool> Function() available;
  int acquireCalls = 0;
  List<apple.AppleIDAuthorizationScopes>? scopes;
  String? nonce;
  apple.WebAuthenticationOptions? webOptions;

  void reset() {
    acquire = () async => _appleCredential();
    available = () async => true;
    acquireCalls = 0;
    scopes = null;
    nonce = null;
    webOptions = null;
  }

  @override
  Future<bool> isAvailable() => available();

  @override
  Future<apple.AuthorizationCredentialAppleID> getAppleIDCredential({
    required List<apple.AppleIDAuthorizationScopes> scopes,
    apple.WebAuthenticationOptions? webAuthenticationOptions,
    String? nonce,
    String? state,
  }) {
    acquireCalls++;
    this.scopes = scopes;
    this.nonce = nonce;
    webOptions = webAuthenticationOptions;
    return acquire();
  }
}
