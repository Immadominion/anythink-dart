import 'dart:convert';
import 'dart:io';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:test/test.dart';

import '../live_delete_guard.dart';

Future<void> exercise({
  required int deleteStatus,
  bool deleteActuallyRemoves = false,
  bool deleteChangesBody = false,
  Object? failure,
}) async {
  var exists = true;
  var body = 'owned synthetic body';
  var ownerReads = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.uri.path.endsWith('/auth/v1/token')) {
      final payload =
          jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'access_token': payload['email'] == 'a@test.invalid'
              ? 'synthetic-a'
              : 'synthetic-b',
          'refresh_token': 'synthetic-refresh',
          'expires_in': 1800,
        }),
      );
    } else if (request.method == 'DELETE') {
      expect(request.headers.value('authorization'), 'Bearer synthetic-b');
      if (deleteActuallyRemoves) exists = false;
      if (deleteChangesBody) body = 'wrongly modified';
      request.response.statusCode = deleteStatus;
    } else if (request.method == 'GET') {
      expect(request.headers.value('authorization'), 'Bearer synthetic-a');
      ownerReads++;
      if (exists) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'id': 7, 'title': 'owned synthetic title', 'body': body}),
        );
      } else {
        request.response.statusCode = 404;
      }
    } else {
      request.response.statusCode = 500;
    }
    await request.response.close();
  });
  final origin = Uri.parse('http://127.0.0.1:${server.port}');
  final observed = DeleteStatusHttpClient();
  final a = AnythinkClient(
    apiOrigin: origin,
    projectId: 'test',
    allowInsecureLocalhost: true,
  );
  final b = AnythinkClient(
    apiOrigin: origin,
    projectId: 'test',
    allowInsecureLocalhost: true,
    httpClient: observed,
    closeHttpClient: true,
  );
  addTearDown(() async {
    await a.close();
    await b.close();
    await server.close(force: true);
  });
  await a.auth.signInWithPassword(
    email: 'a@test.invalid',
    password: 'synthetic',
  );
  await b.auth.signInWithPassword(
    email: 'b@test.invalid',
    password: 'synthetic',
  );
  final guard = verifyDeleteIsolation(
    deleteAsOther: () async {
      await b.records('notes').delete(7);
      return observed.lastDeleteStatus;
    },
    verifyOwnerUnchanged: () async {
      final record = await a.records('notes').get(7);
      if (record['title'] != 'owned synthetic title' ||
          record['body'] != 'owned synthetic body') {
        throw StateError('Owner data changed.');
      }
    },
  );
  if (failure == null) {
    await guard;
    expect(
      ownerReads,
      1,
      reason: 'A response code alone never proves isolation.',
    );
  } else {
    await expectLater(guard, throwsA(failure));
  }
}

void main() {
  test('204 no-op passes only after unchanged owner read', () async {
    await exercise(deleteStatus: 204);
  });
  test('204 that deletes the owner record fails', () async {
    await exercise(
      deleteStatus: 204,
      deleteActuallyRemoves: true,
      failure: isA<ApiException>().having((e) => e.statusCode, 'status', 404),
    );
  });
  test('204 that modifies owner content fails', () async {
    await exercise(
      deleteStatus: 204,
      deleteChangesBody: true,
      failure: isA<StateError>(),
    );
  });
  for (final status in [403, 404]) {
    test('$status denial also requires unchanged owner read', () async {
      await exercise(deleteStatus: status);
    });
  }
  test('unexpected 200 success is not accepted', () async {
    await exercise(
      deleteStatus: 200,
      failure: isA<LiveDeleteIsolationFailure>(),
    );
  });
  test('unexpected server error cannot become isolation success', () async {
    await exercise(deleteStatus: 500, failure: isA<ApiException>());
  });
}
