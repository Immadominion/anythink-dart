import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_flutter/anythink_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

// Test-only loopback transport and synthetic credentials. Secure storage and
// process interruption are real. This entrypoint is never a production runtime.
const _project = 'native-resilience-test';
final _storageOrigin = Uri.parse('https://native-resilience.invalid');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native persistence interruption phase',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('Anythink SDK resilience validation')),
          ),
        ),
      );
      try {
        await _runPhase();
      } on _GateFailure catch (error) {
        fail('RESILIENCE_GATE_FAILED ${error.code}');
      } catch (_) {
        fail('RESILIENCE_GATE_FAILED unexpected_redacted');
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _runPhase() async {
  _require(Platform.isAndroid || Platform.isIOS, 'mobile_platform_required');
  final cache = await getTemporaryDirectory();
  final input = File('${cache.path}/anythink-resilience-input.json');
  _require(await input.exists(), 'input_missing');
  final config = jsonDecode(await input.readAsString()) as Map<String, dynamic>;
  await input.delete();
  final marker = File('${cache.path}/anythink-resilience-state.json');
  final store = SecureSessionStore(
    apiOrigin: _storageOrigin,
    projectId: _project,
  );
  switch (config['phase']) {
    case 'interrupt':
      _require(!await marker.exists(), 'preexisting_marker');
      _require(await store.read() == null, 'preexisting_storage');
      await _validateNativeOrderingAndIsolation(store);
      await _beginInterruptedRefresh(store, marker);
    case 'recover':
      _require(await marker.exists(), 'interruption_marker_missing');
      await _recoverInterruptedRefresh(store, marker);
    default:
      throw const _GateFailure('invalid_phase');
  }
}

Future<void> _validateNativeOrderingAndIsolation(
  SecureSessionStore store,
) async {
  final sibling = SecureSessionStore(
    apiOrigin: _storageOrigin,
    projectId: 'native-resilience-sibling',
  );
  _require(await sibling.read() == null, 'preexisting_sibling_storage');
  await sibling.write('synthetic-isolation-marker');
  try {
    final first = store.write('first-synthetic-envelope');
    final second = store.write('second-synthetic-envelope');
    final read = store.read();
    final clear = store.clear();
    await first;
    await second;
    _require(await read == 'second-synthetic-envelope', 'native_queue_order');
    await clear;
    _require(await store.read() == null, 'native_queue_clear');
    _require(
      await sibling.read() == 'synthetic-isolation-marker',
      'namespace_clear_escaped',
    );
  } finally {
    await sibling.clear();
  }
}

Future<void> _beginInterruptedRefresh(
  SecureSessionStore store,
  File marker,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final entered = Completer<void>();
  final neverRespond = Completer<void>();
  var refreshRequests = 0;
  var now = DateTime.utc(2026, 10, 14);
  final handlerErrors = <Object>[];
  server.listen((request) async {
    try {
      await request.drain<void>();
      if (request.uri.path.endsWith('/auth/v1/token')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'access_token': 'synthetic-native-resilience-access',
            'refresh_token': 'synthetic-native-resilience-refresh',
            'expires_in': 3600,
          }),
        );
        await request.response.close();
      } else if (request.uri.path.endsWith('/auth/v1/refresh')) {
        refreshRequests++;
        if (!entered.isCompleted) entered.complete();
        await neverRespond.future;
      } else {
        handlerErrors.add(const _GateFailure('unexpected_request'));
        request.response.statusCode = 404;
        await request.response.close();
      }
    } catch (error) {
      handlerErrors.add(error);
    }
  });
  final origin = Uri.parse('http://127.0.0.1:${server.port}');
  final client = AnythinkClient(
    apiOrigin: origin,
    projectId: _project,
    sessionStore: store,
    clock: () => now,
    requestTimeout: const Duration(minutes: 2),
    allowInsecureLocalhost: true,
  );
  final errors = <Object>[];
  final bridge = AnythinkLifecycleBridge(
    auth: client.auth,
    onError: (error, _) => errors.add(error),
  );
  try {
    await client.auth.signInWithPassword(
      email: 'native-resilience@example.test',
      password: 'synthetic-test-password',
    );
    now = now.add(const Duration(hours: 2));
    bridge.attach();
    for (var index = 0; index < 4; index++) {
      bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
    }
    await entered.future.timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _require(refreshRequests == 1, 'resume_checks_not_coalesced');
    _require(errors.isEmpty && handlerErrors.isEmpty, 'unexpected_error');
    final envelope = jsonDecode((await store.read())!) as Map<String, dynamic>;
    _require(
      envelope['rotation_pending'] == true,
      'pending_marker_not_durable',
    );
    await marker.writeAsString(
      jsonEncode({
        'phase': 'refresh_held',
        'pid': pid,
        'port': server.port,
        'gates': [
          'native_store_order_and_namespace_isolation',
          'lifecycle_resume_checks_coalesced',
          'native_pending_marker_before_interruption',
        ],
      }),
      flush: true,
    );
    // The external official-tool runner kills this app only after the durable
    // marker above. Returning normally would not exercise process interruption.
    await Future<void>.delayed(const Duration(minutes: 2));
    throw const _GateFailure('external_interruption_did_not_occur');
  } finally {
    bridge.dispose();
    await client.close();
    await server.close(force: true);
  }
}

Future<void> _recoverInterruptedRefresh(
  SecureSessionStore store,
  File marker,
) async {
  final previous =
      jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
  _require(previous['phase'] == 'refresh_held', 'invalid_previous_phase');
  _require(previous['pid'] != pid, 'process_not_restarted');
  final port = previous['port'] as int;
  _require(port > 0 && port <= 65535, 'invalid_loopback_port');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  var requests = 0;
  server.listen((request) async {
    requests++;
    await request.drain<void>();
    request.response.statusCode = request.uri.path.endsWith('/auth/v1/logout')
        ? 204
        : 500;
    await request.response.close();
  });
  final client = AnythinkClient(
    apiOrigin: Uri.parse('http://127.0.0.1:$port'),
    projectId: _project,
    sessionStore: store,
    allowInsecureLocalhost: true,
  );
  try {
    final before = await store.read();
    _require(before != null, 'pending_envelope_lost');
    await _requiresUncertain(client.auth.restoreSession);
    _require(
      client.auth.state.status == AuthStatus.reauthenticationRequired,
      'pending_restore_status_wrong',
    );
    await _requiresUncertain(client.auth.refreshIfNeeded);
    await _requiresUncertain(client.auth.getUser);
    _require(requests == 0, 'pending_token_replayed');
    _require(await store.read() == before, 'pending_envelope_changed');
    _pass('pending_rotation_restored_as_uncertain');
    _pass('uncertain_credentials_not_replayed');
    final logout = await client.auth.signOut();
    _require(logout.remoteError == null, 'loopback_logout_failed');
    _require(requests == 1, 'unexpected_logout_requests');
    _require(await store.read() == null, 'uncertain_logout_not_cleared');
    _pass('uncertain_session_explicit_logout_clears_native_store');

    const malformed = '{not-valid-json';
    await store.write(malformed);
    var rejected = false;
    try {
      await client.auth.restoreSession();
    } on ProtocolException {
      rejected = true;
    }
    _require(rejected, 'malformed_envelope_accepted');
    _require(await store.read() == malformed, 'malformed_envelope_deleted');
    _require(requests == 1, 'malformed_envelope_sent_request');
    await client.auth.signOut();
    _require(await store.read() == null, 'malformed_cleanup_failed');
    await marker.delete();
    _pass('corrupt_native_envelope_rejected_without_deletion');
  } finally {
    await client.close();
    await server.close(force: true);
  }
}

Future<void> _requiresUncertain(Future<Object?> Function() action) async {
  try {
    await action();
  } on RefreshUncertainException {
    return;
  }
  throw const _GateFailure('uncertain_operation_accepted');
}

void _require(bool condition, String code) {
  if (!condition) throw _GateFailure(code);
}

void _pass(String gate) {
  // Fixed labels only; no persisted envelope or platform error reaches output.
  // ignore: avoid_print
  print('RESILIENCE_GATE_PASS $gate');
}

final class _GateFailure implements Exception {
  const _GateFailure(this.code);
  final String code;
}
