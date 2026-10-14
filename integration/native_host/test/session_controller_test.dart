import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_native_host/configuration.dart';
import 'package:anythink_native_host/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _LocalApi api;
  late _FailingStore store;
  late AnythinkClient client;
  late SessionController controller;

  setUp(() async {
    api = await _LocalApi.start();
    store = _FailingStore()..value = _savedSession(api.origin);
    client = AnythinkClient(
      apiOrigin: api.origin,
      projectId: 'controller-test',
      sessionStore: store,
      allowInsecureLocalhost: true,
      // Flutter's test binding normally substitutes a canned HTTP 400. This
      // client uses actual sockets, and every request targets this local server.
      httpClient: IOClient(_RealHttpOverrides().createHttpClient(null)),
      closeHttpClient: true,
    );
    controller = SessionController(
      NativeHostConfiguration(
        apiOrigin: api.origin.toString(),
        projectId: 'controller-test',
      ),
      client: client,
      sessionStore: store,
    );
  });

  tearDown(() async {
    controller.dispose();
    await client.close();
    await api.close();
  });

  test(
    'construction checks saved-session availability without restoring or networking',
    () async {
      store.value = _savedSession(api.origin);
      await Future<void>.delayed(Duration.zero);

      expect(controller.hasSavedSession, isTrue);
      expect(controller.configured, isTrue);
      expect(controller.validApiOrigin, api.origin.toString());
      expect(controller.signedIn, isFalse);
      expect(controller.user, isNull);
      expect(client.auth.currentSession, isNull);
      expect(store.reads, 1);
      expect(store.writes, 0);
      expect(store.clears, 0);
      expect(store.value, isNotNull);
      expect(api.requests, isEmpty);
    },
  );

  test(
    'uncertain rotation exposes sign-in despite retained credentials',
    () async {
      await controller.signIn('ordinary@example.test', 'synthetic-password');
      expect(controller.signedIn, isTrue);
      expect(controller.user?.id, 7);
      api.refreshStatus = HttpStatus.serviceUnavailable;

      await expectLater(
        client.auth.refreshSession(),
        throwsA(isA<ApiException>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.auth.currentSession, isNotNull);
      expect(client.auth.state.status, AuthStatus.reauthenticationRequired);
      expect(controller.signedIn, isFalse);
      expect(controller.statusLabel, 'Sign in again');
      expect(controller.hasSavedSession, isFalse);
      expect(jsonDecode(store.value!)['rotation_pending'], isTrue);
      expect(api.count('/auth/v1/refresh'), 1);

      // A UI recovery attempt must not replay the uncertain refresh token.
      await controller.refreshAccount();
      expect(controller.isError, isTrue);
      expect(controller.signedIn, isFalse);
      expect(api.count('/auth/v1/refresh'), 1);
      expect(api.count('/users/me'), 1);
    },
  );

  test(
    'failed local sign-out recovers through clearing or a fresh sign-in',
    () async {
      await controller.signIn('ordinary@example.test', 'synthetic-password');
      final persisted = store.value;
      expect(persisted, isNotNull);
      store.failClear = true;
      api.logoutStatus = HttpStatus.serviceUnavailable;

      await controller.signOut();
      await Future<void>.delayed(Duration.zero);

      expect(client.auth.currentSession, isNull);
      expect(controller.user, isNull);
      expect(controller.signedIn, isFalse);
      expect(controller.needsSignOutRetry, isTrue);
      expect(controller.hasSavedSession, isFalse);
      expect(controller.isError, isTrue);
      expect(controller.message, contains('Sign-out is incomplete'));
      expect(controller.message, contains('clear the saved session'));
      expect(store.value, persisted);
      expect(api.count('/auth/v1/logout'), 1);

      store.failClear = false;
      await controller.signOut();
      await Future<void>.delayed(Duration.zero);

      expect(store.value, isNull);
      expect(controller.hasSavedSession, isFalse);
      expect(controller.needsSignOutRetry, isFalse);
      expect(controller.isError, isFalse);
      expect(controller.message, contains('on this device'));
      expect(api.count('/auth/v1/logout'), 1);

      // A new sign-in also durably replaces the old session. Its successful
      // recovery must not carry a stale sign-out warning into later operations.
      await controller.signIn('ordinary@example.test', 'synthetic-password');
      store.failClear = true;
      await controller.signOut();
      expect(controller.needsSignOutRetry, isTrue);
      expect(controller.hasSavedSession, isFalse);
      expect(store.value, isNotNull);

      store.failClear = false;
      await controller.signIn('ordinary@example.test', 'synthetic-password');
      await Future<void>.delayed(Duration.zero);

      expect(controller.needsSignOutRetry, isFalse);
      expect(controller.isError, isFalse);
      expect(controller.message, isNull);
      expect(controller.signedIn, isTrue);
      expect(controller.user?.id, 7);
      expect(store.value, isNotNull);
      expect(api.count('/auth/v1/token'), 3);
      expect(api.count('/auth/v1/logout'), 2);
    },
  );

  SessionController withStore(_FailingStore localStore) {
    final localClient = AnythinkClient(
      apiOrigin: api.origin,
      projectId: 'controller-test',
      sessionStore: localStore,
      allowInsecureLocalhost: true,
      httpClient: IOClient(_RealHttpOverrides().createHttpClient(null)),
      closeHttpClient: true,
    );
    final result = SessionController(
      NativeHostConfiguration(
        apiOrigin: api.origin.toString(),
        projectId: 'controller-test',
      ),
      client: localClient,
      sessionStore: localStore,
    );
    addTearDown(result.dispose);
    return result;
  }

  test('empty and unreadable storage never offer restore', () async {
    final empty = withStore(_FailingStore());
    final unreadable = withStore(_FailingStore()..failRead = true);
    expect(empty.hasSavedSession, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(empty.hasSavedSession, isFalse);
    expect(unreadable.hasSavedSession, isFalse);
    expect(api.requests, isEmpty);
  });

  test('a late storage read cannot bring back a signed-out session', () async {
    final pending = Completer<String?>();
    final delayedStore = _FailingStore()..readResult = pending.future;
    final delayed = withStore(delayedStore);
    await delayed.signOut();
    pending.complete(_savedSession(api.origin));
    await Future<void>.delayed(Duration.zero);
    expect(delayed.hasSavedSession, isFalse);
    expect(delayed.signedIn, isFalse);
    expect(api.requests, isEmpty);
  });

  test('restore hides the action if storage was cleared meanwhile', () async {
    await Future<void>.delayed(Duration.zero);
    expect(controller.hasSavedSession, isTrue);
    store.value = null;
    await controller.restore();
    expect(controller.hasSavedSession, isFalse);
    expect(controller.signedIn, isFalse);
    expect(api.requests, isEmpty);
  });
  test('clearing an unrestored session claims only local sign-out', () async {
    store.value = _savedSession(api.origin);

    await controller.signOut();
    await Future<void>.delayed(Duration.zero);

    expect(store.value, isNull);
    expect(controller.hasSavedSession, isFalse);
    expect(store.reads, 1);
    expect(store.clears, 1);
    expect(api.requests, isEmpty);
    expect(controller.signedIn, isFalse);
    expect(controller.needsSignOutRetry, isFalse);
    expect(controller.isError, isFalse);
    expect(controller.message, contains('on this device'));
  });
}

String _savedSession(Uri origin) => jsonEncode({
  'version': 1,
  'api_origin': origin.toString(),
  'project_id': 'controller-test',
  'rotation_pending': false,
  'session': {
    'access_token': 'synthetic-access',
    'refresh_token': 'synthetic-refresh',
    'expires_at': DateTime.now()
        .toUtc()
        .add(const Duration(hours: 1))
        .toIso8601String(),
  },
});

final class _FailingStore implements SessionStore {
  String? value;
  bool failClear = false;
  bool failRead = false;
  Future<String?>? readResult;
  int reads = 0;
  int writes = 0;
  int clears = 0;

  @override
  Future<String?> read() async {
    reads++;
    if (failRead) throw StateError('Synthetic read failure');
    return readResult ?? value;
  }

  @override
  Future<void> write(String value) async {
    writes++;
    this.value = value;
  }

  @override
  Future<void> clear() async {
    clears++;
    if (failClear) throw StateError('Synthetic secure-store failure');
    value = null;
  }
}

final class _RealHttpOverrides extends HttpOverrides {}

final class _LocalApi {
  _LocalApi(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;
  final requests = <String>[];
  int refreshStatus = HttpStatus.ok;
  int logoutStatus = HttpStatus.noContent;

  static Future<_LocalApi> start() async =>
      _LocalApi(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');
  int count(String suffix) =>
      requests.where((path) => path.endsWith(suffix)).length;

  Future<void> _handle(HttpRequest request) async {
    requests.add(request.uri.path);
    await request.drain<void>();
    final path = request.uri.path;
    Object? body;
    if (request.method == 'POST' && path.endsWith('/auth/v1/token')) {
      body = {
        'access_token': 'synthetic-access',
        'refresh_token': 'synthetic-refresh',
        'expires_in': 3600,
      };
    } else if (request.method == 'GET' && path.endsWith('/users/me')) {
      body = {
        'id': 7,
        'gid': 'synthetic-user',
        'email': 'ordinary@example.test',
        'first_name': 'Test',
        'last_name': 'User',
      };
    } else if (request.method == 'POST' && path.endsWith('/auth/v1/refresh')) {
      request.response.statusCode = refreshStatus;
      body = {'error': 'synthetic_rotation_response_lost'};
    } else if (request.method == 'POST' && path.endsWith('/auth/v1/logout')) {
      request.response.statusCode = logoutStatus;
      if (logoutStatus != HttpStatus.noContent) {
        body = {'error': 'synthetic_revocation_unavailable'};
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      body = {'error': 'unexpected_test_route'};
    }
    if (body != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(body));
    }
    await request.response.close();
  }

  Future<void> close() async => _server.close(force: true);
}
