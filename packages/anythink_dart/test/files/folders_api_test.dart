import 'package:anythink_dart/anythink_dart.dart';
import 'package:test/test.dart';

import 'local_server.dart';

Map<String, Object?> folder(int id, {int? parent, int? user}) => {
  'id': id,
  'name': parent == null ? 'Documents' : 'Invoices',
  'parent_folder_id': parent,
  'user_id': user,
  'path': parent == null ? 'Documents' : 'Documents/Invoices',
  'file_count': parent == null ? 3 : 1,
  'sub_folder_count': parent == null ? 1 : 0,
};

void main() {
  test('folder raw metadata is a deep immutable snapshot', () {
    final nested = <String, Object?>{'label': 'original'};
    final unknown = <Object?>[nested];
    final folderJson = {...folder(5), 'unknown': unknown};
    final breadcrumbJson = <String, Object?>{
      'id': 5,
      'name': 'Documents',
      'unknown': unknown,
    };
    final children = <Object?>[folder(9, parent: 5)];
    final json = <String, Object?>{
      'folder': folderJson,
      'sub_folders': children,
      'breadcrumb': [breadcrumbJson],
    };
    final details = FileFolderDetails.fromJson(json);
    nested['label'] = 'changed';
    children.clear();
    folderJson['name'] = 'changed';
    breadcrumbJson['name'] = 'changed';
    expect(details.folder.name, 'Documents');
    expect(details.subFolders.single.id, 9);
    expect(details.breadcrumbs.single.name, 'Documents');
    final rawFolder = details.data['folder']! as JsonObject;
    expect(rawFolder['name'], 'Documents');
    expect(
      ((rawFolder['unknown']! as List).single as Map)['label'],
      'original',
    );
    expect(
      ((details.folder.data['unknown']! as List).single as Map)['label'],
      'original',
    );
    expect(
      ((details.breadcrumbs.single.data['unknown']! as List).single
          as Map)['label'],
      'original',
    );
    expect(
      () => (details.data['sub_folders']! as List).clear(),
      throwsUnsupportedError,
    );
    expect(
      () =>
          ((rawFolder['unknown']! as List).single as Map)['label'] = 'mutated',
      throwsUnsupportedError,
    );
  });

  test('folder metadata rejects cyclic and non-JSON raw values', () {
    final cycle = <Object?>[];
    cycle.add(cycle);
    for (final invalid in <Object?>[
      cycle,
      <int, String>{1: 'bad key'},
      DateTime.utc(2026),
      double.infinity,
    ]) {
      expect(
        () => FileFolder.fromJson({...folder(5), 'unknown': invalid}),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => FileFolderBreadcrumb.fromJson({
          'id': 5,
          'name': 'Documents',
          'unknown': invalid,
        }),
        throwsA(isA<ProtocolException>()),
      );
    }
  });

  test(
    'folder by ID decodes actual envelope and immutable breadcrumb rows',
    () async {
      final server = await LocalServer.start((request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/org/42/files/folders/5');
        expect(request.headers.value('authorization'), 'Bearer fixture-access');
        await respondJson(request, {
          'folder': {...folder(5), 'created_at': '2026-10-14T12:00:00Z'},
          'sub_folders': [folder(9, parent: 5)],
          'breadcrumb': [
            {'id': 5, 'name': 'Documents'},
          ],
          'future_field': true,
        });
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final detail = await FilesApi(transport).folders.get(5);
      expect(detail.folder.id, 5);
      expect(detail.folder.data['created_at'], '2026-10-14T12:00:00Z');
      expect(detail.subFolders.single.parentFolderId, 5);
      expect(detail.breadcrumbs.single.id, 5);
      expect(detail.breadcrumbs.single.name, 'Documents');
      expect(detail.data['future_field'], true);
      expect(() => detail.subFolders.clear(), throwsUnsupportedError);
      expect(() => detail.breadcrumbs.clear(), throwsUnsupportedError);
      expect(
        detail.breadcrumbs.single.toString(),
        isNot(contains('Documents')),
      );
    },
  );

  test(
    'folder by ID propagates denial and rejects incomplete envelopes',
    () async {
      var calls = 0;
      final server = await LocalServer.start((request) async {
        calls++;
        if (calls == 1) {
          await respondJson(request, null, status: 403);
        } else {
          await respondJson(request, {
            'folder': folder(5),
            'sub_folders': <Object?>[],
          });
        }
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      final api = FilesApi(transport).folders;
      await expectLater(
        api.get(5),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
      );
      await expectLater(api.get(5), throwsA(isA<ProtocolException>()));
      await expectLater(api.get(0), throwsArgumentError);
      await expectLater(
        api.get(5, cancellation: CancellationToken()..cancel()),
        throwsA(isA<TransportException>()),
      );
      expect(calls, 2);
    },
  );

  test('folder by ID retries authenticated read once after recovery', () async {
    var calls = 0;
    var recoveries = 0;
    final server = await LocalServer.start((request) async {
      calls++;
      if (calls == 1) {
        await respondJson(request, null, status: 401);
      } else {
        expect(
          request.headers.value('authorization'),
          'Bearer fixture-renewed',
        );
        await respondJson(request, {
          'folder': folder(5),
          'sub_folders': <Object?>[],
          'breadcrumb': [
            {'id': 5, 'name': 'Documents'},
          ],
        });
      }
    });
    final transport = server.transport()
      ..recoverAccessToken = (_) async {
        recoveries++;
        return 'fixture-renewed';
      };
    addTearDown(() async {
      transport.close();
      await server.close();
    });
    expect((await FilesApi(transport).folders.get(5)).folder.id, 5);
    expect(calls, 2);
    expect(recoveries, 1);
  });

  test(
    'folder list and flat tree use documented paths and retain metadata',
    () async {
      final paths = <String>[];
      final server = await LocalServer.start((request) async {
        expect(request.method, 'GET');
        expect(request.headers.value('authorization'), 'Bearer fixture-access');
        paths.add(request.uri.path);
        await respondJson(request, [
          folder(1),
          if (request.uri.path.endsWith('/tree'))
            {...folder(2, parent: 1, user: 5), 'future_field': true},
        ]);
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final api = FilesApi(transport).folders;
      final top = await api.list();
      final tree = await api.tree();
      expect(paths, ['/org/42/files/folders', '/org/42/files/folders/tree']);
      expect(top.single.parentFolderId, isNull);
      expect(top.single.fileCount, 3);
      expect(top.single.subFolderCount, 1);
      expect(tree.last.parentFolderId, 1);
      expect(tree.last.userId, 5);
      expect(tree.last.path, 'Documents/Invoices');
      expect(tree.last.data['future_field'], true);
      expect(() => tree.clear(), throwsUnsupportedError);
      expect(tree.last.toString(), isNot(contains('Invoices')));
    },
  );

  test(
    'folder mutations use exact bodies and require explicit content deletion',
    () async {
      final observations = <String>[];
      final server = await LocalServer.start((request) async {
        final path = '${request.method} ${request.uri}';
        observations.add(path);
        if (request.method == 'POST') {
          expect(await readJson(request), {'name': 'Folder & space'});
          // The mutation response shape is deliberately not required by the SDK.
          await respondJson(request, {
            'server_chosen_result': true,
          }, status: 201);
        } else if (request.method == 'PUT') {
          expect(
            await readJson(request),
            observations.length == 2
                ? {'name': 'Renamed'}
                : {'parent_folder_id': 7},
          );
          await respondJson(request, null, status: 204);
        } else {
          await respondJson(request, null, status: 204);
        }
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final api = FilesApi(transport).folders;
      await api.create('Folder & space');
      await api.rename(5, 'Renamed');
      await api.move(5, parentFolderId: 7);
      await api.delete(5);
      await api.delete(6, deleteContents: true);
      expect(observations, [
        'POST /org/42/files/folders',
        'PUT /org/42/files/folders/5',
        'PUT /org/42/files/folders/5',
        'DELETE /org/42/files/folders/5',
        'DELETE /org/42/files/folders/6?deleteContents=true',
      ]);
    },
  );

  test('folder reads recover auth once; writes never replay', () async {
    var reads = 0;
    var writes = 0;
    var recoveries = 0;
    final server = await LocalServer.start((request) async {
      if (request.method == 'GET') {
        reads++;
        if (reads == 1) {
          await respondJson(request, null, status: 401);
        } else {
          expect(
            request.headers.value('authorization'),
            'Bearer fixture-renewed',
          );
          await respondJson(request, [folder(1)]);
        }
      } else {
        writes++;
        await request.drain<void>();
        await respondJson(request, null, status: 401);
      }
    });
    final transport = server.transport()
      ..recoverAccessToken = (_) async {
        recoveries++;
        return 'fixture-renewed';
      };
    addTearDown(() async {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    });
    final api = FilesApi(transport).folders;
    expect(await api.list(), hasLength(1));
    await expectLater(api.create('Folder'), throwsA(isA<ApiException>()));
    expect(reads, 2);
    expect(writes, 1);
    expect(recoveries, 1);
  });

  test(
    'folder permission errors and malformed models do not become empty success',
    () async {
      var calls = 0;
      final server = await LocalServer.start((request) async {
        calls++;
        if (calls == 1) {
          await respondJson(request, null, status: 403);
        } else {
          await respondJson(request, [
            {...folder(1), 'file_count': -1},
          ]);
        }
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final api = FilesApi(transport).folders;
      await expectLater(
        api.list(),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
      );
      await expectLater(api.tree(), throwsA(isA<ProtocolException>()));
    },
  );

  test(
    'invalid folder input and cancelled work open no HTTP request',
    () async {
      var calls = 0;
      final server = await LocalServer.start((request) async {
        calls++;
        await request.response.close();
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      final api = FilesApi(transport).folders;
      await expectLater(api.create(' '), throwsArgumentError);
      await expectLater(api.rename(0, 'Name'), throwsArgumentError);
      await expectLater(api.move(1, parentFolderId: 0), throwsArgumentError);
      await expectLater(api.delete(-1), throwsArgumentError);
      final cancelled = CancellationToken()..cancel();
      await expectLater(
        api.tree(cancellation: cancelled),
        throwsA(isA<TransportException>()),
      );
      await expectLater(
        api.create('Name', cancellation: cancelled),
        throwsA(isA<TransportException>()),
      );
      expect(calls, 0);
    },
  );
}
