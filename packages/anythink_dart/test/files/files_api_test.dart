import 'dart:async';
import 'dart:convert';

import 'package:anythink_dart/files.dart';
import 'package:anythink_dart/src/cancellation.dart';
import 'package:anythink_dart/src/errors.dart';
import 'package:test/test.dart';

import 'local_server.dart';

void main() {
  test('multipart upload streams source once and reports file bytes', () async {
    var calls = 0;
    final sourceBytes = utf8.encode('A streamed document with some bytes.');
    final server = await LocalServer.start((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/org/42/files');
      expect(request.uri.queryParameters, {
        'isPublic': 'false',
        'folderId': '3',
      });
      expect(request.headers.value('authorization'), 'Bearer fixture-access');
      expect(request.headers.contentType!.mimeType, 'multipart/form-data');
      final body = await utf8.decoder.bind(request).join();
      expect(body, contains('name="file"; filename="report.txt"'));
      expect(body, contains('content-type: text/plain'));
      expect(body, contains(utf8.decode(sourceBytes)));
      await respondJson(request, {
        'id': 7,
        'original_file_name': 'report.txt',
        'file_size': sourceBytes.length,
        'is_public': false,
      }, status: 201);
    });
    final transport = server.transport();
    addTearDown(() async {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    });
    final progress = <int>[];
    final result = await FilesApi(transport).upload(
      UploadSource(
        filename: 'report.txt',
        length: sourceBytes.length,
        contentType: 'text/plain',
        openRead: () {
          calls++;
          return Stream.fromIterable([
            sourceBytes.sublist(0, 10),
            sourceBytes.sublist(10),
          ]);
        },
      ),
      folderId: 3,
      onProgress: (count, total) {
        expect(total, sourceBytes.length);
        progress.add(count);
      },
    );
    expect(result.id, 7);
    expect(result.isPublic, false);
    expect(calls, 1);
    expect(progress, [0, 10, sourceBytes.length]);
  });

  test('multipart mutations are not replayed after unauthorized', () async {
    var requests = 0;
    var recovered = false;
    final server = await LocalServer.start((request) async {
      requests++;
      await request.drain<void>();
      await respondJson(request, {'title': 'Unauthorized'}, status: 401);
    });
    final transport = server.transport()
      ..recoverAccessToken = (_) async {
        recovered = true;
        return 'new-token';
      };
    addTearDown(() async {
      transport.close();
      await server.close();
      expect(server.errors, isEmpty);
    });
    await expectLater(
      FilesApi(transport).upload(
        UploadSource(
          filename: 'a.txt',
          length: 3,
          openRead: () => Stream.value([1, 2, 3]),
        ),
      ),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)),
    );
    expect(requests, 1);
    expect(recovered, false);
  });

  test(
    'cancellation before upload opens no byte source or connection',
    () async {
      var requests = 0;
      var opened = false;
      final server = await LocalServer.start((request) async {
        requests++;
        await request.response.close();
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      final cancel = CancellationToken()..cancel();
      await expectLater(
        FilesApi(transport).upload(
          UploadSource(
            filename: 'a.txt',
            length: 1,
            openRead: () {
              opened = true;
              return Stream.value([1]);
            },
          ),
          cancellation: cancel,
        ),
        throwsA(
          isA<TransportException>().having(
            (e) => e.failure,
            'failure',
            TransportFailure.cancelled,
          ),
        ),
      );
      expect(opened, false);
      expect(requests, 0);
    },
  );

  test(
    'cancel during streamed upload aborts before consuming the source',
    () async {
      var chunks = 0;
      final server = await LocalServer.start((request) async {
        await request.drain<void>();
        await respondJson(request, {'id': 1}, status: 201);
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      final cancel = CancellationToken();
      Stream<List<int>> source() async* {
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          chunks++;
          yield List.filled(1024, i);
        }
      }

      await expectLater(
        FilesApi(transport).upload(
          UploadSource(filename: 'large.bin', length: 102400, openRead: source),
          cancellation: cancel,
          onProgress: (sent, _) {
            if (sent >= 4096) cancel.cancel();
          },
        ),
        throwsA(
          isA<TransportException>().having(
            (e) => e.failure,
            'failure',
            TransportFailure.cancelled,
          ),
        ),
      );
      expect(chunks, lessThan(100));
    },
  );

  test('cancelling initial upload progress never opens the source', () async {
    var opened = false;
    final server = await LocalServer.start((request) async {
      await request.drain<void>();
      await respondJson(request, {'id': 1}, status: 201);
    });
    final transport = server.transport();
    addTearDown(() async {
      transport.close();
      await server.close();
    });
    final cancellation = CancellationToken();
    await expectLater(
      FilesApi(transport).upload(
        UploadSource(
          filename: 'private.txt',
          length: 1,
          openRead: () {
            opened = true;
            return Stream.value([1]);
          },
        ),
        cancellation: cancellation,
        onProgress: (_, _) => cancellation.cancel(),
      ),
      throwsA(
        isA<TransportException>().having(
          (error) => error.failure,
          'reason',
          TransportFailure.cancelled,
        ),
      ),
    );
    expect(opened, false);
  });

  test(
    'download resolves signed URL then streams with no API credentials',
    () async {
      final payload = utf8.encode('streamed private content');
      var downloaded = false;
      final storage = await LocalServer.start((request) async {
        downloaded = true;
        expect(request.uri.path, '/download');
        expect(request.uri.queryParameters['sig'], 'test-capability');
        expect(request.headers.value('authorization'), isNull);
        expect(request.headers.value('x-api-key'), isNull);
        request.response.contentLength = payload.length;
        request.response.add(payload.sublist(0, 7));
        await request.response.flush();
        request.response.add(payload.sublist(7));
        await request.response.close();
      });
      final server = await LocalServer.start((request) async {
        expect(request.uri.path, '/org/42/files/9/url');
        expect(request.headers.value('authorization'), 'Bearer fixture-access');
        await respondJson(request, {
          'url': '${storage.origin}/download?sig=test-capability',
          'expires_at': '2030-01-01T00:00:00Z',
        });
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        await storage.close();
        expect(server.errors, isEmpty);
        expect(storage.errors, isEmpty);
      });
      final progress = <int>[];
      final download = await FilesApi(transport).download(
        9,
        onProgress: (n, total) {
          progress.add(n);
          expect(total, payload.length);
        },
      );
      final bytes = await download.stream.expand((chunk) => chunk).toList();
      expect(downloaded, true);
      expect(bytes, payload);
      expect(progress.last, payload.length);
      expect(download.contentLength, payload.length);
    },
  );

  test(
    'file pagination and signed URL diagnostics preserve contract and secrecy',
    () async {
      final server = await LocalServer.start((request) async {
        expect(request.uri.queryParameters['search'], 'space & plus+');
        expect(request.uri.queryParameters['fileType'], 'document');
        expect(request.uri.queryParameters['pageSize'], '2');
        expect(request.uri.queryParameters['sortBy'], 'file_size');
        await respondJson(request, {
          'items': [
            {'id': 1, 'is_public': false},
          ],
          'page': 1,
          'page_size': 2,
          'total_items': 1,
          'total_pages': 1,
          'has_next_page': false,
          'has_previous_page': false,
        });
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      final page = await FilesApi(transport).list(
        pageSize: 2,
        search: 'space & plus+',
        category: FileCategory.document,
        sortBy: FileSortField.size,
      );
      expect(page.items.single.id, 1);
      final signed = SignedFileUrl.fromJson({
        'url': 'https://store.invalid/blob?sig=secret',
        'expires_at': '2030-01-01T00:00:00Z',
      });
      expect(signed.toString(), isNot(contains('secret')));
    },
  );

  test(
    'file metadata update and delete have precise wire operations',
    () async {
      final observed = <String>[];
      final server = await LocalServer.start((request) async {
        observed.add('${request.method} ${request.uri.path}');
        if (request.method == 'PUT') {
          expect(await readJson(request), {'alt_text': 'Accessible image'});
          await respondJson(request, null, status: 204);
        } else if (request.uri.path == '/org/42/files') {
          expect(await readJson(request), {
            'file_ids': [7, 8],
          });
          await respondJson(request, {
            'successful_deletes': [7],
            'failed_deletes': [
              {'id': 8},
            ],
            'total_requested': 2,
            'total_deleted': 1,
          });
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
      final files = FilesApi(transport);
      await files.update(7, {'alt_text': 'Accessible image'});
      await files.delete(7);
      final deletion = await files.deleteMany([7, 8]);
      expect(deletion.successfulDeletes, [7]);
      expect(deletion.failedDeletes, hasLength(1));
      expect(observed, [
        'PUT /org/42/files/7',
        'DELETE /org/42/files/7',
        'DELETE /org/42/files',
      ]);
    },
  );
  test('download stream stops when the owning session changes', () async {
    var generation = 0;
    final continueDownload = Completer<void>();
    final storage = await LocalServer.start((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = 65536;
      request.response.add(List.filled(32768, 1));
      await request.response.flush();
      await continueDownload.future;
      request.response.add(List.filled(32768, 2));
      await request.response.close();
    });
    final server = await LocalServer.start((request) async {
      await respondJson(request, {
        'url': '${storage.origin}/download',
        'expires_at': '2030-01-01T00:00:00Z',
      });
    });
    final transport = server.transport()..sessionGeneration = () => generation;
    addTearDown(() async {
      if (!continueDownload.isCompleted) continueDownload.complete();
      transport.close();
      await server.close();
      await storage.close();
      expect(server.errors, isEmpty);
      expect(storage.errors, isEmpty);
    });
    final download = await FilesApi(transport).download(
      4,
      onProgress: (bytes, _) {
        if (!continueDownload.isCompleted) {
          generation++;
          continueDownload.complete();
        }
      },
    );
    final exposed = <int>[];
    await expectLater(
      download.stream.map((chunk) {
        exposed.addAll(chunk);
        return chunk;
      }).drain<void>(),
      throwsA(isA<SessionChangedException>()),
    );
    expect(exposed, isEmpty);
  });

  test(
    'cancellation in download progress withholds the current chunk',
    () async {
      final cancellation = CancellationToken();
      final storage = await LocalServer.start((request) async {
        request.response.contentLength = 3;
        request.response.add([1, 2, 3]);
        await request.response.close();
      });
      final server = await LocalServer.start((request) async {
        await respondJson(request, {
          'url': '${storage.origin}/download',
          'expires_at': '2030-01-01T00:00:00Z',
        });
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        await storage.close();
        expect(server.errors, isEmpty);
        expect(storage.errors, isEmpty);
      });
      final download = await FilesApi(transport).download(
        1,
        cancellation: cancellation,
        onProgress: (_, _) => cancellation.cancel(),
      );
      final exposed = <int>[];
      await expectLater(
        download.stream.map((chunk) {
          exposed.addAll(chunk);
          return chunk;
        }).drain<void>(),
        throwsA(
          isA<TransportException>().having(
            (error) => error.failure,
            'reason',
            TransportFailure.cancelled,
          ),
        ),
      );
      expect(exposed, isEmpty);
    },
  );

  test(
    'invalid source length fails and upload metadata remains bounded',
    () async {
      final server = await LocalServer.start((request) async {
        await request.drain<void>();
        await respondJson(request, {'id': 1, 'large': 'x' * 500});
      });
      final transport = server.transport(maxResponseBytes: 100);
      addTearDown(() async {
        transport.close();
        await server.close();
      });
      final api = FilesApi(transport);
      await expectLater(
        api.upload(
          UploadSource(
            filename: 'small.txt',
            length: 1,
            openRead: () => Stream.value([1]),
          ),
        ),
        throwsA(isA<ProtocolException>()),
      );
      await expectLater(
        api.upload(
          UploadSource(
            filename: 'wrong.txt',
            length: 1,
            openRead: () => Stream.value([1, 2]),
          ),
        ),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
}
