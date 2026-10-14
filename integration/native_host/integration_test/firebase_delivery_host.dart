import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_flutter/anythink_flutter.dart';
import 'package:anythink_flutter_push/anythink_flutter_push.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

// Real-provider development entrypoint, not the product host. A notification
// must relaunch this entrypoint after process death, so it cannot depend on a
// surviving flutter_test VM connection. Results remain in app-private storage.
final _instructions = ValueNotifier('Preparing native delivery validation…');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Anythink delivery validation')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ValueListenableBuilder(
              valueListenable: _instructions,
              builder: (_, text, _) => Text(text, textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    ),
  );
  final runner = _DeliveryRun();
  await runner.start();
}

final class _DeliveryRun with WidgetsBindingObserver {
  late final File _input;
  late final File _stateFile;
  late final File _resultFile;
  late final FirebaseMessaging _messaging;
  late final AnythinkClient _client;
  late final AnythinkFirebasePush _push;
  StreamSubscription<RemoteMessage>? _opened;
  Timer? _deadline;
  Future<void> _tail = Future.value();
  Map<String, dynamic> _state = {};
  final _gates = <String>{};
  bool _initialized = false;
  bool _finished = false;

  Future<void> start() async {
    try {
      _require(Platform.isAndroid, 'android_required');
      final cache = await getTemporaryDirectory();
      _input = File('${cache.path}/anythink-delivery-input.json');
      _stateFile = File('${cache.path}/anythink-delivery-state.json');
      _resultFile = File('${cache.path}/anythink-delivery-result.json');
      Map<String, dynamic>? input;
      if (await _input.exists()) {
        _require(!await _stateFile.exists(), 'preexisting_delivery_state');
        final bytes = await _input.readAsBytes();
        await _input.delete();
        input = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        bytes.fillRange(0, bytes.length, 0);
        _require(
          input['api_origin'] == 'https://api.uk01-lon.anythink.cloud' &&
              input['project_id'] == '19006800',
          'dedicated_backend_required',
        );
        _state = {
          'phase': 'starting',
          'firebase': input['firebase'],
          'original_pid': pid,
        };
      } else {
        _require(await _stateFile.exists(), 'runtime_input_missing');
        _state =
            jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>;
        _require(
          _state['phase'] == 'terminated_ready',
          'unexpected_restart_phase',
        );
        _require(_state['original_pid'] != pid, 'process_not_restarted');
        _gates.addAll((_state['gates'] as List).cast<String>());
      }
      final config = _state['firebase'] as Map<String, dynamic>;
      _require(
        config['projectId'] == 'aura-the-app',
        'firebase_project_mismatch',
      );
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: config['apiKey'] as String,
          appId: config['appId'] as String,
          messagingSenderId: config['messagingSenderId'] as String,
          projectId: config['projectId'] as String,
        ),
      );
      _messaging = FirebaseMessaging.instance;
      _client = AnythinkClient(
        apiOrigin: Uri.parse('https://api.uk01-lon.anythink.cloud'),
        projectId: '19006800',
      );
      _push = AnythinkFirebasePush(
        client: _client,
        messaging: _messaging,
        metadata: const {
          'purpose': 'sdk-delivery-validation',
          'device': 'Seeker',
        },
        onError: (_, _) => _enqueue(() => _fail('automatic_sync_failed')),
      );
      _initialized = true;
      _deadline = Timer(
        const Duration(minutes: 15),
        () => _enqueue(() => _fail('manual_delivery_timeout')),
      );
      _require(!_messaging.isAutoInitEnabled, 'unexpected_auto_init');
      var permission = await _messaging.getNotificationSettings();
      if (permission.authorizationStatus != AuthorizationStatus.authorized &&
          input != null) {
        _instructions.value = 'Allow notifications for this SDK test app.';
        await _writeResult('awaiting_notification_permission');
        permission = await _push.requestPermission();
      }
      _require(
        permission.authorizationStatus == AuthorizationStatus.authorized,
        'notification_permission_required',
      );
      if (input != null) {
        await _establish(input);
        input.clear();
      } else {
        await _verifyTerminated();
      }
    } catch (error) {
      await _fail(error is _GateFailure ? error.code : 'unexpected_redacted');
    }
  }

  Future<void> _establish(Map<String, dynamic> input) async {
    final token = await _messaging.getToken();
    _require(token != null && token.isNotEmpty, 'native_token_missing');
    _state['token'] = token;
    await _client.auth.signInWithPassword(
      email: input['email'] as String,
      password: input['password'] as String,
    );
    _require(!await _client.auth.isAdmin(), 'administrator_forbidden');
    _require(
      await _client.auth.hasPermission('anythink_tenant_devices:create'),
      'device_create_permission_required',
    );
    final result = await _push.start();
    _require(
      result.status == PushSyncStatus.registered,
      'registration_missing',
    );
    _state['backend_device_id'] = result.registration!.id;
    _gates.add('real_token_and_backend_registration');
    final signOut = await _client.auth.signOut();
    _require(signOut.remoteError == null, 'logout_unconfirmed');
    _require(_client.auth.currentSession == null, 'logout_retained_session');
    _gates.add('backend_session_revoked_before_delivery');
    // Incoming notification routing belongs to the installation. Signing out
    // does not unregister its token; this test payload contains no user data.
    _opened = _push.openedMessages.listen(
      (message) => _enqueue(() => _verifyBackgroundTap(message)),
      onError: (Object _, StackTrace _) =>
          _enqueue(() => _fail('opened_stream_failed')),
    );
    WidgetsBinding.instance.addObserver(this);
    await _setPhase('awaiting_first_home');
    _instructions.value =
        'Press Home once. Then tap the SDK background test notification when it arrives.';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused || _finished) return;
    _enqueue(() async {
      if (_state['phase'] == 'awaiting_first_home') {
        _gates.add('actual_os_background_transition');
        await _setPhase('background_ready');
      } else if (_state['phase'] == 'awaiting_second_home') {
        await _setPhase('terminated_ready');
      }
    });
  }

  Future<void> _verifyBackgroundTap(RemoteMessage message) async {
    if (_finished || _state['phase'] != 'background_ready') return;
    if (!_matches(message, 'Background tap check')) return;
    _require(_state['original_pid'] == pid, 'background_process_changed');
    _gates.add('actual_background_notification_tap_via_adapter');
    await _setPhase('awaiting_second_home');
    _instructions.value =
        'Background tap passed. Press Home again. Then tap the SDK restart test notification when it arrives.';
  }

  Future<void> _verifyTerminated() async {
    final initial = await _push.getInitialMessage();
    _require(
      initial != null && _matches(initial, 'Terminated tap check'),
      'terminated_initial_message_missing',
    );
    _gates.add('actual_terminated_notification_launch');
    _require(
      await _push.getInitialMessage() == null,
      'initial_message_not_consumed_once',
    );
    _gates.add('terminated_initial_message_consumed_once');
    _require(
      _client.auth.currentSession == null,
      'unexpected_session_after_restart',
    );
    await _cleanup();
    _gates.add('test_token_retired_and_private_state_removed');
    _finished = true;
    await _writeResult('complete');
    _instructions.value =
        'Both notification taps passed. The test token and private state have been removed.';
  }

  bool _matches(RemoteMessage message, String body) =>
      message.notification?.title == 'Anythink SDK validation' &&
      message.notification?.body == body;

  void _enqueue(Future<void> Function() operation) {
    _tail = _tail.then((_) => operation()).catchError((Object error) async {
      await _fail(error is _GateFailure ? error.code : 'unexpected_redacted');
    });
  }

  Future<void> _setPhase(String phase) async {
    _state['phase'] = phase;
    _state['gates'] = _gates.toList();
    final temporary = File('${_stateFile.path}.tmp');
    await temporary.writeAsString(jsonEncode(_state), flush: true);
    await temporary.rename(_stateFile.path);
    await _writeResult(phase);
  }

  Future<void> _writeResult(String phase, {String? failure}) async {
    final temporary = File('${_resultFile.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'phase': phase,
        'gates': _gates.toList(),
        'backend_device_id': _state['backend_device_id'],
        'failure': ?failure,
      }),
      flush: true,
    );
    await temporary.rename(_resultFile.path);
  }

  Future<void> _cleanup() async {
    var failed = false;
    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (_) {
        failed = true;
      }
    }

    _deadline?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    await attempt(() async => _opened?.cancel());
    if (_initialized) {
      await attempt(_push.dispose);
      await attempt(() async {
        if (_client.auth.currentSession != null) {
          final result = await _client.auth.signOut();
          _require(result.remoteError == null, 'cleanup_logout_unconfirmed');
        }
      });
      await attempt(_client.close);
      await attempt(_messaging.deleteToken);
    }
    await attempt(() async {
      if (await _stateFile.exists()) await _stateFile.delete();
    });
    await attempt(() async {
      final temporary = File('${_stateFile.path}.tmp');
      if (await temporary.exists()) await temporary.delete();
    });
    await attempt(() async {
      if (await _input.exists()) await _input.delete();
    });
    _require(!failed, 'required_cleanup_unconfirmed');
  }

  Future<void> _fail(String code) async {
    if (_finished) return;
    _finished = true;
    try {
      await _cleanup();
    } catch (_) {
      code = '${code}_cleanup_unconfirmed';
    }
    try {
      await _writeResult('failed', failure: code);
    } catch (_) {
      // A failure to persist is not a passing result. No arbitrary error output.
    }
    _instructions.value =
        'Validation stopped. The operator will inspect the private test status.';
  }
}

void _require(bool condition, String code) {
  if (!condition) throw _GateFailure(code);
}

final class _GateFailure implements Exception {
  const _GateFailure(this.code);
  final String code;
}
