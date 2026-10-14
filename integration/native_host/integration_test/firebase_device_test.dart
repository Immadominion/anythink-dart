import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_flutter/anythink_flutter.dart';
import 'package:anythink_flutter_push/anythink_flutter_push.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// Deliberate, interactive provider validation only. Private input is transferred
// to this debug host's cache once, never included in a build or a test log.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Android Firebase registration and foreground delivery',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Anythink SDK Firebase validation')),
          ),
        ),
      );
      try {
        await _run();
      } on _GateFailure catch (error) {
        fail('FIREBASE_GATE_FAILED ${error.code}');
      } on ApiException catch (error) {
        fail('FIREBASE_GATE_FAILED api_http_${error.statusCode}');
      } on TransportException catch (error) {
        fail('FIREBASE_GATE_FAILED transport_${error.failure.name}');
      } catch (_) {
        fail('FIREBASE_GATE_FAILED unexpected_redacted');
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _run() async {
  _require(Platform.isAndroid, 'android_required');
  final cache = await getTemporaryDirectory();
  final inputFile = File('${cache.path}/anythink-firebase-input.json');
  final readyFile = File('${cache.path}/anythink-firebase-ready.json');
  _require(await inputFile.exists(), 'runtime_input_missing');
  _require(!await readyFile.exists(), 'preexisting_provider_state');
  final bytes = await inputFile.readAsBytes();
  await inputFile.delete();
  final input = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  bytes.fillRange(0, bytes.length, 0);
  _require(
    input['api_origin'] == 'https://api.uk01-lon.anythink.cloud' &&
        input['project_id'] == '19006800',
    'dedicated_backend_required',
  );
  final config = input['firebase'] as Map<String, dynamic>;
  _require(config['projectId'] == 'aura-the-app', 'firebase_project_mismatch');
  await Firebase.initializeApp(
    options: FirebaseOptions(
      apiKey: config['apiKey'] as String,
      appId: config['appId'] as String,
      messagingSenderId: config['messagingSenderId'] as String,
      projectId: config['projectId'] as String,
    ),
  );
  final messaging = FirebaseMessaging.instance;
  final client = AnythinkClient(
    apiOrigin: Uri.parse(input['api_origin'] as String),
    projectId: input['project_id'] as String,
  );
  final automaticErrors = <Object>[];
  final push = AnythinkFirebasePush(
    client: client,
    messaging: messaging,
    metadata: const {'purpose': 'sdk-native-validation', 'device': 'Seeker'},
    onError: (error, _) => automaticErrors.add(error),
  );
  StreamSubscription<RemoteMessage>? subscription;
  var tokenCreated = false;
  try {
    _require(!messaging.isAutoInitEnabled, 'unexpected_auto_init');
    final token = await messaging.getToken().timeout(
      const Duration(seconds: 60),
    );
    _require(token != null && token.isNotEmpty, 'native_token_missing');
    tokenCreated = true;
    _require(await messaging.getToken() == token, 'native_token_not_stable');
    _pass('real_firebase_initialization_and_token');
    _require(
      (await push.start()).status == PushSyncStatus.signedOut,
      'signed_out_registration_not_suppressed',
    );
    _pass('signed_out_sync_suppressed');

    await client.auth.signInWithPassword(
      email: input['email'] as String,
      password: input['password'] as String,
    );
    _require(!await client.auth.isAdmin(), 'administrator_forbidden');
    _require(await client.auth.hasRole('App User'), 'app_user_role_required');
    _require(
      await client.auth.hasPermission('anythink_tenant_devices:create'),
      'device_create_permission_required',
    );
    _require(
      (await client.auth.getUser()).email == input['email'],
      'backend_identity_mismatch',
    );
    _pass('ordinary_backend_identity');
    var settings = await messaging.getNotificationSettings();
    if (settings.authorizationStatus != AuthorizationStatus.authorized) {
      // The user taps the real OS prompt. No test code grants a permission or
      // modifies device settings. Parent orchestrator coordinates that action.
      _pass('awaiting_user_notification_permission');
      settings = await push.requestPermission();
    }
    _require(
      settings.authorizationStatus == AuthorizationStatus.authorized,
      'notification_permission_not_granted',
    );
    final registration = await push.synchronize();
    _require(
      registration.status == PushSyncStatus.registered ||
          registration.status == PushSyncStatus.alreadyRegistered,
      'backend_device_registration_missing',
    );
    _require(registration.registration != null, 'registration_result_missing');
    _pass('real_fcm_token_registered_with_backend');
    _require(
      (await push.synchronize()).status == PushSyncStatus.alreadyRegistered,
      'duplicate_registration_not_coalesced',
    );
    _pass('duplicate_registration_coalesced');

    final received = Completer<void>();
    subscription = push.messages.listen((message) {
      if (message.notification?.title == 'Anythink SDK validation' &&
          message.notification?.body == 'Foreground delivery check') {
        if (!received.isCompleted) received.complete();
      }
    });
    // App-private handoff for the console's single-device test only. The runner
    // copies this privately; neither token nor session can reach console output.
    await readyFile.writeAsString(
      jsonEncode({
        'token': token,
        'stage': 'foreground_ready',
        'backend_device_id': registration.registration!.id,
      }),
      flush: true,
    );
    _pass('awaiting_console_foreground_message');
    await received.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () => throw const _GateFailure('foreground_message_timeout'),
    );
    _pass('real_foreground_message_received_via_adapter');
    _require(automaticErrors.isEmpty, 'automatic_sync_error');
    await push.dispose();
    final signOut = await client.auth.signOut();
    _require(signOut.remoteError == null, 'remote_sign_out_unconfirmed');
    _require(client.auth.currentSession == null, 'sign_out_retained_session');
    _pass('explicit_stop_and_backend_logout');
  } finally {
    await subscription?.cancel();
    await push.dispose();
    if (client.auth.currentSession != null) await client.auth.signOut();
    await client.close();
    if (tokenCreated) {
      try {
        await messaging.deleteToken();
      } catch (_) {
        throw const _GateFailure('test_token_retirement_failed');
      }
    }
    // Firebase's default app cannot be deleted. The process exits with auto
    // initialization still disabled, after retiring this test registration.
    if (await readyFile.exists()) await readyFile.delete();
    input.clear();
  }
  _pass('test_token_retired_and_private_handoff_removed');
}

void _require(bool condition, String code) {
  if (!condition) throw _GateFailure(code);
}

void _pass(String gate) {
  // ignore: avoid_print
  print('FIREBASE_GATE_PASS $gate');
}

final class _GateFailure implements Exception {
  const _GateFailure(this.code);
  final String code;
}
