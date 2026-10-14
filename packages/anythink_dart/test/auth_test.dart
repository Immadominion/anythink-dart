import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:test/test.dart';

import 'auth_transport_support/file_session_store.dart';
import 'auth_transport_support/local_api.dart';

void main() {
  late LocalApi api;
  late Directory temporary;
  late FileSessionStore disk;
  late AnythinkClient client;
  late List<AnythinkClient> clients;
  late DateTime now;

  AnythinkClient createClient({
    SessionStore? store,
    Duration timeout = const Duration(seconds: 5),
  }) {
    final value = AnythinkClient(
      apiOrigin: api.origin,
      projectId: 'auth-tests',
      sessionStore: store ?? disk,
      clock: () => now,
      requestTimeout: timeout,
      allowInsecureLocalhost: true,
    );
    clients.add(value);
    return value;
  }

  Future<Session> signIn([AnythinkClient? target, String account = 'a']) =>
      (target ?? client).auth.signInWithPassword(
        email: '$account@example.test',
        password: 'synthetic-test-password',
      );

  setUp(() async {
    api = await LocalApi.start();
    temporary = await Directory.systemTemp.createTemp('anythink-auth-test-');
    disk = FileSessionStore(File('${temporary.path}/session.json'));
    clients = [];
    now = DateTime.utc(2026, 10, 14, 12);
    api.handle = (request) {
      if (request.uri.path.endsWith('/token')) {
        final body = request.body! as Map<String, Object?>;
        final account = (body['email']! as String).startsWith('b@') ? 'b' : 'a';
        return WireReply.json(_tokens(account));
      }
      if (request.uri.path.endsWith('/refresh')) {
        return WireReply.json(_tokens('renewed'));
      }
      if (request.uri.path.endsWith('/logout')) return WireReply.empty();
      if (request.uri.path.endsWith('/users/me')) {
        return WireReply.json(
          _user(request.authorization == 'Bearer access-b' ? 2 : 1),
        );
      }
      return WireReply.json({'id': 1, 'reference': 'record'});
    };
    client = createClient();
  });

  tearDown(() async {
    for (final value in clients) {
      await value.close();
    }
    await api.close();
    await temporary.delete(recursive: true);
    expect(api.handlerErrors, isEmpty);
  });

  test(
    'password sign-in persists a scoped envelope and restores real identity',
    () async {
      final session = await signIn();
      expect(session.accessToken, 'access-a');
      expect(session.expiresAt, now.add(const Duration(hours: 1)));
      expect(client.auth.state.status, AuthStatus.authenticated);
      expect(client.auth.state.user, isNull);
      final envelope = jsonDecode((await disk.read())!) as Map<String, Object?>;
      expect(envelope['version'], 1);
      expect(envelope['api_origin'], api.origin.toString());
      expect(envelope['project_id'], 'auth-tests');
      expect(envelope['rotation_pending'], isFalse);
      expect(api.at('/token').single.authorization, isNull);
      expect(api.at('/token').single.body, {
        'email': 'a@example.test',
        'password': 'synthetic-test-password',
      });

      await client.close();
      final restored = createClient();
      await restored.auth.restoreSession();
      expect(restored.auth.currentSession?.accessToken, 'access-a');
      expect(restored.auth.state.user?.id, 1);
      expect(api.at('/refresh'), isEmpty);
      expect(api.at('/users/me').single.authorization, 'Bearer access-a');
      expect(session.toString(), isNot(contains('access-a')));
      expect(restored.auth.state.toString(), isNot(contains('example.test')));
    },
  );

  test(
    'expired persisted session rotates once before loading identity',
    () async {
      await signIn();
      now = now.add(const Duration(hours: 2));
      await client.close();
      final restored = createClient();
      await restored.auth.restoreSession();
      expect(api.at('/refresh').length, 1);
      expect(api.at('/refresh').single.body, {'token': 'refresh-a'});
      expect(api.at('/users/me').single.authorization, 'Bearer access-renewed');
      expect(
        restored.auth.currentSession?.expiresAt,
        now.add(const Duration(hours: 1)),
      );
      expect(restored.auth.state.user?.id, 1);
    },
  );

  test(
    'concurrent refresh callers share one rotation and durable renewed pair',
    () async {
      await signIn();
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/refresh')
          ? release.future
          : original(request);
      final pending = List.generate(12, (_) => client.auth.refreshSession());
      await api.waitFor('/refresh');
      expect(api.at('/refresh').length, 1);
      final marker = jsonDecode((await disk.read())!) as Map<String, Object?>;
      expect(marker['rotation_pending'], isTrue);
      expect(api.at('/refresh').single.body, {'token': 'refresh-a'});
      expect(api.at('/refresh').single.authorization, isNull);
      release.complete(WireReply.json(_tokens('renewed')));
      final results = await Future.wait(pending);
      expect(
        results.every((session) => session.accessToken == 'access-renewed'),
        isTrue,
      );
      expect(api.at('/refresh').length, 1);
      final persisted =
          jsonDecode((await disk.read())!) as Map<String, Object?>;
      expect(persisted['rotation_pending'], isFalse);
      expect(
        (persisted['session']! as Map<String, Object?>)['refresh_token'],
        'refresh-renewed',
      );
    },
  );

  test('late 401 for an old access token reuses the renewed session', () async {
    await signIn();
    final late = Completer<WireReply>();
    final original = api.handle;
    api.handle = (request) {
      if (request.uri.path.contains('/entities/')) {
        if (request.authorization == 'Bearer access-a') {
          if (request.uri.path.endsWith('/1')) return late.future;
          return WireReply.json({'error': 'expired'}, status: 401);
        }
        return WireReply.json({'id': 1});
      }
      return original(request);
    };
    final first = client.records('notes').get(1);
    await api.waitFor('/items/1');
    await client.records('notes').get(2);
    expect(api.at('/refresh').length, 1);
    late.complete(WireReply.json({'error': 'expired'}, status: 401));
    await first;
    expect(api.at('/refresh').length, 1);
    expect(api.at('/items/1').last.authorization, 'Bearer access-renewed');
  });

  test(
    'logout during refresh cannot resurrect session and revokes late pair',
    () async {
      await signIn();
      await client.auth.getUser();
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/refresh')
          ? release.future
          : original(request);
      final pending = client.auth.refreshSession();
      final rejected = expectLater(
        pending,
        throwsA(isA<SessionChangedException>()),
      );
      await api.waitFor('/refresh');
      final result = await client.auth.signOut();
      expect(result.remoteRevoked, isTrue);
      release.complete(WireReply.json(_tokens('late')));
      await rejected;
      expect(client.auth.currentSession, isNull);
      expect(client.auth.state.status, AuthStatus.signedOut);
      expect(client.auth.state.user, isNull);
      expect(await disk.read(), isNull);
      expect(api.at('/logout').map((request) => request.body), [
        {'token': 'refresh-a'},
        {'token': 'refresh-late'},
      ]);
    },
  );

  test(
    'account replacement fences old refresh and old profile responses',
    () async {
      await signIn();
      final refreshRelease = Completer<WireReply>();
      final userRelease = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) {
        if (request.uri.path.endsWith('/refresh')) return refreshRelease.future;
        if (request.uri.path.endsWith('/users/me') &&
            request.authorization == 'Bearer access-a') {
          return userRelease.future;
        }
        return original(request);
      };
      final oldUser = client.auth.getUser();
      final userRejected = expectLater(
        oldUser,
        throwsA(isA<SessionChangedException>()),
      );
      await api.waitFor('/users/me');
      final oldRefresh = client.auth.refreshSession();
      final refreshRejected = expectLater(
        oldRefresh,
        throwsA(isA<SessionChangedException>()),
      );
      await api.waitFor('/refresh');
      await signIn(client, 'b');
      await client.auth.getUser();
      userRelease.complete(WireReply.json(_user(1)));
      refreshRelease.complete(WireReply.json(_tokens('late-a')));
      await Future.wait([userRejected, refreshRejected]);
      expect(client.auth.currentSession?.accessToken, 'access-b');
      expect(client.auth.state.user?.id, 2);
      final stored = jsonDecode((await disk.read())!) as Map<String, Object?>;
      expect(
        (stored['session']! as Map<String, Object?>)['access_token'],
        'access-b',
      );
      expect(api.at('/logout').single.body, {'token': 'refresh-late-a'});
    },
  );

  test(
    'late profile mutation response cannot overwrite a replacement identity',
    () async {
      await signIn();
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) =>
          request.method == 'PUT' && request.uri.path.endsWith('/users/me')
          ? release.future
          : original(request);
      final pending = client.auth.updateProfile(
        firstName: 'Old',
        lastName: 'Account',
      );
      final rejected = expectLater(
        pending,
        throwsA(isA<SessionChangedException>()),
      );
      await api.waitFor('/users/me');
      await signIn(client, 'b');
      await client.auth.getUser();
      release.complete(WireReply.empty());
      await rejected;
      expect(client.auth.state.status, AuthStatus.authenticated);
      expect(client.auth.state.user?.id, 2);
    },
  );

  test(
    'failed account replacement clears previous visible and durable identity',
    () async {
      await signIn();
      await client.auth.getUser();
      api.handle = (_) =>
          WireReply.json({'error': 'invalid_credentials'}, status: 401);
      await expectLater(signIn(client, 'b'), throwsA(isA<ApiException>()));
      expect(client.auth.currentSession, isNull);
      expect(client.auth.state.status, AuthStatus.signedOut);
      expect(client.auth.state.user, isNull);
      expect(await disk.read(), isNull);
    },
  );

  test(
    'failed profile read clears previous identity with a typed error',
    () async {
      await signIn();
      await client.auth.getUser();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/users/me')
          ? WireReply.json({..._user(1), 'email': 42})
          : original(request);
      await expectLater(
        client.auth.getUser(),
        throwsA(isA<ProtocolException>()),
      );
      expect(client.auth.state.user, isNull);
      expect(client.auth.state.status, AuthStatus.temporarilyUnavailable);
      expect(client.auth.currentSession?.accessToken, 'access-a');
    },
  );

  test(
    'failed persistence after rotation never replays the old token',
    () async {
      final fault = FaultSessionStore(disk);
      final subject = createClient(store: fault);
      await signIn(subject);
      final original = api.handle;
      api.handle = (request) {
        if (request.uri.path.endsWith('/refresh')) {
          fault.failWrite = true;
          return WireReply.json(_tokens('renewed'));
        }
        return original(request);
      };
      await expectLater(
        subject.auth.refreshSession(),
        throwsA(isA<SessionStorageException>()),
      );
      expect(subject.auth.currentSession?.refreshToken, 'refresh-renewed');
      expect(subject.auth.state.status, AuthStatus.temporarilyUnavailable);
      expect(
        (jsonDecode((await disk.read())!)
            as Map<String, Object?>)['rotation_pending'],
        isTrue,
      );
      fault.failWrite = false;
      expect(await subject.auth.accessTokenForRequest(), 'access-renewed');
      expect(api.at('/refresh').length, 1);
      expect(
        (jsonDecode((await disk.read())!)
            as Map<String, Object?>)['rotation_pending'],
        isFalse,
      );
      await subject.close();
      final restored = createClient();
      await restored.auth.restoreSession();
      expect(restored.auth.currentSession?.refreshToken, 'refresh-renewed');
      expect(api.at('/refresh').length, 1);
    },
  );

  test(
    'process restart after renewed-pair write failure refuses old-token replay',
    () async {
      final fault = FaultSessionStore(disk);
      final subject = createClient(store: fault);
      await signIn(subject);
      final original = api.handle;
      api.handle = (request) {
        if (request.uri.path.endsWith('/refresh')) {
          fault.failWrite = true;
          return WireReply.json(_tokens('renewed'));
        }
        return original(request);
      };
      await expectLater(
        subject.auth.refreshSession(),
        throwsA(isA<SessionStorageException>()),
      );
      await subject.close();
      final restored = createClient();
      await expectLater(
        restored.auth.restoreSession(),
        throwsA(isA<RefreshUncertainException>()),
      );
      expect(api.at('/refresh').length, 1);
      expect(api.at('/users/me'), isEmpty);
    },
  );

  test(
    'sign-out serializes durable clear after an in-flight sign-in write',
    () async {
      final fault = FaultSessionStore(disk);
      final writing = Completer<void>();
      final release = Completer<void>();
      fault.beforeWrite = (_) {
        writing.complete();
        return release.future;
      };
      final subject = createClient(store: fault);
      final login = signIn(subject);
      final rejected = expectLater(
        login,
        throwsA(isA<SessionChangedException>()),
      );
      await writing.future;
      final logout = subject.auth.signOut();
      release.complete();
      await Future.wait([rejected, logout]);
      expect(subject.auth.currentSession, isNull);
      expect(subject.auth.state.status, AuthStatus.signedOut);
      expect(await disk.read(), isNull);
    },
  );

  test(
    'marker persistence failure prevents refresh from reaching the server',
    () async {
      final fault = FaultSessionStore(disk);
      final subject = createClient(store: fault);
      await signIn(subject);
      fault.failWrite = true;
      await expectLater(
        subject.auth.refreshSession(),
        throwsA(isA<SessionStorageException>()),
      );
      expect(api.at('/refresh'), isEmpty);
      expect(subject.auth.currentSession?.refreshToken, 'refresh-a');
      fault.failWrite = false;
      await subject.auth.refreshSession();
      expect(api.at('/refresh').single.body, {'token': 'refresh-a'});
    },
  );

  test(
    'sign-in persistence and sign-out clear failures are observable',
    () async {
      final fault = FaultSessionStore(disk)..failWrite = true;
      final subject = createClient(store: fault);
      await expectLater(
        signIn(subject),
        throwsA(isA<SessionStorageException>()),
      );
      expect(subject.auth.state.status, AuthStatus.temporarilyUnavailable);
      fault.failWrite = false;
      await subject.auth.accessTokenForRequest();
      expect(await disk.read(), isNotNull);
      fault.failClear = true;
      await expectLater(
        subject.auth.signOut(),
        throwsA(isA<SessionStorageException>()),
      );
      expect(subject.auth.currentSession, isNull);
      expect(subject.auth.state.status, AuthStatus.signedOut);
      expect(await disk.read(), isNotNull);
      expect(api.at('/logout').length, 1);
    },
  );

  test(
    'write-ahead marker survives interrupted rotation and blocks restart replay',
    () async {
      await signIn();
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/refresh')
          ? release.future
          : original(request);
      final pending = client.auth.refreshSession();
      final stopped = expectLater(pending, throwsA(isA<AnythinkException>()));
      await api.waitFor('/refresh');
      expect(
        (jsonDecode((await disk.read())!)
            as Map<String, Object?>)['rotation_pending'],
        isTrue,
      );
      await client.close();
      await stopped;
      release.complete(WireReply.json(_tokens('response-lost')));
      final restored = createClient();
      await expectLater(
        restored.auth.restoreSession(),
        throwsA(isA<RefreshUncertainException>()),
      );
      expect(restored.auth.state.status, AuthStatus.reauthenticationRequired);
      await expectLater(
        restored.auth.accessTokenForRequest(),
        throwsA(isA<RefreshUncertainException>()),
      );
      expect(
        () => restored.auth.refreshSession(),
        throwsA(isA<RefreshUncertainException>()),
      );
      expect(api.at('/refresh').length, 1);
      expect(api.at('/users/me'), isEmpty);
    },
  );

  for (final failure in ['server', 'malformed', 'invalid_tokens']) {
    test(
      '$failure rotation response blocks retry and restore replay',
      () async {
        await signIn();
        final original = api.handle;
        api.handle = (request) {
          if (!request.uri.path.endsWith('/refresh')) return original(request);
          return switch (failure) {
            'server' => WireReply.json({'error': 'internal'}, status: 503),
            'malformed' => WireReply.bytes(
              utf8.encode('{broken'),
              contentType: 'application/json',
            ),
            _ => WireReply.json({'access_token': 'incomplete'}),
          };
        };
        await expectLater(
          client.auth.refreshSession(),
          throwsA(isA<AnythinkException>()),
        );
        expect(client.auth.state.status, AuthStatus.reauthenticationRequired);
        expect(
          () => client.auth.refreshSession(),
          throwsA(isA<RefreshUncertainException>()),
        );
        await expectLater(
          client.auth.restoreSession(),
          throwsA(isA<RefreshUncertainException>()),
        );
        await client.close();
        final restored = createClient();
        await expectLater(
          restored.auth.restoreSession(),
          throwsA(isA<RefreshUncertainException>()),
        );
        expect(api.at('/refresh').length, 1);
        expect(api.at('/users/me'), isEmpty);
      },
    );
  }

  test(
    'rotation timeout is uncertain, durable and cannot be automatically replayed',
    () async {
      final subject = createClient(timeout: const Duration(milliseconds: 100));
      await signIn(subject);
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/refresh')
          ? release.future
          : original(request);
      await expectLater(
        subject.auth.refreshSession(),
        throwsA(
          isA<TransportException>()
              .having(
                (error) => error.failure,
                'failure',
                TransportFailure.timeout,
              )
              .having(
                (error) => error.outcomeUncertain,
                'outcome uncertain',
                isTrue,
              ),
        ),
      );
      expect(subject.auth.state.status, AuthStatus.reauthenticationRequired);
      expect(
        () => subject.auth.refreshSession(),
        throwsA(isA<RefreshUncertainException>()),
      );
      release.complete(WireReply.json(_tokens('late')));
      await subject.close();
      await expectLater(
        createClient().auth.restoreSession(),
        throwsA(isA<RefreshUncertainException>()),
      );
      expect(api.at('/refresh').length, 1);
    },
  );

  test(
    'refresh 401 clears durable credentials and requires new sign-in',
    () async {
      await signIn();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/refresh')
          ? WireReply.json({'error': 'invalid_refresh_token'}, status: 401)
          : original(request);
      await expectLater(
        client.auth.refreshSession(),
        throwsA(isA<ApiException>()),
      );
      expect(client.auth.currentSession, isNull);
      expect(client.auth.state.status, AuthStatus.reauthenticationRequired);
      expect(await disk.read(), isNull);
      expect(
        () => client.auth.refreshSession(),
        throwsA(isA<AuthRequiredException>()),
      );
      final restored = createClient();
      await restored.auth.restoreSession();
      expect(restored.auth.state.status, AuthStatus.signedOut);
      expect(api.at('/refresh').length, 1);
    },
  );

  test(
    'one cancelled waiter does not cancel shared proactive refresh',
    () async {
      await signIn();
      now = now.add(const Duration(hours: 1));
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/refresh')
          ? release.future
          : original(request);
      final cancellation = CancellationToken();
      final cancelledRequest = client
          .records('notes')
          .get(1, cancellation: cancellation);
      final cancelled = expectLater(
        cancelledRequest,
        throwsA(
          isA<TransportException>().having(
            (error) => error.failure,
            'failure',
            TransportFailure.cancelled,
          ),
        ),
      );
      final survivingRequest = client.records('notes').get(2);
      await api.waitFor('/refresh');
      cancellation.cancel();
      await cancelled.timeout(const Duration(seconds: 1));
      expect(api.at('/refresh').length, 1);
      release.complete(WireReply.json(_tokens('renewed')));
      await survivingRequest;
      expect(api.at('/items/1'), isEmpty);
      expect(api.at('/items/2').single.authorization, 'Bearer access-renewed');
      expect(client.auth.state.status, AuthStatus.authenticated);
    },
  );

  test(
    'pending sign-in cleared by logout cannot adopt its late response',
    () async {
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/token')
          ? release.future
          : original(request);
      final pending = signIn();
      final rejected = expectLater(
        pending,
        throwsA(isA<SessionChangedException>()),
      );
      await api.waitFor('/token');
      await client.auth.signOut();
      release.complete(WireReply.json(_tokens('late-login')));
      await rejected;
      expect(client.auth.state.status, AuthStatus.signedOut);
      expect(client.auth.currentSession, isNull);
      expect(await disk.read(), isNull);
      expect(api.at('/logout').single.body, {'token': 'refresh-late-login'});
    },
  );

  test('sign-out clears locally when remote revocation fails', () async {
    await signIn();
    final original = api.handle;
    api.handle = (request) => request.uri.path.endsWith('/logout')
        ? WireReply.json({'error': 'unavailable'}, status: 503)
        : original(request);
    final result = await client.auth.signOut();
    expect(result.remoteRevoked, isFalse);
    expect(result.remoteError, isA<ApiException>());
    expect(client.auth.state.status, AuthStatus.signedOut);
    expect(client.auth.currentSession, isNull);
    expect(await disk.read(), isNull);
  });

  test(
    'invalid scope and malformed saved JSON remain untouched and fail closed',
    () async {
      for (final serialized in [
        'not-json',
        jsonEncode({
          'version': 1,
          'api_origin': api.origin.toString(),
          'project_id': 'other-project',
          'rotation_pending': false,
          'session': {
            'access_token': 'a',
            'refresh_token': 'b',
            'expires_at': now.toIso8601String(),
          },
        }),
      ]) {
        await disk.write(serialized);
        final subject = createClient();
        await expectLater(
          subject.auth.restoreSession(),
          throwsA(isA<ProtocolException>()),
        );
        expect(subject.auth.currentSession, isNull);
        expect(await disk.read(), serialized);
      }
      expect(api.requests, isEmpty);
      final fault = FaultSessionStore(disk)..failRead = true;
      await expectLater(
        createClient(store: fault).auth.restoreSession(),
        throwsA(isA<SessionStorageException>()),
      );
    },
  );

  test(
    'restore rejects invalid calendar or timezone-free expiry before HTTP',
    () async {
      for (final expiry in <Object?>[
        '2026-02-30T12:00:00Z',
        '2026-13-01T12:00:00Z',
        '2026-10-00T12:00:00Z',
        '2026-10-14T24:00:00Z',
        '2026-10-14T12:60:00Z',
        '2026-10-14T12:00:00+24:00',
        '2026-10-14T12:00:00',
        '2026-10-14',
        1791979200,
        null,
      ]) {
        final serialized = jsonEncode({
          'version': 1,
          'api_origin': api.origin.toString(),
          'project_id': 'auth-tests',
          'rotation_pending': false,
          'session': {
            'access_token': 'synthetic-access',
            'refresh_token': 'synthetic-refresh',
            'expires_at': expiry,
          },
        });
        await disk.write(serialized);
        final subject = createClient();
        await expectLater(
          subject.auth.restoreSession(),
          throwsA(isA<ProtocolException>()),
        );
        expect(subject.auth.currentSession, isNull);
        expect(subject.auth.state.user, isNull);
        expect(await disk.read(), serialized);
        expect(api.requests, isEmpty);
      }
    },
  );

  test(
    'restore accepts an explicit expiry offset and normalizes the instant to UTC',
    () async {
      await disk.write(
        jsonEncode({
          'version': 1,
          'api_origin': api.origin.toString(),
          'project_id': 'auth-tests',
          'rotation_pending': false,
          'session': {
            'access_token': 'access-a',
            'refresh_token': 'refresh-a',
            'expires_at': '2026-10-14T15:00:00.123456+01:00',
          },
        }),
      );
      await client.auth.restoreSession();
      expect(
        client.auth.currentSession?.expiresAt,
        DateTime.utc(2026, 10, 14, 14, 0, 0, 123, 456),
      );
      expect(client.auth.currentSession?.expiresAt.isUtc, isTrue);
      expect(api.at('/refresh'), isEmpty);
      expect(api.at('/users/me'), hasLength(1));
    },
  );

  test(
    'auth endpoint methods preserve JSON, plain acknowledgments, booleans and 204s',
    () async {
      await signIn();
      api.requests.clear();
      api.handle = (request) {
        final path = request.uri.path;
        if (path.endsWith('/register') || path.endsWith('/confirm-email')) {
          return WireReply.text('ok');
        }
        if (path.endsWith('/permissions')) {
          return WireReply.json(['notes:read']);
        }
        if (path.endsWith('/has-permission') ||
            path.endsWith('/has-role') ||
            path.endsWith('/is-admin')) {
          return WireReply.json(true);
        }
        if (path.endsWith('/providers')) {
          return WireReply.json([
            {'provider': 'google', 'display_name': 'Google', 'icon': 'google'},
          ]);
        }
        if (path.endsWith('/authorize')) {
          return WireReply.json({
            'authorization_url': 'https://accounts.example.test/oauth',
          });
        }
        if (path.contains('/invites/') && request.method == 'GET') {
          return WireReply.json({'email': 'invite@example.test'});
        }
        return WireReply.empty();
      };
      expect(
        await client.auth.signUp(
          firstName: 'A',
          lastName: 'B',
          email: 'a@example.test',
          password: 'test',
          referralCode: 'ref',
          signupContext: {'source': 'test'},
        ),
        'ok',
      );
      expect(
        await client.auth.confirmEmail(
          email: 'a@example.test',
          token: 'verify',
        ),
        'ok',
      );
      await client.auth.resendConfirmation('a+b@example.test');
      await client.auth.requestPasswordReset('a+b@example.test');
      await client.auth.confirmPasswordReset(
        email: 'a@example.test',
        token: 'reset',
        password: 'new',
      );
      await client.auth.updateProfile(firstName: 'New', lastName: 'Name');
      await client.auth.changePassword(
        currentPassword: 'old',
        newPassword: 'new',
      );
      expect(await client.auth.getPermissions(), ['notes:read']);
      expect(await client.auth.hasPermission('notes:read'), isTrue);
      expect(await client.auth.hasRole('admin'), isTrue);
      expect(await client.auth.isAdmin(), isTrue);
      final providers = await client.auth.getProviders();
      expect(providers.single.provider, 'google');
      expect(providers.single.displayName, 'Google');
      expect(providers.single.icon, 'google');
      expect(
        await client.auth.getAuthorizationUrl(
          WebProvider.google,
          Uri.parse('example-app://callback'),
        ),
        Uri.parse('https://accounts.example.test/oauth'),
      );
      expect(await client.auth.getInvitation('invite'), {
        'email': 'invite@example.test',
      });
      await client.auth.acceptInvitation(
        inviteToken: 'invite',
        firstName: 'A',
        lastName: 'B',
        password: 'test',
      );
      expect(
        api.requests.map(
          (request) =>
              '${request.method} ${request.uri.path.replaceFirst('/org/auth-tests', '')}',
        ),
        [
          'POST /auth/v1/register',
          'POST /auth/v1/confirm-email',
          'POST /auth/v1/resend-confirm-email',
          'POST /auth/v1/send-password-reset',
          'POST /auth/v1/confirm-password-reset',
          'PUT /users/me',
          'PUT /users/me/password',
          'GET /users/me/permissions',
          'GET /users/me/has-permission',
          'GET /users/me/has-role',
          'GET /users/me/is-admin',
          'GET /auth/v1/providers',
          'GET /auth/v1/google/authorize',
          'GET /users/invites/invite',
          'POST /users/invites/invite',
        ],
      );
      expect(api.at('/register').single.body, {
        'first_name': 'A',
        'last_name': 'B',
        'email': 'a@example.test',
        'password': 'test',
        'referral_code': 'ref',
        'signup_context': {'source': 'test'},
      });
      expect(api.at('/resend-confirm-email').single.uri.queryParameters, {
        'email': 'a+b@example.test',
      });
      expect(api.at('/has-permission').single.uri.queryParameters, {
        'permissionName': 'notes:read',
      });
      expect(api.at('/has-role').single.uri.queryParameters, {
        'roleName': 'admin',
      });
      expect(api.at('/authorize').single.uri.queryParameters, {
        'redirectUri': 'example-app://callback',
      });
      expect(
        api.requests
            .where((request) => !request.uri.path.contains('/users/me'))
            .every((request) => request.authorization == null),
        isTrue,
      );
    },
  );

  test(
    'native sign-in, Apple exchange and OAuth callback have distinct contracts',
    () async {
      api.handle = (_) => WireReply.json(_tokens('provider'));
      await client.auth.signInWithNativeToken(
        provider: NativeProvider.apple,
        identityToken: 'native-id',
        userIdentifier: 'native-user',
        givenName: 'A',
        familyName: 'B',
        signupContext: {'source': 'test'},
      );
      await client.auth.exchangeAppleCode('one-use-code');
      await client.auth.completeOAuth(
        provider: WebProvider.github,
        code: 'code&value',
        state: 'state+value',
      );
      expect(api.at('/native/apple').single.body, {
        'identity_token': 'native-id',
        'user_identifier': 'native-user',
        'given_name': 'A',
        'family_name': 'B',
        'signup_context': {'source': 'test'},
      });
      expect(api.at('/exchange').single.body, {'code': 'one-use-code'});
      expect(api.at('/github/callback').single.method, 'GET');
      expect(api.at('/github/callback').single.uri.queryParameters, {
        'code': 'code&value',
        'state': 'state+value',
      });
      expect(
        api.requests.every((request) => request.authorization == null),
        isTrue,
      );
      await expectLater(
        client.auth.completeOAuth(
          provider: WebProvider.apple,
          code: 'wrong-flow',
          state: 'state',
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'web authorize encodes all documented attribution without sending auth',
    () async {
      await signIn();
      final session = client.auth.currentSession;
      final generation = client.auth.generation;
      api.requests.clear();
      api.handle = (_) => WireReply.json({
        'authorization_url':
            'https://accounts.example.test/authorize?state=one-use',
      });
      const attribution = SignupAttribution(
        utmSource: 'community & friends',
        utmMedium: 'social+chat',
        utmCampaign: 'Mobile launch / October',
        utmTerm: 'Flutter SDK',
        utmContent: 'a=b&redirectUri=untrusted',
        referrer: 'https://example.test/post?a=1&b=2',
        signupCountry: 'NG',
      );
      final redirect = Uri.parse(
        'https://app.example.test/callback?next=%2Fhome',
      );
      final url = await client.auth.getAuthorizationUrl(
        WebProvider.google,
        redirect,
        attribution: attribution,
      );
      expect(
        url,
        Uri.parse('https://accounts.example.test/authorize?state=one-use'),
      );
      final request = api.requests.single;
      expect(request.method, 'GET');
      expect(request.uri.path, '/org/auth-tests/auth/v1/google/authorize');
      expect(request.uri.queryParameters, {
        'redirectUri': redirect.toString(),
        'utm_source': 'community & friends',
        'utm_medium': 'social+chat',
        'utm_campaign': 'Mobile launch / October',
        'utm_term': 'Flutter SDK',
        'utm_content': 'a=b&redirectUri=untrusted',
        'referrer': 'https://example.test/post?a=1&b=2',
        'signup_country': 'NG',
      });
      expect(request.authorization, isNull);
      expect(request.body, isNull);
      expect(client.auth.currentSession, same(session));
      expect(client.auth.generation, generation);
      expect(
        const SignupAttribution(utmSource: 'community').toQueryParameters(),
        {'utm_source': 'community'},
      );
      expect(
        () => attribution.toQueryParameters()['utm_source'] = 'mutated',
        throwsUnsupportedError,
      );
    },
  );
}

Map<String, Object?> _tokens(String suffix) => {
  'access_token': 'access-$suffix',
  'refresh_token': 'refresh-$suffix',
  'expires_in': 3600,
};

Map<String, Object?> _user(int id) => {
  'id': id,
  'gid': 'user-$id',
  'email': 'user$id@example.test',
  'first_name': 'User',
  'last_name': '$id',
};
