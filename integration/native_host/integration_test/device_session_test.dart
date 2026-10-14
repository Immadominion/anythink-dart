import 'dart:convert';
import 'dart:io';

import 'package:anythink_flutter/anythink_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'interrupted_session_cleanup.dart';

// This entrypoint is only for deliberate device integration runs. Credentials
// arrive once through this debug application's private cache, never Dart defines.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real device session phase', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Anythink SDK device validation')),
        ),
      ),
    );
    try {
      await _runPhase();
    } on _GateFailure catch (failure) {
      fail('DEVICE_GATE_FAILED ${failure.code}');
    } on ApiException catch (error) {
      fail('DEVICE_GATE_FAILED api_http_${error.statusCode}');
    } on TransportException catch (error) {
      fail('DEVICE_GATE_FAILED transport_${error.failure.name}');
    } on SessionStorageException {
      fail('DEVICE_GATE_FAILED core_storage');
    } on SecureSessionStoreException {
      fail('DEVICE_GATE_FAILED native_storage');
    } catch (_) {
      // Never let framework failure formatting receive a credential, response
      // body, session envelope, plugin message, or arbitrary exception string.
      fail('DEVICE_GATE_FAILED unexpected_redacted');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _runPhase() async {
  _require(Platform.isAndroid || Platform.isIOS, 'mobile_platform_required');
  final rootCache = await getTemporaryDirectory();
  const inputSubdirectory = String.fromEnvironment(
    'ANYTHINK_DEVICE_INPUT_SUBDIRECTORY',
  );
  _require(
    inputSubdirectory.isEmpty ||
        inputSubdirectory == 'anythink-physical-session',
    'invalid_input_subdirectory',
  );
  final cache = inputSubdirectory.isEmpty
      ? rootCache
      : Directory('${rootCache.path}/$inputSubdirectory');
  final inputFile = File('${cache.path}/anythink-device-input.json');
  _require(await inputFile.exists(), 'runtime_input_missing');
  final inputBytes = await inputFile.readAsBytes();
  await inputFile.delete();
  _require(!await inputFile.exists(), 'runtime_input_not_deleted');
  final input = jsonDecode(utf8.decode(inputBytes)) as Map<String, dynamic>;
  inputBytes.fillRange(0, inputBytes.length, 0);
  final phase = input['phase'] as String;
  final origin = Uri.parse(input['api_origin'] as String);
  final project = input['project_id'] as String;
  _require(
    origin.toString() == 'https://api.uk01-lon.anythink.cloud' &&
        project == '19006800',
    'dedicated_project_required',
  );
  final store = SecureSessionStore(apiOrigin: origin, projectId: project);
  final client = AnythinkClient(
    apiOrigin: origin,
    projectId: project,
    sessionStore: store,
  );
  final marker = File('${cache.path}/anythink-device-state.json');
  try {
    switch (phase) {
      case 'cleanup_interrupted_run':
        // Recovery is separate from the seven validation gates. It never
        // reconstructs a deleted restart marker or certifies persistence.
        final cleanup = await cleanupInterruptedSession(
          client,
          store,
          expectedEmail: input['email'] as String,
        );
        _require(cleanup.localCleared, 'cleanup_storage_retained');
        _require(!cleanup.rotationUncertain, 'cleanup_rotation_uncertain');
        _require(cleanup.identityConfirmed, 'cleanup_identity_unconfirmed');
        _require(cleanup.remoteRevoked, 'cleanup_remote_revoke_unconfirmed');
        _pass('interrupted_run_cleanup');
      case 'establish':
        _require(await store.read() == null, 'preexisting_session');
        _require(!await marker.exists(), 'preexisting_test_state');
        await client.auth.signInWithPassword(
          email: input['email'] as String,
          password: input['password'] as String,
        );
        final user = await client.auth.getUser();
        _require(user.email == input['email'], 'identity_mismatch');
        _require(!await client.auth.isAdmin(), 'administrator_forbidden');
        _require(
          await client.auth.hasRole('App User'),
          'required_role_missing',
        );
        _require(
          !await client.auth.hasRole('Standard User'),
          'privileged_role_forbidden',
        );
        _require(await store.read() != null, 'secure_session_missing');
        // IDs and process markers are private test metadata, not token copies.
        await marker.writeAsString(
          jsonEncode({'user_id': user.id, 'phase': 'established', 'pid': pid}),
          flush: true,
        );
        _pass('password_sign_in');
        _pass('server_identity_and_role');
        _pass('native_secure_persistence');
      case 'restore_refresh_logout':
        _require(await marker.exists(), 'restart_marker_missing');
        final previous =
            jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
        _require(previous['phase'] == 'established', 'wrong_previous_phase');
        _require(previous['pid'] != pid, 'process_did_not_restart');
        _require(client.auth.currentSession == null, 'implicit_restore');
        _require(await store.read() != null, 'persistence_lost_on_restart');
        await client.auth.restoreSession();
        final before = client.auth.currentSession;
        _require(before != null, 'restore_missing_session');
        _require(
          client.auth.state.user?.id == previous['user_id'],
          'restored_identity_mismatch',
        );
        _pass('restore_after_process_restart');
        final refreshed = await client.auth.refreshSession();
        _require(
          refreshed.refreshToken != before!.refreshToken,
          'refresh_pair_did_not_rotate',
        );
        _require(await store.read() != null, 'rotated_session_not_saved');
        final user = await client.auth.getUser();
        _require(user.id == previous['user_id'], 'refresh_identity_mismatch');
        _pass('real_refresh_rotation_and_identity');
        final signOut = await client.auth.signOut();
        _require(client.auth.currentSession == null, 'logout_session_retained');
        _require(await store.read() == null, 'logout_storage_retained');
        _require(signOut.remoteError == null, 'remote_revoke_unconfirmed');
        _require(signOut.remoteRevoked, 'remote_revoke_not_performed');
        await marker.writeAsString(
          jsonEncode({'phase': 'logged_out', 'pid': pid}),
          flush: true,
        );
        _pass('local_logout_and_revoke_response');
      case 'verify_cleared':
        _require(await marker.exists(), 'logout_marker_missing');
        final previous =
            jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
        _require(previous['phase'] == 'logged_out', 'wrong_previous_phase');
        _require(previous['pid'] != pid, 'process_did_not_restart');
        _require(await store.read() == null, 'logout_not_durable');
        await client.auth.restoreSession();
        _require(client.auth.currentSession == null, 'logout_session_restored');
        _require(client.auth.state.user == null, 'logout_identity_restored');
        _require(
          client.auth.state.status == AuthStatus.signedOut,
          'logout_status_wrong',
        );
        await marker.delete();
        _pass('logout_durable_after_process_restart');
      default:
        throw const _GateFailure('invalid_phase');
    }
  } finally {
    // Closing preserves the session between phases; explicit sign-out is the
    // behavior under test. A failed phase is not silently turned into a pass.
    input.clear();
    await client.close();
  }
}

void _require(bool condition, String code) {
  if (!condition) throw _GateFailure(code);
}

void _pass(String gate) {
  // Only fixed gate labels reach the test runner; never identity or tokens.
  // ignore: avoid_print
  print('DEVICE_GATE_PASS $gate');
}

final class _GateFailure implements Exception {
  const _GateFailure(this.code);
  final String code;
  @override
  String toString() => 'DeviceGateFailure($code)';
}
