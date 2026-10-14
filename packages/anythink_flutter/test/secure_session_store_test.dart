import 'dart:async';

import 'package:anythink_flutter/anythink_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

Map<String, Object?> _arguments(MethodCall call) =>
    (call.arguments as Map<Object?, Object?>).cast<String, Object?>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> persisted;
  late List<MethodCall> calls;

  SecureSessionStore store({
    String origin = 'https://api.example.test',
    String project = 'project-a',
    FlutterSecureStorage? storage,
  }) => SecureSessionStore(
    apiOrigin: Uri.parse(origin),
    projectId: project,
    storage: storage,
  );

  Future<Object?> handleCall(MethodCall call) async {
    calls.add(call);
    final arguments = _arguments(call);
    final key = arguments['key'] as String;
    switch (call.method) {
      case 'read':
        return persisted[key];
      case 'write':
        persisted[key] = arguments['value'] as String;
        return null;
      case 'delete':
        persisted.remove(key);
        return null;
      default:
        throw StateError('Unexpected storage method: ${call.method}');
    }
  }

  setUp(() {
    persisted = {};
    calls = [];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, handleCall);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('reads a missing envelope as null without mutating storage', () async {
    expect(await store().read(), isNull);
    expect(calls.map((call) => call.method), ['read']);
    expect(persisted, isEmpty);
  });

  test('writes one opaque envelope without parsing or splitting it', () async {
    final subject = store();
    const envelope = '{"future-core-version":27,"opaque":"sample"}';
    await subject.write(envelope);

    expect(persisted, {subject.storageKey: envelope});
    expect(await subject.read(), envelope);
    expect(calls.map((call) => call.method), ['write', 'read']);
  });

  test(
    'leaves malformed data for the core to validate without deleting it',
    () async {
      final subject = store();
      persisted[subject.storageKey] = 'not JSON';

      expect(await subject.read(), 'not JSON');
      expect(persisted[subject.storageKey], 'not JSON');
      expect(calls.map((call) => call.method), ['read']);
    },
  );

  test('namespaces origin and project without delimiter collisions', () async {
    final first = store();
    final otherProject = store(project: 'project-b');
    final otherHost = store(origin: 'https://other.example.test');
    final otherPort = store(origin: 'https://api.example.test:444');

    expect({
      first.storageKey,
      otherProject.storageKey,
      otherHost.storageKey,
      otherPort.storageKey,
      store(project: 'project:a/b').storageKey,
      store(project: 'project%3Aa%2Fb').storageKey,
    }, hasLength(6));
    await first.write('first envelope');
    await otherProject.write('second envelope');
    expect(await first.read(), 'first envelope');
    expect(await otherProject.read(), 'second envelope');
  });

  test('canonicalizes equivalent HTTPS origins to the same storage key', () {
    expect(
      store(origin: 'https://API.EXAMPLE.TEST:443/').storageKey,
      store().storageKey,
    );
  });

  test('rejects invalid origin configuration without echoing its value', () {
    for (final origin in [
      'http://api.example.test',
      'https://private:sample-secret@api.example.test',
      'https://api.example.test/path',
      'https://api.example.test?token=sample-secret',
      'https://api.example.test#sample-secret',
    ]) {
      expect(
        () => store(origin: origin),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.toString(),
            'redacted description',
            isNot(contains('sample-secret')),
          ),
        ),
      );
    }
    expect(() => store(project: '  '), throwsArgumentError);
  });

  test('clear deletes only the scoped session key', () async {
    final first = store();
    final second = store(project: 'project-b');
    persisted['unrelated-application-entry'] = 'keep this';
    await first.write('first');
    await second.write('second');

    await first.clear();

    expect(persisted, {
      'unrelated-application-entry': 'keep this',
      second.storageKey: 'second',
    });
    expect(calls.last.method, 'delete');
    expect(calls.any((call) => call.method == 'deleteAll'), isFalse);
  });

  test('orders overlapping reads, writes and deletion', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'write' && _arguments(call)['value'] == 'first') {
            started.complete();
            await release.future;
          }
          return handleCall(call);
        });
    final subject = store();
    final firstWrite = subject.write('first');
    await started.future;
    final secondWrite = subject.write('second');
    final read = subject.read();
    final clear = subject.clear();

    expect(calls, isEmpty);
    release.complete();
    await firstWrite;
    await secondWrite;
    expect(await read, 'second');
    await clear;
    expect(persisted, isEmpty);
    expect(calls.map((call) => call.method), [
      'write',
      'write',
      'read',
      'delete',
    ]);
  });

  test(
    'Android defaults preserve errors and enable migration backup',
    () async {
      await store().write('envelope');
      final options =
          (_arguments(calls.single)['options'] as Map<Object?, Object?>)
              .cast<String, Object?>();

      expect(options['resetOnError'], 'false');
      expect(options['migrateWithBackup'], 'true');
    },
  );

  test(
    'iOS defaults do not sync and require this device to be unlocked',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await store().write('envelope');
      final options =
          (_arguments(calls.single)['options'] as Map<Object?, Object?>)
              .cast<String, Object?>();

      expect(options['accessibility'], 'unlocked_this_device');
      expect(options['synchronizable'], 'false');
    },
  );

  test('passes explicit application storage options to the plugin', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await store(
      storage: const FlutterSecureStorage(
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
          accountName: 'custom.application.service',
        ),
      ),
    ).read();
    final options =
        (_arguments(calls.single)['options'] as Map<Object?, Object?>)
            .cast<String, Object?>();

    expect(options['accessibility'], 'first_unlock_this_device');
    expect(options['accountName'], 'custom.application.service');
  });

  test(
    'redacts platform details and permits later operations after failure',
    () async {
      var fail = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (fail) {
              fail = false;
              throw PlatformException(
                code: 'Exception encountered',
                message: 'private envelope in native error',
                details: {'value': 'private envelope'},
              );
            }
            return handleCall(call);
          });
      final subject = store();
      await expectLater(
        subject.write('private envelope'),
        throwsA(
          isA<SecureSessionStoreException>()
              .having(
                (error) => error.operation,
                'operation',
                SecureSessionStoreOperation.write,
              )
              .having(
                (error) => error.failure,
                'failure',
                SecureSessionStoreFailure.platform,
              )
              .having(
                (error) => error.platformCode,
                'code',
                'Exception encountered',
              )
              .having(
                (error) => error.toString(),
                'description',
                isNot(contains('private')),
              ),
        ),
      );

      await subject.write('next envelope');
      expect(await subject.read(), 'next envelope');
    },
  );

  test(
    'read errors do not masquerade as a missing session or delete data',
    () async {
      final subject = store();
      persisted[subject.storageKey] = 'keep envelope';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'read') {
              throw PlatformException(code: 'device_locked');
            }
            return handleCall(call);
          });

      await expectLater(
        subject.read(),
        throwsA(
          isA<SecureSessionStoreException>().having(
            (error) => error.operation,
            'operation',
            SecureSessionStoreOperation.read,
          ),
        ),
      );
      expect(persisted[subject.storageKey], 'keep envelope');
      expect(calls, isEmpty);
    },
  );

  test(
    'clear failure is visible and does not report local logout success',
    () async {
      final subject = store();
      persisted[subject.storageKey] = 'keep envelope';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            throw PlatformException(code: 'device_locked');
          });

      await expectLater(
        subject.clear(),
        throwsA(
          isA<SecureSessionStoreException>().having(
            (error) => error.operation,
            'operation',
            SecureSessionStoreOperation.clear,
          ),
        ),
      );
      expect(persisted[subject.storageKey], 'keep envelope');
    },
  );

  test('does not retain unsafe platform error codes', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (_) async {
          throw PlatformException(code: 'secretValueInCode');
        });

    await expectLater(
      store().read(),
      throwsA(
        isA<SecureSessionStoreException>()
            .having((error) => error.platformCode, 'code', isNull)
            .having(
              (error) => error.toString(),
              'description',
              isNot(contains('secretValueInCode')),
            ),
      ),
    );
  });

  test('missing native plugin is an explicit unavailable failure', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);

    await expectLater(
      store().read(),
      throwsA(
        isA<SecureSessionStoreException>().having(
          (error) => error.failure,
          'failure',
          SecureSessionStoreFailure.unavailable,
        ),
      ),
    );
  });
}
