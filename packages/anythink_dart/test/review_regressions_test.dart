import 'dart:async';
import 'dart:convert';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:test/test.dart';

import 'auth_transport_support/local_api.dart';

void main() {
  late LocalApi api;
  late List<AnythinkClient> clients;
  final now = DateTime.utc(2026, 10, 14, 12);

  AnythinkClient createClient({SessionStore? store}) {
    final client = AnythinkClient(
      apiOrigin: api.origin,
      projectId: 'review-regressions',
      sessionStore: store,
      clock: () => now,
      allowInsecureLocalhost: true,
    );
    clients.add(client);
    return client;
  }

  setUp(() async {
    api = await LocalApi.start();
    clients = [];
    api.handle = (_) => WireReply.json(_tokens('initial'));
  });

  tearDown(() async {
    for (final client in clients) {
      await client.close();
    }
    await api.close();
    expect(api.handlerErrors, isEmpty);
  });

  test(
    'token lifetime rejects integer overflow before Duration arithmetic',
    () {
      for (final lifetime in [
        9223372036854775807,
        10000000000000,
        9223372036855,
      ]) {
        expect(
          () => Session.fromTokenResponse(_tokens('invalid', lifetime), now),
          throwsA(isA<ProtocolException>()),
          reason: 'expires_in=$lifetime must not wrap or leak RangeError',
        );
      }
      expect(
        Session.fromTokenResponse(_tokens('valid', 1800), now).expiresAt,
        now.add(const Duration(minutes: 30)),
      );
    },
  );

  test(
    'malformed rotation expiry prevents replay of the consumed token',
    () async {
      final client = createClient();
      await client.auth.signInWithPassword(
        email: 'test@example.test',
        password: 'synthetic',
      );
      api.handle = (_) => WireReply.json(_tokens('invalid', 9223372036855));
      await expectLater(
        client.auth.refreshSession(),
        throwsA(isA<ProtocolException>()),
      );
      expect(client.auth.state.status, AuthStatus.reauthenticationRequired);
      await expectLater(
        Future<Session>.sync(client.auth.refreshSession),
        throwsA(isA<RefreshUncertainException>()),
      );
      expect(api.at('/refresh'), hasLength(1));
    },
  );

  test(
    'native signup context is copied before awaited session clearing',
    () async {
      final client = createClient();
      final context = {'source': 'original'};
      final login = client.auth.signInWithNativeToken(
        provider: NativeProvider.google,
        identityToken: 'synthetic-provider-token',
        userIdentifier: 'synthetic-provider-subject',
        signupContext: context,
      );
      context['source'] = 'changed-after-call';
      await login;
      expect((api.at('/native/google').single.body as Map)['signup_context'], {
        'source': 'original',
      });
    },
  );

  test(
    'dirty-session recovery cannot clear an in-flight rotation marker',
    () async {
      final store = _ControlledStore()..failNextWrite = true;
      final client = createClient(store: store);
      await expectLater(
        client.auth.signInWithPassword(
          email: 'test@example.test',
          password: 'synthetic',
        ),
        throwsA(isA<SessionStorageException>()),
      );
      final reply = Completer<WireReply>();
      api.handle = (_) => reply.future;
      final rotation = client.auth.refreshSession();
      await api.waitFor('/refresh');
      expect((jsonDecode(store.value!) as Map)['rotation_pending'], isTrue);

      var recoveryCompleted = false;
      final recovery = client.auth.refreshIfNeeded().then((session) {
        recoveryCompleted = true;
        return session;
      });
      try {
        // Drain queued persistence operations while the real HTTP refresh remains
        // blocked. A client restart in this interval must still see pending=true.
        await Future<void>(() {});
        expect((jsonDecode(store.value!) as Map)['rotation_pending'], isTrue);
        expect(recoveryCompleted, isFalse);
      } finally {
        reply.complete(WireReply.json(_tokens('renewed')));
        await rotation;
        await recovery;
      }
      final saved = jsonDecode(store.value!) as Map;
      expect(saved['rotation_pending'], isFalse);
      expect(
        (saved['session'] as Map)['refresh_token'],
        'synthetic-refresh-renewed',
      );
      expect(api.at('/refresh'), hasLength(1));
    },
  );

  for (final marker in <Object>['true', 1, <String, Object?>{}, <Object?>[]]) {
    test('stored rotation marker rejects ${marker.runtimeType}', () async {
      final store = _ControlledStore()
        ..value = jsonEncode({
          'version': 1,
          'api_origin': api.origin.toString(),
          'project_id': 'review-regressions',
          'rotation_pending': marker,
          'session': {
            'access_token': 'synthetic-access',
            'refresh_token': 'synthetic-refresh',
            'expires_at': now.add(const Duration(hours: 1)).toIso8601String(),
          },
        });
      final original = store.value;
      final client = createClient(store: store);
      await expectLater(
        client.auth.restoreSession(),
        throwsA(isA<ProtocolException>()),
      );
      expect(client.auth.currentSession, isNull);
      expect(api.requests, isEmpty);
      expect(store.value, original);
    });
  }

  test(
    'page retrieval time rejects finite values whose conversion overflows',
    () {
      for (final timing in <num>[1e308, 9223372036854775807]) {
        expect(
          () => Page<JsonObject>.fromJson(_page(timing), (value) => value),
          throwsA(isA<ProtocolException>()),
        );
      }
      expect(
        Page<JsonObject>.fromJson(_page(0.125), (value) => value).retrievalTime,
        const Duration(microseconds: 125),
      );
    },
  );
}

Map<String, Object?> _tokens(String tag, [int lifetime = 3600]) => {
  'access_token': 'synthetic-access-$tag',
  'refresh_token': 'synthetic-refresh-$tag',
  'expires_in': lifetime,
};

Map<String, Object?> _page(num timing) => {
  'items': <Object?>[],
  'page': 1,
  'page_size': 25,
  'total_items': 0,
  'total_pages': 0,
  'has_next_page': false,
  'has_previous_page': false,
  'retrieval_time': timing,
};

/// Test-only deterministic persistence fault at the public SessionStore seam.
final class _ControlledStore implements SessionStore {
  String? value;
  bool failNextWrite = false;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> clear() async {
    value = null;
  }

  @override
  Future<void> write(String serialized) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('Synthetic storage failure');
    }
    value = serialized;
  }
}
