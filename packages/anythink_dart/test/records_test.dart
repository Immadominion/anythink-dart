import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anythink_dart/records.dart';
import 'package:anythink_dart/src/cancellation.dart';
import 'package:anythink_dart/src/errors.dart';
import 'package:anythink_dart/src/http/api_transport.dart';
import 'package:test/test.dart';

void main() {
  late _LocalApi api;
  late ApiTransport transport;
  late RecordService<_Order> records;

  setUp(() async {
    api = await _LocalApi.start();
    transport = ApiTransport(
      apiOrigin: api.origin,
      projectId: 'test-project',
      allowInsecureLocalhost: true,
    );
    transport.provideAccessToken = () async => 'test-access-token';
    transport.sessionGeneration = () => 0;
    records = RecordService(
      transport: transport,
      entity: 'orders',
      decode: _Order.fromJson,
    );
  });

  tearDown(() async {
    transport.close();
    await api.close();
  });

  test(
    'list sends the documented query and decodes typed page metadata',
    () async {
      api.respond = (_) => _Reply.json(
        _page(
          [
            {'id': 8, 'reference': 'A-8'},
          ],
          page: 2,
          pageSize: 10,
          totalItems: 21,
          totalPages: 3,
        ),
      );

      final result = await records.list(
        query: RecordQuery(
          page: 2,
          pageSize: 10,
          sortBy: 'total',
          sortDirection: SortDirection.descending,
          fields: FieldSelection(['reference', 'customer.email']),
          groupScope: 7,
          filters: [
            RecordFilter.equal('reference', FilterValue.text('Lagos & 東京')),
            RecordFilter.allOf([
              RecordFilter.greaterThanOrEqual(
                'total',
                FilterValue.decimal('10.25'),
              ),
              RecordFilter.lessThan('total', FilterValue.number(50)),
            ]),
            RecordFilter.oneOf('status', [
              FilterValue.text('paid'),
              FilterValue.text('shipped'),
            ]),
            RecordFilter.equal('paid', FilterValue.boolean(true)),
            RecordFilter.greaterThan(
              'placed_on',
              FilterValue.date(2026, 10, 14),
            ),
          ],
        ),
      );

      final request = api.requests.single;
      expect(request.method, 'GET');
      expect(request.uri.path, '/org/test-project/entities/orders/items');
      expect(request.authorization, 'Bearer test-access-token');
      expect(request.uri.queryParameters, {
        'page': '2',
        'pageSize': '10',
        'sortBy': 'total',
        'sortDirection': 'desc',
        'fields': 'reference,customer.email',
        'group_scope': '7',
        'reference': 'Lagos & 東京',
        'total': 'GTE:10.25,LT:50',
        'status': 'IN:paid,shipped',
        'paid': 'true',
        'placed_on': 'GT:2026-10-14',
      });
      expect(result.items.single.id, 8);
      expect(result.items.single.reference, 'A-8');
      expect(result.page, 2);
      expect(result.pageSize, 10);
      expect(result.totalItems, 21);
      expect(result.totalPages, 3);
      expect(result.hasNextPage, isTrue);
      expect(result.hasPreviousPage, isTrue);
      expect(result.retrievalTime, const Duration(microseconds: 1250));
      expect(() => result.items.clear(), throwsUnsupportedError);
    },
  );

  test('single reads apply fields and group scope', () async {
    api.respond = (_) => _Reply.json({'id': 7, 'reference': 'A-7'});

    final result = await records.get(
      7,
      fields: FieldSelection(['reference']),
      groupScope: 8,
    );

    expect(result.id, 7);
    expect(
      api.requests.single.uri.path,
      '/org/test-project/entities/orders/items/7',
    );
    expect(api.requests.single.uri.queryParameters, {
      'fields': 'reference',
      'group_scope': '8',
    });
  });

  test('create snapshots nested JSON before awaiting authentication', () async {
    final auth = Completer<String>();
    transport.provideAccessToken = () => auth.future;
    api.respond = (_) =>
        _Reply.json({'id': 9, 'reference': 'A-9'}, status: 201);
    final tags = <Object?>['original'];
    final properties = <String, Object?>{'': 'valid JSON key'};
    final values = <String, Object?>{
      'reference': 'A-9',
      'metadata': {'tags': tags, 'properties': properties},
      'optional': null,
    };

    final pending = records.create(values);
    tags.add('late mutation');
    properties[''] = 'late mutation';
    values['reference'] = 'changed';
    auth.complete('test-access-token');
    final result = await pending;

    expect(result.reference, 'A-9');
    expect(api.requests.single.method, 'POST');
    expect(api.requests.single.body, {
      'reference': 'A-9',
      'metadata': {
        'tags': ['original'],
        'properties': {'': 'valid JSON key'},
      },
      'optional': null,
    });
    expect(api.requests.single.contentType, contains('application/json'));
  });

  test(
    'create permits an empty object for entities with server defaults',
    () async {
      api.respond = (_) =>
          _Reply.json({'id': 9, 'reference': 'default'}, status: 201);
      await records.create({});
      expect(api.requests.single.body, <String, Object?>{});
    },
  );

  test(
    'bulk, import, partial update, delete and locking use exact routes',
    () async {
      api.respond = (request) => request.uri.path.endsWith('/bulk')
          ? _Reply.json([
              {'id': 9, 'reference': 'B-1'},
              {'id': 10, 'reference': 'B-2'},
            ])
          : const _Reply.empty();

      final result = await records.bulk([
        {'reference': 'B-1'},
        {'reference': 'B-2'},
      ]);
      expect(result.map((order) => order.id), [9, 10]);
      expect(() => result.clear(), throwsUnsupportedError);
      await records.importRecords([
        {'reference': 'C-1'},
      ]);
      await records.update(9, {'status': 'shipped'});
      await records.delete(10);
      await records.deleteMany([9, 12]);
      await records.setLockStatus(12, locked: true);
      await records.setLockStatus(12, locked: false);

      const base = '/org/test-project/entities/orders/items';
      expect(
        api.requests.map((request) => '${request.method} ${request.uri.path}'),
        [
          'POST $base/bulk',
          'POST $base/import',
          'PUT $base/9',
          'DELETE $base/10',
          'POST $base/delete-many',
          'POST $base/12/set-lock-status',
          'POST $base/12/set-lock-status',
        ],
      );
      expect(api.requests[0].body, [
        {'reference': 'B-1'},
        {'reference': 'B-2'},
      ]);
      expect(api.requests[1].body, [
        {'reference': 'C-1'},
      ]);
      expect(api.requests[2].body, {'status': 'shipped'});
      expect(api.requests[3].body, isNull);
      expect(api.requests[4].body, [9, 12]);
      expect(api.requests[5].uri.queryParameters, {'locked': 'true'});
      expect(api.requests[6].uri.queryParameters, {'locked': 'false'});
    },
  );

  test('public list and single reads never use session credentials', () async {
    transport.provideAccessToken = () =>
        throw StateError('must not read session');
    api.respond = (request) => request.uri.path.endsWith('/items')
        ? _Reply.json(
            _page([
              {'id': 1, 'reference': 'public'},
            ]),
          )
        : _Reply.json({'id': 1, 'reference': 'public'});

    final page = await records.listPublic(
      query: RecordQuery(filters: [RecordFilter.contains('reference', 'pub')]),
    );
    final item = await records.getPublic(
      1,
      fields: FieldSelection(['reference']),
    );

    expect(page.items.single.reference, 'public');
    expect(item.reference, 'public');
    expect(api.requests.map((request) => request.uri.path), [
      '/org/test-project/entities/orders/public/items',
      '/org/test-project/entities/orders/public/items/1',
    ]);
    expect(
      api.requests.every((request) => request.authorization == null),
      isTrue,
    );
    expect(api.requests[0].uri.queryParameters['reference'], 'C:pub');
    expect(api.requests[1].uri.queryParameters, {'fields': 'reference'});
  });

  test('authenticated reads may replay once after auth recovery', () async {
    var recoveries = 0;
    transport.recoverAccessToken = (rejected) async {
      expect(rejected, 'test-access-token');
      recoveries++;
      return 'new-test-access-token';
    };
    api.respond = (request) =>
        request.authorization == 'Bearer test-access-token'
        ? _Reply.json({'error': 'unauthorized'}, status: 401)
        : _Reply.json({'id': 1, 'reference': 'recovered'});

    expect((await records.get(1)).reference, 'recovered');
    expect(recoveries, 1);
    expect(api.requests.length, 2);
    expect(api.requests[1].authorization, 'Bearer new-test-access-token');
  });

  test('writes never replay on unauthorized responses', () async {
    var recoveries = 0;
    transport.recoverAccessToken = (_) async {
      recoveries++;
      return 'new-test-access-token';
    };
    api.respond = (_) => _Reply.json({'error': 'unauthorized'}, status: 401);
    final operations = <Future<Object?> Function()>[
      () => records.create({'reference': 'A-1'}),
      () => records.bulk([
        {'reference': 'A-1'},
      ]),
      () => records.importRecords([
        {'reference': 'A-1'},
      ]),
      () => records.update(1, {'reference': 'A-1'}),
      () => records.delete(1),
      () => records.deleteMany([1]),
      () => records.setLockStatus(1, locked: true),
    ];

    for (final operation in operations) {
      await expectLater(
        operation(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            401,
          ),
        ),
      );
    }
    expect(api.requests.length, operations.length);
    expect(recoveries, 0);
  });

  test(
    'public 401 does not recover auth and 404 remains an API failure',
    () async {
      transport.recoverAccessToken = (_) =>
          throw StateError('must not recover');
      api.respond = (_) => _Reply.json({'error': 'unauthorized'}, status: 401);
      await expectLater(
        records.getPublic(1),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            401,
          ),
        ),
      );
      expect(api.requests.length, 1);
      api.respond = (_) => _Reply.json({'error': 'not_found'}, status: 404);
      await expectLater(
        records.get(1),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            404,
          ),
        ),
      );
      expect(api.requests.length, 2);
    },
  );

  test(
    'malformed page or record bodies fail without fabricated data',
    () async {
      final malformed = <Object?>[
        [],
        {'items': <Object?>[]},
        {..._page([]), 'page': 0},
        {..._page([]), 'total_items': -1},
        {..._page([]), 'has_next_page': 'false'},
        {..._page([]), 'retrieval_time': 'quick'},
        {
          ..._page([]),
          'items': [true],
        },
      ];
      for (final response in malformed) {
        api.respond = (_) => _Reply.json(response);
        await expectLater(records.list(), throwsA(isA<ProtocolException>()));
      }
      api.respond = (_) => _Reply.json([]);
      await expectLater(records.get(1), throwsA(isA<ProtocolException>()));
      api.respond = (_) => _Reply.json({'id': 1});
      await expectLater(
        records.bulk([
          {'reference': 'A-1'},
        ]),
        throwsA(isA<ProtocolException>()),
      );
    },
  );

  test(
    'invalid writes fail before any request, including cyclic JSON',
    () async {
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      final badBodies = <JsonObject>[
        {'id': 7},
        {'created_at': '2026-10-14'},
        {'nested': double.nan},
        {
          'nested': [double.infinity],
        },
        {'nested': DateTime.utc(2026)},
        cyclic,
      ];
      for (final body in badBodies) {
        await expectLater(records.create(body), throwsArgumentError);
      }
      await expectLater(records.get(0), throwsArgumentError);
      await expectLater(records.get(1, groupScope: -1), throwsArgumentError);
      await expectLater(
        records.update(-1, {'status': 'paid'}),
        throwsArgumentError,
      );
      await expectLater(records.delete(0), throwsArgumentError);
      await expectLater(records.deleteMany([]), throwsArgumentError);
      await expectLater(records.deleteMany([1, 1]), throwsArgumentError);
      await expectLater(records.deleteMany([1, 0]), throwsArgumentError);
      await expectLater(records.bulk([]), throwsArgumentError);
      await expectLater(records.importRecords([]), throwsArgumentError);
      await expectLater(
        records.setLockStatus(0, locked: true),
        throwsArgumentError,
      );
      await expectLater(
        records.listPublic(query: RecordQuery(groupScope: 1)),
        throwsArgumentError,
      );
      expect(api.requests, isEmpty);
    },
  );

  test('cancellation reaches the real transport before a request', () async {
    final cancellation = CancellationToken()..cancel();
    await expectLater(
      records.list(cancellation: cancellation),
      throwsA(
        isA<TransportException>().having(
          (error) => error.failure,
          'failure',
          TransportFailure.cancelled,
        ),
      ),
    );
    expect(api.requests, isEmpty);
  });

  group('immutable query grammar', () {
    test('copies collections and prevents mutation of serialized options', () {
      final names = ['reference'];
      final fields = FieldSelection(names);
      final filters = [RecordFilter.equal('status', FilterValue.text('paid'))];
      final query = RecordQuery(fields: fields, filters: filters);
      names.add('total');
      filters.clear();
      expect(query.toQueryParameters()['fields'], 'reference');
      expect(query.toQueryParameters()['status'], 'paid');
      expect(() => query.filters.clear(), throwsUnsupportedError);
      expect(() => fields.fields.clear(), throwsUnsupportedError);
      expect(() => query.toQueryParameters().clear(), throwsUnsupportedError);
    });

    test('rejects reserved filters and unsupported literal escaping', () {
      for (final field in [
        'page',
        'PageSize',
        'sortBy',
        'sortDirection',
        'fields',
        'group_scope',
      ]) {
        expect(
          () => RecordFilter.equal(field, FilterValue.text('value')),
          throwsArgumentError,
        );
      }
      for (final value in [
        '',
        'a,b',
        '!important',
        'gt:5',
        'GTE:8',
        'C:literal',
        'IN:literal',
      ]) {
        expect(() => FilterValue.text(value), throwsArgumentError);
      }
      expect(
        () => RecordQuery(
          filters: [
            RecordFilter.equal('status', FilterValue.text('paid')),
            RecordFilter.notEqual('status', FilterValue.text('draft')),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => RecordFilter.allOf([
          RecordFilter.equal('total', FilterValue.number(10)),
          RecordFilter.lessThan('total', FilterValue.number(30)),
        ]),
        throwsArgumentError,
      );
      expect(
        () => RecordFilter.allOf([
          RecordFilter.greaterThan('a', FilterValue.number(10)),
          RecordFilter.lessThan('b', FilterValue.number(30)),
        ]),
        throwsArgumentError,
      );
      expect(() => RecordFilter.oneOf('status', []), throwsArgumentError);
    });

    test(
      'validates paging, projections, numeric values and calendar dates',
      () {
        expect(() => RecordQuery(page: 0), throwsArgumentError);
        expect(() => RecordQuery(pageSize: 0), throwsArgumentError);
        expect(() => RecordQuery(pageSize: 1001), throwsArgumentError);
        expect(() => RecordQuery(groupScope: 0), throwsArgumentError);
        expect(() => FieldSelection([]), throwsArgumentError);
        expect(() => FieldSelection(['*', 'reference']), throwsArgumentError);
        expect(
          () => FieldSelection(['reference', 'reference']),
          throwsArgumentError,
        );
        expect(() => FieldSelection(['customer..email']), throwsArgumentError);
        expect(() => FilterValue.number(double.infinity), throwsArgumentError);
        expect(() => FilterValue.date(2026, 2, 29), throwsArgumentError);
        expect(() => FilterValue.decimal('1,25'), throwsArgumentError);
        final query = RecordQuery(
          filters: [
            RecordFilter.equal('placed_on', FilterValue.date(2024, 2, 29)),
            RecordFilter.equal(
              'changed_at',
              FilterValue.timestamp(
                DateTime.parse('2026-10-14T11:00:00+01:00'),
              ),
            ),
            RecordFilter.equal(
              'amount',
              FilterValue.decimal('9007199254740993.01'),
            ),
          ],
        );
        expect(query.toQueryParameters()['placed_on'], '2024-02-29');
        expect(
          query.toQueryParameters()['changed_at'],
          '2026-10-14T10:00:00.000Z',
        );
        expect(query.toQueryParameters()['amount'], '9007199254740993.01');
      },
    );
  });
}

final class _Order {
  const _Order(this.id, this.reference);
  factory _Order.fromJson(JsonObject json) =>
      _Order(json['id'] as int, json['reference'] as String);
  final int id;
  final String reference;
}

JsonObject _page(
  List<JsonObject> items, {
  int page = 1,
  int pageSize = 25,
  int totalItems = 1,
  int totalPages = 1,
}) => {
  'items': items,
  'page': page,
  'page_size': pageSize,
  'total_items': totalItems,
  'total_pages': totalPages,
  'has_next_page': page < totalPages,
  'has_previous_page': page > 1,
  'retrieval_time': 1.25,
};

final class _RecordedRequest {
  const _RecordedRequest(
    this.method,
    this.uri,
    this.authorization,
    this.contentType,
    this.body,
  );
  final String method;
  final Uri uri;
  final String? authorization;
  final String? contentType;
  final Object? body;
}

final class _Reply {
  const _Reply.json(this.body, {this.status = 200});
  const _Reply.empty() : body = null, status = 204;
  final Object? body;
  final int status;
}

/// Serves actual TCP HTTP requests; no HTTP client or transport is mocked.
final class _LocalApi {
  _LocalApi(this._server) {
    _subscription = _server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final recorded = _RecordedRequest(
        request.method,
        request.uri,
        request.headers.value(HttpHeaders.authorizationHeader),
        request.headers.value(HttpHeaders.contentTypeHeader),
        body.isEmpty ? null : jsonDecode(body),
      );
      requests.add(recorded);
      final reply = respond(recorded);
      request.response.statusCode = reply.status;
      if (reply.status != 204) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(reply.body));
      }
      await request.response.close();
    });
  }

  static Future<_LocalApi> start() async =>
      _LocalApi(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final requests = <_RecordedRequest>[];
  _Reply Function(_RecordedRequest) respond = (_) => const _Reply.empty();
  Uri get origin => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}
