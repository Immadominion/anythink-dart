import 'package:anythink_dart/push.dart';
import 'package:anythink_dart/src/cancellation.dart';
import 'package:anythink_dart/src/errors.dart';
import 'package:test/test.dart';

import '../files/local_server.dart';

void main() {
  test(
    'register binds own token and uses documented provider strings',
    () async {
      final server = await LocalServer.start((request) async {
        expect(request.uri.path, '/org/42/push/devices');
        expect(request.headers.value('authorization'), 'Bearer fixture-access');
        expect(await readJson(request), {
          'provider': 'fcm',
          'token': 'fixture-device-token',
          'metadata': {'platform': 'ios'},
        });
        await respondJson(request, {
          'id': 21,
          'registered_at': '2026-10-14T00:00:00Z',
        });
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final result = await PushApi(transport).registerDevice(
        provider: PushProvider.fcm,
        token: 'fixture-device-token',
        metadata: {'platform': 'ios'},
      );
      expect(result.id, 21);
      expect(result.registeredAt.isUtc, true);
    },
  );

  test(
    'signed action reports without bearer even with signed-in transport',
    () async {
      var calls = 0;
      final event = PushActionEvent(
        notificationId: 'fixture-capability',
        category: 'reminder',
        actionId: 'done',
        receivedAt: DateTime.parse('2026-10-14T09:00:00+01:00'),
        data: {'note_id': '4'},
      );
      final server = await LocalServer.start((request) async {
        calls++;
        expect(request.uri.path, '/org/42/push/action-events');
        expect(request.headers.value('authorization'), isNull);
        expect(request.headers.value('x-api-key'), isNull);
        expect(await readJson(request), {
          'notification_id': 'fixture-capability',
          'category': 'reminder',
          'action_id': 'done',
          'received_at': '2026-10-14T08:00:00.000Z',
          'data': {'note_id': '4'},
        });
        await respondJson(
          request,
          calls == 1 ? {'received': true} : {'duplicate': true},
          status: 202,
        );
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final api = PushApi(transport);
      expect((await api.reportAction(event)).received, true);
      expect((await api.reportAction(event)).duplicate, true);
      expect(event.toString(), isNot(contains('fixture-capability')));
    },
  );

  test('expired action is not retried through user auth refresh', () async {
    var refreshes = 0;
    var requests = 0;
    final server = await LocalServer.start((request) async {
      requests++;
      await request.drain<void>();
      await respondJson(request, {
        'title': 'Expired notification',
      }, status: 401);
    });
    final transport = server.transport()
      ..recoverAccessToken = (_) async {
        refreshes++;
        return 'new';
      };
    addTearDown(() async {
      transport.close();
      await server.close();
    });
    await expectLater(
      PushApi(transport).reportAction(
        PushActionEvent(
          notificationId: 'expired-fixture',
          category: 'reminder',
          actionId: 'done',
        ),
      ),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
    );
    expect(requests, 1);
    expect(refreshes, 0);
  });

  test(
    'category sync sends explicit action definitions and validates uniqueness',
    () async {
      var count = 0;
      final category = PushCategory(
        id: 'reminder',
        actions: [PushActionButton(id: 'done', label: 'Done')],
      );
      final server = await LocalServer.start((request) async {
        count++;
        expect(request.uri.path, '/org/42/push/categories/sync');
        expect(await readJson(request), {
          'app_version': '0.1.0',
          'categories': [
            {
              'id': 'reminder',
              'actions': [
                {'id': 'done', 'label': 'Done'},
              ],
            },
          ],
        });
        await respondJson(request, [
          {'category': 'reminder'},
        ]);
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final api = PushApi(transport);
      await api.syncCategories(appVersion: '0.1.0', categories: [category]);
      await expectLater(
        api.syncCategories(
          appVersion: '0.1.0',
          categories: [category, category],
        ),
        throwsArgumentError,
      );
      expect(count, 1);
    },
  );

  test(
    'VAPID is public and pre-cancelled registration opens no request',
    () async {
      var count = 0;
      final server = await LocalServer.start((request) async {
        count++;
        expect(request.uri.path, '/org/42/push/vapid-public-key');
        expect(request.headers.value('authorization'), isNull);
        await respondJson(request, {'public_key': 'fixture-public-key'});
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final api = PushApi(transport);
      expect(await api.vapidPublicKey(), 'fixture-public-key');
      await expectLater(
        api.registerDevice(
          provider: PushProvider.fcm,
          token: 'test',
          cancellation: CancellationToken()..cancel(),
        ),
        throwsA(isA<TransportException>()),
      );
      expect(count, 1);
    },
  );
}
