import 'dart:convert';
import 'dart:io';

import 'package:anythink_flutter/anythink_flutter.dart';
import 'package:anythink_flutter_auth/anythink_flutter_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  // This manual provider gate deliberately accepts the user's physical tap.
  // The integration binding otherwise drops device-originated Flutter taps.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
          .shouldPropagateDevicePointerEvents =
      true;
  testWidgets(
    'real Google cancellation and ordinary native exchange',
    (tester) async {
      try {
        await _run((phase) async {
          var started = false;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        phase == 'cancel'
                            ? 'Cancellation check: dismiss the Google sheet.'
                            : 'Sign-in check: use only the dedicated test account.',
                      ),
                      ElevatedButton(
                        onPressed: () => started = true,
                        child: const Text('Start Google check'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          _stage('waiting_for_user_start_$phase');
          while (!started) {
            await tester.pump(const Duration(milliseconds: 100));
          }
        });
      } on _GateFailure catch (error) {
        fail('GOOGLE_GATE_FAILED ${error.code}');
      } on ApiException catch (error) {
        // No raw response is printed: server text can contain account data.
        await _writePrivateApiDiagnostic(error);
        fail(
          'GOOGLE_GATE_FAILED api_http_${error.statusCode}_${_providerFailure(error)}',
        );
      } on NativeSignInException catch (error) {
        fail('GOOGLE_GATE_FAILED native_${error.failure.name}');
      } catch (_) {
        fail('GOOGLE_GATE_FAILED unexpected_redacted');
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<void> _run(Future<void> Function(String phase) beforePrompt) async {
  _require(Platform.isAndroid, 'android_required');
  final cache = await getTemporaryDirectory();
  final file = File('${cache.path}/anythink-google-input.json');
  _require(await file.exists(), 'runtime_input_missing');
  final bytes = await file.readAsBytes();
  await file.delete();
  final input = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  bytes.fillRange(0, bytes.length, 0);
  _require(input['expected_user_id'] == 1548, 'ordinary_user_required');
  final phase = input['phase'] as String;
  _require(phase == 'cancel' || phase == 'exchange', 'known_phase_required');
  final store = SecureSessionStore(
    apiOrigin: Uri.parse('https://api.uk01-lon.anythink.cloud'),
    projectId: '19006800',
  );
  _require(await store.read() == null, 'preexisting_session');
  final guard = TestIdentityGuard(input['expected_email'] as String);
  final client = AnythinkClient(
    apiOrigin: Uri.parse('https://api.uk01-lon.anythink.cloud'),
    projectId: '19006800',
    sessionStore: store,
    httpClient: guard,
  );
  final native = AnythinkNativeAuth(auth: client.auth);
  final google = GoogleSignIn.instance;
  var providerInitialized = false;
  try {
    await google.initialize(
      serverClientId: input['server_client_id'] as String,
    );
    providerInitialized = true;
    await google.signOut();
    await beforePrompt(phase);
    if (phase == 'cancel') {
      _stage('cancel_native_chooser');
      var canceled = false;
      try {
        await native.signInWithGoogle();
      } on NativeSignInException catch (error) {
        if (error.failure != NativeSignInFailure.canceled) rethrow;
        canceled = true;
      }
      _require(canceled, 'native_cancel_required');
      _require(guard.forwarded == 0, 'cancel_phase_sent_exchange');
      _require(client.auth.currentSession == null, 'cancel_created_session');
      _require(await store.read() == null, 'cancel_persisted_session');
      _pass('real_native_cancel_preserves_signed_out_state');
      return;
    }
    guard.allowExchange = true;
    _stage('select_only_dedicated_google_test_account');
    await native.signInWithGoogle();
    _require(guard.forwarded == 1, 'single_native_exchange_required');
    _require(guard.blocked == 0, 'wrong_identity_was_selected');
    final user = await client.auth.getUser();
    _require(user.id == input['expected_user_id'], 'unexpected_backend_user');
    _require(user.email == input['expected_email'], 'unexpected_backend_email');
    _require(!await client.auth.isAdmin(), 'administrator_forbidden');
    _require(await client.auth.hasRole('App User'), 'ordinary_role_required');
    _require(
      !await client.auth.hasRole('Standard User'),
      'privileged_role_forbidden',
    );
    _pass('native_google_token_verified_as_ordinary_backend_user');
    _require(await store.read() != null, 'native_session_not_persisted');
    _pass('native_google_session_in_real_secure_store');
    final previous = client.auth.currentSession!;
    final next = await client.auth.refreshSession();
    _require(
      next.refreshToken != previous.refreshToken,
      'native_session_not_rotated',
    );
    _require(
      (await client.auth.getUser()).id == user.id,
      'rotated_identity_mismatch',
    );
    _pass('native_google_session_refresh_and_identity');
    final logout = await client.auth.signOut();
    _require(logout.remoteError == null, 'logout_revoke_unconfirmed');
    _require(await store.read() == null, 'logout_storage_retained');
    _pass('native_google_logout_and_secure_store_clear');
  } finally {
    var cleanupFailed = false;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        cleanupFailed = true;
      }
    }

    await attempt(() async {
      final rotationUncertain =
          client.auth.state.status == AuthStatus.reauthenticationRequired;
      final result = await client.auth.signOut();
      _require(await store.read() == null, 'cleanup_storage_retained');
      _require(result.remoteError == null, 'cleanup_logout_unconfirmed');
      _require(!rotationUncertain, 'cleanup_remote_rotation_uncertain');
    });
    await attempt(client.close);
    guard.close();
    if (providerInitialized) await attempt(google.signOut);
    input.clear();
    _require(!cleanupFailed, 'cleanup_unconfirmed');
  }
}

/// Test-only outbound safety guard, never an authentication mechanism. The
/// token payload is read solely to refuse unintended accounts BEFORE sending.
/// The backend remains responsible for signature/audience/subject verification.
final class TestIdentityGuard extends http.BaseClient {
  TestIdentityGuard(this.expectedEmail);
  final String expectedEmail;
  final _inner = http.Client();
  bool allowExchange = false;
  int forwarded = 0;
  int blocked = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/auth/v1/native/google')) {
      try {
        if (!allowExchange || request is! http.Request) {
          throw const FormatException();
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final token = body['identity_token'] as String;
        final parts = token.split('.');
        if (parts.length != 3) throw const FormatException();
        final claims =
            jsonDecode(
                  utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
                )
                as Map<String, dynamic>;
        if (claims['email'] != expectedEmail) throw const FormatException();
      } catch (_) {
        blocked++;
        throw const _GateFailure('unintended_google_exchange_blocked_locally');
      }
      forwarded++;
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

void _require(bool condition, String code) {
  if (!condition) throw _GateFailure(code);
}

void _pass(String gate) {
  // ignore: avoid_print
  print('GOOGLE_GATE_PASS $gate');
}

void _stage(String stage) {
  // ignore: avoid_print
  print('GOOGLE_STAGE $stage');
}

final class _GateFailure implements Exception {
  const _GateFailure(this.code);
  final String code;
}

String _providerFailure(ApiException error) {
  final message = error.serverMessage?.toLowerCase() ?? '';
  if (message.contains('not configured')) return 'provider_not_configured';
  if (message.contains('native sign-in not supported')) return 'unsupported';
  if (message.contains('audience not allowed')) return 'audience';
  if (message.contains('subject mismatch')) return 'subject';
  if (message.contains('token expired')) return 'expired';
  if (message.contains('no email returned')) return 'missing_email';
  if (message.contains('user account is not active')) return 'inactive_user';
  if (message.contains('does not have a default role')) return 'default_role';
  return 'unclassified';
}

Future<void> _writePrivateApiDiagnostic(ApiException error) async {
  String redact(String value) => value
      .replaceAll(RegExp(r'Bearer\s+\S+', caseSensitive: false), '[credential]')
      .replaceAll(
        RegExp(r'[A-Za-z0-9.!#$%&\x27*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+'),
        '[email]',
      )
      .replaceAll(RegExp(r'[A-Za-z0-9_./+=-]{24,}'), '[opaque identifier]');
  final cache = await getTemporaryDirectory();
  await File('${cache.path}/anythink-google-error.json').writeAsString(
    jsonEncode({
      'status': error.statusCode,
      'classification': _providerFailure(error),
      'message': redact(error.serverMessage ?? ''),
      'fields': {
        for (final entry in error.fieldErrors.entries)
          redact(entry.key): entry.value.map(redact).toList(),
      },
    }),
    flush: true,
  );
}
