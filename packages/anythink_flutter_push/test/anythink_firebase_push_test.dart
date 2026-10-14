import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_flutter_push/anythink_flutter_push.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const channel = MethodChannel('plugins.flutter.io/firebase_messaging');

final class RealHttpOverrides extends HttpOverrides {}

Future<void> nativeEvent(String name, Object? value) async {
  final done = Completer<void>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(name, value)),
        (_) => done.complete(),
      );
  await done.future;
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Condition was not reached.');
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  late FirebaseMessaging messaging;
  late HttpServer server;
  late AnythinkClient client;
  late AnythinkFirebasePush push;
  late List<MethodCall> calls;
  late List<JsonObject> registrations;
  late List<String?> authorization;
  late List<Object> automaticErrors;
  late List<PushSyncResult> results;
  late StreamSubscription<PushSyncResult> resultSubscription;
  int permission = 1;
  int pushStatus = 200;
  String? nativeToken = 'fixture-fcm-token';
  String? apns = 'fixture-apns-token';
  Completer<void>? tokenEntered;
  Completer<void>? tokenRelease;
  Completer<void>? requestEntered;
  Completer<void>? requestRelease;
  Object? tokenError;
  Map<String, Object?>? initialMessage;
  Object? initialMessageError;
  Completer<void>? initialMessageEntered;
  Completer<void>? initialMessageRelease;

  setUpAll(() async {
    await Firebase.initializeApp();
    messaging = FirebaseMessaging.instance;
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    permission = 1;
    pushStatus = 200;
    nativeToken = 'fixture-fcm-token';
    apns = 'fixture-apns-token';
    tokenEntered = null;
    tokenRelease = null;
    requestEntered = null;
    requestRelease = null;
    tokenError = null;
    initialMessage = null;
    initialMessageError = null;
    initialMessageEntered = null;
    initialMessageRelease = null;
    calls = [];
    registrations = [];
    authorization = [];
    automaticErrors = [];
    results = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'Messaging#getNotificationSettings':
            case 'Messaging#requestPermission':
              return {'authorizationStatus': permission};
            case 'Messaging#getAPNSToken':
              return {'token': apns};
            case 'Messaging#getToken':
              final entered = tokenEntered;
              if (entered != null && !entered.isCompleted) entered.complete();
              await tokenRelease?.future;
              final error = tokenError;
              if (error != null) throw error;
              return {'token': nativeToken};
            case 'Messaging#getInitialMessage':
              final entered = initialMessageEntered;
              if (entered != null && !entered.isCompleted) entered.complete();
              await initialMessageRelease?.future;
              final error = initialMessageError;
              if (error != null) throw error;
              // The Android plugin can return the same launch message twice.
              // Leave the native value available to expose SDK duplicates.
              return initialMessage;
            default:
              fail('Unexpected Firebase method: ${call.method}');
          }
        });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/auth/v1/token')) {
          final email = (jsonDecode(body) as Map)['email'];
          request.response.write(
            jsonEncode({
              'access_token': 'fixture-access-$email',
              'refresh_token': 'fixture-refresh-$email',
              'expires_in': 1800,
            }),
          );
        } else if (request.uri.path.endsWith('/auth/v1/logout')) {
          request.response.statusCode = 204;
        } else if (request.uri.path.endsWith('/auth/v1/refresh')) {
          request.response.statusCode = 500;
          request.response.write('{"error":"refresh_failed"}');
        } else if (request.uri.path.endsWith('/push/devices')) {
          expect(request.method, 'POST');
          registrations.add(Map<String, Object?>.from(jsonDecode(body) as Map));
          authorization.add(request.headers.value('authorization'));
          final entered = requestEntered;
          if (entered != null && !entered.isCompleted) entered.complete();
          await requestRelease?.future;
          request.response.statusCode = pushStatus;
          request.response.write(
            jsonEncode(
              pushStatus == 200
                  ? {
                      'id': registrations.length,
                      'registered_at': '2026-10-14T10:00:00Z',
                    }
                  : {'error': 'fixture conflict'},
            ),
          );
        } else {
          fail('Unexpected Anythink endpoint: ${request.uri.path}');
        }
        await request.response.close();
      } on HttpException {
        // Cancellation intentionally closes the connection.
      } on SocketException {
        // Cancellation intentionally closes the connection.
      }
    });
    client = HttpOverrides.runWithHttpOverrides(
      () => AnythinkClient(
        apiOrigin: Uri.parse('http://127.0.0.1:${server.port}'),
        projectId: 'fixture-project',
        allowInsecureLocalhost: true,
      ),
      RealHttpOverrides(),
    );
    await client.auth.signInWithPassword(
      email: 'a@example.test',
      password: 'fixture',
    );
    push = AnythinkFirebasePush(
      client: client,
      messaging: messaging,
      metadata: {'app_version': '1.2.3'},
      onError: (error, _) => automaticErrors.add(error),
    );
    resultSubscription = push.results.listen(results.add);
  });

  tearDown(() async {
    if (tokenRelease case final release? when !release.isCompleted) {
      release.complete();
    }
    if (requestRelease case final release? when !release.isCompleted) {
      release.complete();
    }
    if (initialMessageRelease case final release? when !release.isCompleted) {
      release.complete();
    }
    await resultSubscription.cancel();
    await push.dispose();
    await client.close();
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'constructor is inert; start registers the real plugin token over HTTP',
    () async {
      expect(calls, isEmpty);
      final result = await push.start();
      expect(result.status, PushSyncStatus.registered);
      expect(result.registration!.id, 1);
      expect(registrations.single, {
        'provider': 'fcm',
        'token': 'fixture-fcm-token',
        'metadata': {'app_version': '1.2.3', 'platform': 'android'},
      });
      expect(authorization.single, 'Bearer fixture-access-a@example.test');
      expect(calls.map((c) => c.method), [
        'Messaging#getNotificationSettings',
        'Messaging#getToken',
      ]);
      expect(result.toString(), isNot(contains('fixture-fcm-token')));
      expect((await push.start()).status, PushSyncStatus.alreadyRegistered);
      expect(registrations, hasLength(1));
    },
  );

  test('permission is explicit, including provisional authorization', () async {
    permission = -1;
    expect((await push.start()).status, PushSyncStatus.permissionRequired);
    expect(calls.map((c) => c.method), ['Messaging#getNotificationSettings']);
    permission = 2;
    final settings = await push.requestPermission(
      alert: false,
      sound: false,
      provisional: true,
    );
    expect(settings.authorizationStatus, AuthorizationStatus.provisional);
    final flags = (calls.last.arguments as Map)['permissions'] as Map;
    expect(flags['provisional'], true);
    expect(flags['alert'], false);
    expect(flags['sound'], false);
    expect(registrations, isEmpty);
    expect((await push.synchronize()).status, PushSyncStatus.registered);
  });

  test(
    'uncertain refresh cancels pending registration without success',
    () async {
      requestEntered = Completer<void>();
      requestRelease = Completer<void>();
      final starting = push.start();
      await requestEntered!.future;
      final generation = client.auth.generation;
      await expectLater(
        client.auth.refreshSession(),
        throwsA(isA<ApiException>()),
      );
      expect(client.auth.generation, generation);
      expect(client.auth.currentSession, isNotNull);
      expect(client.auth.state.status, AuthStatus.reauthenticationRequired);
      requestRelease!.complete();
      expect((await starting).status, PushSyncStatus.superseded);
      expect((await push.synchronize()).status, PushSyncStatus.signedOut);
      expect(
        results.where((result) => result.status == PushSyncStatus.registered),
        isEmpty,
      );
      expect(automaticErrors, isEmpty);
    },
  );

  test('nested metadata is snapshotted before native token lookup', () async {
    final tags = <Object?>['original'];
    final details = <String, Object?>{'tags': tags};
    final adapter = AnythinkFirebasePush(
      client: client,
      messaging: messaging,
      metadata: {'details': details, 'repeated': details},
    );
    addTearDown(adapter.dispose);
    tokenEntered = Completer<void>();
    tokenRelease = Completer<void>();
    final pending = adapter.start();
    await tokenEntered!.future;
    tags.clear();
    details['changed'] = true;
    tokenRelease!.complete();
    expect((await pending).status, PushSyncStatus.registered);
    expect(registrations.single['metadata'], {
      'details': {
        'tags': ['original'],
      },
      'repeated': {
        'tags': ['original'],
      },
      'platform': 'android',
    });
    final snapshot = adapter.metadata['details']! as Map<String, Object?>;
    expect(() => snapshot.clear(), throwsUnsupportedError);
    expect(
      () => (snapshot['tags']! as List<Object?>).clear(),
      throwsUnsupportedError,
    );
  });

  test('invalid metadata fails before native calls with redacted errors', () {
    final cycle = <String, Object?>{};
    cycle['private-metadata-value'] = cycle;
    final listCycle = <Object?>[];
    listCycle.add(listCycle);
    for (final value in <Object>[
      cycle,
      listCycle,
      double.nan,
      double.infinity,
      <Object?, Object?>{7: 'private-metadata-value'},
      <Object?>{'private-metadata-value'},
      Object(),
    ]) {
      expect(
        () => AnythinkFirebasePush(
          client: client,
          messaging: messaging,
          metadata: {'nested': value},
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'redacted error',
            isNot(contains('private-metadata-value')),
          ),
        ),
      );
    }
    expect(calls, isEmpty);
    expect(registrations, isEmpty);
  });

  test(
    'denied and permanently denied never acquire or register a token',
    () async {
      permission = 0;
      expect((await push.start()).status, PushSyncStatus.permissionDenied);
      permission = 3;
      expect(
        (await push.synchronize()).status,
        PushSyncStatus.permissionDenied,
      );
      expect(
        calls.every((c) => c.method == 'Messaging#getNotificationSettings'),
        true,
      );
      expect(registrations, isEmpty);
    },
  );

  test('iOS waits for APNs, then foreground resume retries', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    apns = null;
    expect((await push.start()).status, PushSyncStatus.apnsPending);
    expect(calls.any((c) => c.method == 'Messaging#getToken'), false);
    apns = 'fixture-ready-apns';
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await until(
      () => results.any((r) => r.status == PushSyncStatus.registered),
    );
    expect(registrations.single['metadata'], {
      'app_version': '1.2.3',
      'platform': 'iOS',
    });
    expect(automaticErrors, isEmpty);
  });

  test(
    'token refresh re-reads current token and serializes duplicate events',
    () async {
      await push.start();
      nativeToken = 'fixture-rotated';
      await nativeEvent('Messaging#onTokenRefresh', 'stale-event-value');
      await nativeEvent('Messaging#onTokenRefresh', 'fixture-rotated');
      await until(() => registrations.length == 2);
      await push.synchronize();
      expect(registrations.map((r) => r['token']), [
        'fixture-fcm-token',
        'fixture-rotated',
      ]);
    },
  );

  test('signed out never touches Firebase token APIs', () async {
    await client.auth.signOut();
    expect((await push.start()).status, PushSyncStatus.signedOut);
    expect(calls, isEmpty);
    expect(registrations, isEmpty);
  });

  test(
    'explicit force refreshes backend registration for the same token',
    () async {
      await push.start();
      expect(
        (await push.synchronize()).status,
        PushSyncStatus.alreadyRegistered,
      );
      expect(
        (await push.synchronize(force: true)).status,
        PushSyncStatus.registered,
      );
      expect(registrations, hasLength(2));
    },
  );

  test('account change during native token lookup fences old work', () async {
    tokenEntered = Completer<void>();
    tokenRelease = Completer<void>();
    final starting = push.start();
    await tokenEntered!.future;
    await client.auth.signInWithPassword(
      email: 'b@example.test',
      password: 'fixture',
    );
    tokenRelease!.complete();
    expect((await starting).status, PushSyncStatus.superseded);
    await until(() => registrations.isNotEmpty);
    expect(authorization, ['Bearer fixture-access-b@example.test']);
    expect(automaticErrors, isEmpty);
  });

  test(
    'logout during HTTP registration cancels and never reports success',
    () async {
      requestEntered = Completer<void>();
      requestRelease = Completer<void>();
      final starting = push.start();
      await requestEntered!.future;
      await client.auth.signOut();
      requestRelease!.complete();
      expect((await starting).status, PushSyncStatus.superseded);
      await until(
        () => results.any((r) => r.status == PushSyncStatus.signedOut),
      );
      expect(results.any((r) => r.status == PushSyncStatus.registered), false);
      expect(automaticErrors, isEmpty);
    },
  );

  test('backend conflicts are visible; explicit retry is possible', () async {
    pushStatus = 409;
    await expectLater(
      push.start(),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
    );
    expect(registrations, hasLength(1));
    nativeToken = 'fixture-second';
    await nativeEvent('Messaging#onTokenRefresh', 'fixture-second');
    await until(() => automaticErrors.isNotEmpty);
    expect(automaticErrors.single, isA<ApiException>());
    pushStatus = 200;
    expect((await push.synchronize()).status, PushSyncStatus.registered);
  });

  test(
    'native errors are redacted for explicit and automatic synchronization',
    () async {
      tokenError = PlatformException(
        code: 'fixture-native-error',
        message: 'sensitive-device-token',
        details: {'native_payload': 'sensitive-device-token'},
      );
      final redacted = isA<PushNativeException>()
          .having(
            (error) => error.operation,
            'operation',
            PushNativeOperation.deviceToken,
          )
          .having(
            (error) => error.toString(),
            'diagnostic',
            isNot(contains('sensitive-device-token')),
          );
      await expectLater(push.start(), throwsA(redacted));
      await nativeEvent('Messaging#onTokenRefresh', 'fixture-event');
      await until(() => automaticErrors.isNotEmpty);
      expect(automaticErrors.single, redacted);
      expect(
        automaticErrors.single.toString(),
        isNot(contains('sensitive-device-token')),
      );
      expect(registrations, isEmpty);
    },
  );

  test(
    'dispose fences a pending native call and removes owned listeners',
    () async {
      tokenEntered = Completer<void>();
      tokenRelease = Completer<void>();
      final starting = push.start();
      await tokenEntered!.future;
      await push.dispose();
      final count = calls.length;
      tokenRelease!.complete();
      expect((await starting).status, PushSyncStatus.superseded);
      await nativeEvent('Messaging#onTokenRefresh', 'fixture-after-dispose');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await client.auth.signOut();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls.length, count);
      expect(registrations, isEmpty);
      expect(push.start, throwsStateError);
      await push.dispose();
    },
  );

  test('raw message routing never invents an action callback', () async {
    // Initialize FlutterFire's platform delegate even when this test runs alone.
    expect(await push.getInitialMessage(), isNull);
    calls.clear();
    final messages = <RemoteMessage>[];
    final taps = <RemoteMessage>[];
    final foreground = push.messages.listen(messages.add);
    final opened = push.openedMessages.listen(taps.add);
    addTearDown(foreground.cancel);
    addTearDown(opened.cancel);
    await nativeEvent('Messaging#onMessage', {
      'messageId': 'fixture-foreground',
      'data': {'route': 'inbox'},
    });
    await nativeEvent('Messaging#onMessageOpenedApp', {
      'messageId': 'fixture-tap',
    });
    await until(() => messages.isNotEmpty && taps.isNotEmpty);
    expect(messages.single.messageId, 'fixture-foreground');
    expect(taps.single.messageId, 'fixture-tap');
    initialMessage = {'messageId': 'fixture-launch'};
    expect((await push.getInitialMessage())!.messageId, 'fixture-launch');
    expect(await push.getInitialMessage(), isNull);
    expect(
      calls.where((call) => call.method == 'Messaging#getInitialMessage'),
      hasLength(1),
    );
    expect(registrations, isEmpty);
  });

  for (final hasMessage in [true, false]) {
    test(
      'concurrent initial message callers have one consumer (message: $hasMessage)',
      () async {
        initialMessage = hasMessage ? {'messageId': 'fixture-launch'} : null;
        initialMessageEntered = Completer<void>();
        initialMessageRelease = Completer<void>();
        final owner = push.getInitialMessage();
        await initialMessageEntered!.future;
        final follower = push.getInitialMessage();
        final otherFollower = push.getInitialMessage();
        initialMessageRelease!.complete();
        expect((await owner)?.messageId, hasMessage ? 'fixture-launch' : null);
        expect(await follower, isNull);
        expect(await otherFollower, isNull);
        expect(
          calls.where((call) => call.method == 'Messaging#getInitialMessage'),
          hasLength(1),
        );
        if (!hasMessage) {
          initialMessage = {'messageId': 'fixture-later-launch'};
          expect(
            (await push.getInitialMessage())?.messageId,
            'fixture-later-launch',
          );
          expect(await push.getInitialMessage(), isNull);
        }
      },
    );
  }

  test(
    'initial message failure reaches all callers and allows explicit retry',
    () async {
      initialMessageEntered = Completer<void>();
      initialMessageRelease = Completer<void>();
      initialMessageError = PlatformException(
        code: 'fixture-failure',
        message: 'sensitive-notification-data',
      );
      final redacted = isA<PushNativeException>()
          .having(
            (error) => error.operation,
            'operation',
            PushNativeOperation.initialMessage,
          )
          .having(
            (error) => error.toString(),
            'diagnostic',
            isNot(contains('sensitive-notification-data')),
          );
      final owner = expectLater(push.getInitialMessage(), throwsA(redacted));
      await initialMessageEntered!.future;
      final follower = expectLater(push.getInitialMessage(), throwsA(redacted));
      initialMessageRelease!.complete();
      await Future.wait([owner, follower]);
      expect(
        calls.where((call) => call.method == 'Messaging#getInitialMessage'),
        hasLength(1),
      );
      initialMessageError = null;
      initialMessage = {'messageId': 'fixture-retried-launch'};
      expect(
        (await push.getInitialMessage())?.messageId,
        'fixture-retried-launch',
      );
      expect(await push.getInitialMessage(), isNull);
    },
  );

  test(
    'disposal rejects late initial message delivery for every caller',
    () async {
      initialMessage = {'messageId': 'fixture-late-launch'};
      initialMessageEntered = Completer<void>();
      initialMessageRelease = Completer<void>();
      final owner = expectLater(push.getInitialMessage(), throwsStateError);
      await initialMessageEntered!.future;
      final follower = expectLater(push.getInitialMessage(), throwsStateError);
      await push.dispose();
      initialMessageRelease!.complete();
      await Future.wait([owner, follower]);
      expect(push.getInitialMessage, throwsStateError);
      expect(registrations, isEmpty);
    },
  );

  test('initial message guard belongs to the adapter instance', () async {
    initialMessage = {'messageId': 'fixture-launch'};
    expect((await push.getInitialMessage())?.messageId, 'fixture-launch');
    expect(await push.getInitialMessage(), isNull);
    final replacement = AnythinkFirebasePush(
      client: client,
      messaging: messaging,
    );
    addTearDown(replacement.dispose);
    expect(
      (await replacement.getInitialMessage())?.messageId,
      'fixture-launch',
    );
    expect(await replacement.getInitialMessage(), isNull);
    expect(
      calls.where((call) => call.method == 'Messaging#getInitialMessage'),
      hasLength(2),
    );
  });

  test('desktop fails before calling a native method', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(push.start, throwsUnsupportedError);
    expect(calls, isEmpty);
  });
}
