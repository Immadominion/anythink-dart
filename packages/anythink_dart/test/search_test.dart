import 'dart:async';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:test/test.dart';

import 'auth_transport_support/local_api.dart';

void main() {
  late LocalApi api;
  late AnythinkClient client;

  Future<void> signIn([String account = 'a']) async {
    await client.auth.signInWithPassword(
      email: '$account@example.test',
      password: 'synthetic-search-test-password',
    );
  }

  setUp(() async {
    api = await LocalApi.start();
    api.handle = (request) {
      if (request.uri.path.endsWith('/token')) {
        final email =
            (request.body! as Map<String, Object?>)['email']! as String;
        return WireReply.json(_tokens(email.startsWith('b@') ? 'b' : 'a'));
      }
      if (request.uri.path.endsWith('/refresh')) {
        return WireReply.json(_tokens('renewed'));
      }
      if (request.uri.path.endsWith('/logout')) return WireReply.empty();
      return WireReply.json(_page());
    };
    client = AnythinkClient(
      apiOrigin: api.origin,
      projectId: 'search-tests',
      allowInsecureLocalhost: true,
    );
  });

  tearDown(() async {
    await client.close();
    await api.close();
    expect(api.handlerErrors, isEmpty);
  });

  test(
    'authenticated search sends its distinct query grammar and decodes hits',
    () async {
      await signIn();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/search')
          ? WireReply.json(
              _page(
                items: [
                  _hit(id: '001', title: 'Lagos & 東京'),
                  _hit(id: '9007199254740993', entity: 'products'),
                ],
                page: 2,
                pageSize: 10,
                totalItems: 25,
                totalPages: 3,
                facets: {
                  'status': {'draft': 1, 'published': 24},
                },
              ),
            )
          : original(request);

      final result = await client.search.query(
        query: SearchQuery(
          text: SearchText.field('title', 'Lagos & 東京'),
          entities: ['articles', 'products'],
          sort: [
            SearchSort.field(
              'created_at',
              direction: SearchSortDirection.descending,
            ),
            SearchSort.distance(latitude: 6.52, longitude: 3.38),
          ],
          filter: SearchFilter.expression(
            'status = "published news" AND id > 10',
          ),
          facets: ['status', 'category'],
          highlight: true,
          page: 2,
          pageSize: 10,
        ),
      );

      final request = api.at('/search').single;
      expect(request.method, 'GET');
      expect(request.uri.path, '/org/search-tests/search');
      expect(request.authorization, 'Bearer access-a');
      expect(request.body, isNull);
      expect(request.uri.queryParameters, {
        'q': 'title:Lagos & 東京',
        'e': 'articles,products',
        's': 'created_at:desc,_geoPoint(6.52, 3.38):asc',
        'fl': 'status = "published news" AND id > 10',
        'f': 'status,category',
        'hl': 'true',
        'page': '2',
        'pageSize': '10',
      });
      expect(result.items.map((item) => item.id), ['001', '9007199254740993']);
      expect(result.items.map((item) => item.entity), ['articles', 'products']);
      expect(result.items.first.name, 'Lagos & 東京');
      expect(result.items.first.decode((json) => json['title']), 'Lagos & 東京');
      expect(
        result.items.first.resourcePath,
        '/org/search-tests/entities/articles/items/001',
      );
      expect(
        result.items.first.untrustedFormatted!['title'],
        '<mark>Lagos</mark><img src=x onerror=alert(1)>',
      );
      expect(result.items.first.toString(), isNot(contains('Lagos')));
      expect(result.page, 2);
      expect(result.pageSize, 10);
      expect(result.totalItems, 25);
      expect(result.totalPages, 3);
      expect(result.hasNextPage, isTrue);
      expect(result.hasPreviousPage, isTrue);
      expect(result.retrievalTime, const Duration(microseconds: 1250));
      expect(result.facetDistribution, {
        'status': {'draft': 1, 'published': 24},
      });
      // RLS may reduce the number of items independently of pagination metadata.
      expect(result.items.length, lessThan(result.pageSize));
    },
  );

  test('public search sends no bearer or refresh on 401', () async {
    await signIn();
    final original = api.handle;
    var rejected = false;
    api.handle = (request) {
      if (request.uri.path.endsWith('/search/public')) {
        return rejected
            ? WireReply.json({'message': 'public route failure'}, status: 401)
            : WireReply.json(_page(items: [_publicHit()]));
      }
      return original(request);
    };
    final result = await client.search.queryPublic(
      query: SearchQuery(text: SearchText.text('public')),
    );
    expect(result.items.single.name, isNull);
    expect(result.items.single.data.containsKey('private_body'), isFalse);
    expect(api.at('/search/public').single.uri.queryParameters['hl'], isNull);
    expect(api.at('/search/public').single.authorization, isNull);
    expect(
      api.at('/search/public').single.headers.containsKey('cookie'),
      isFalse,
    );
    rejected = true;
    await expectLater(
      client.search.queryPublic(),
      throwsA(
        isA<ApiException>().having((error) => error.statusCode, 'status', 401),
      ),
    );
    expect(api.at('/refresh'), isEmpty);
    expect(client.auth.currentSession!.accessToken, 'access-a');
  });

  test('public highlights fail before network or session recovery', () async {
    await signIn();
    final countBefore = api.requests.length;
    await expectLater(
      client.search.queryPublic(query: SearchQuery(highlight: true)),
      throwsA(isA<UnsupportedError>()),
    );
    expect(api.requests.length, countBefore);
    expect(api.at('/search/public'), isEmpty);
    expect(api.at('/refresh'), isEmpty);
    expect(client.auth.currentSession!.accessToken, 'access-a');
  });

  test(
    'anonymous query works and omitted text differs from explicit wildcard',
    () async {
      final first = await client.search.queryPublic();
      expect(first.items, isEmpty);
      expect(first.totalPages, 0);
      expect(first.facetDistribution, isNull);
      expect(api.at('/search/public').last.uri.queryParameters, {
        'page': '1',
        'pageSize': '20',
      });
      await client.search.queryPublic(
        query: SearchQuery(text: const SearchText.all()),
      );
      expect(api.at('/search/public').last.uri.queryParameters['q'], '*');
      await expectLater(
        client.search.query(),
        throwsA(isA<AuthRequiredException>()),
      );
      expect(api.at('/search'), isEmpty);
    },
  );

  test(
    'similarity uses numeric source ID and preserves bare-list string result IDs',
    () async {
      await signIn();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/search/similar')
          ? WireReply.json([_hit(id: '003')])
          : original(request);
      final result = await client.search.similar(
        entity: 'articles',
        recordId: 1,
      );
      final request = api.at('/search/similar').single;
      expect(request.method, 'GET');
      expect(request.uri.path, '/org/search-tests/search/similar');
      expect(request.uri.queryParameters, {
        'e': 'articles',
        'id': '1',
        'limit': '10',
      });
      expect(request.authorization, 'Bearer access-a');
      expect(result.single.id, '003');
      expect(() => result.clear(), throwsUnsupportedError);

      await client.search.similar(
        entity: 'articles',
        recordId: 2147483647,
        limit: 125,
      );
      expect(
        api.at('/search/similar').last.uri.queryParameters['limit'],
        '125',
      );
      // Similarity has no documented 100-result limit; that is a page-size rule.
    },
  );

  test('unindexed similarity 404 is preserved without clearing auth', () async {
    await signIn();
    final original = api.handle;
    api.handle = (request) => request.uri.path.endsWith('/search/similar')
        ? WireReply.json({'title': 'Not Found'}, status: 404)
        : original(request);
    await expectLater(
      client.search.similar(entity: 'articles', recordId: 1),
      throwsA(
        isA<ApiException>().having((error) => error.statusCode, 'status', 404),
      ),
    );
    expect(api.at('/refresh'), isEmpty);
    expect(client.auth.currentSession!.accessToken, 'access-a');
  });

  test(
    'authenticated search retries one 401 with refreshed credentials',
    () async {
      await signIn();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/search')
          ? request.authorization == 'Bearer access-a'
                ? WireReply.json({'message': 'expired'}, status: 401)
                : WireReply.json(_page(items: [_hit()]))
          : original(request);
      expect((await client.search.query()).items.single.id, '1');
      expect(api.at('/search').map((request) => request.authorization), [
        'Bearer access-a',
        'Bearer access-renewed',
      ]);
      expect(api.at('/refresh').length, 1);
    },
  );

  test(
    'query collections snapshot inputs and reject ambiguous grammar before I/O',
    () async {
      final entities = ['articles'];
      final facets = ['status'];
      final sort = [SearchSort.field('id')];
      final query = SearchQuery(entities: entities, facets: facets, sort: sort);
      entities.add('products');
      facets.clear();
      sort.clear();
      expect(query.entities, ['articles']);
      expect(query.facets, ['status']);
      expect(query.sort.single.encoded, 'id:asc');
      expect(() => query.entities.add('changed'), throwsUnsupportedError);
      expect(
        () => query.toQueryParameters()['q'] = 'changed',
        throwsUnsupportedError,
      );

      final invalid = <Object Function()>[
        () => SearchQuery(page: 0),
        () => SearchQuery(page: 2147483648),
        () => SearchQuery(pageSize: 0),
        () => SearchQuery(pageSize: 101),
        () => SearchQuery(entities: ['articles,private']),
        () => SearchQuery(entities: ['articles', 'articles']),
        () => SearchQuery(facets: ['status', 'status']),
        () => SearchQuery(facets: ['status&hl=true']),
        () => SearchQuery(
          sort: [
            SearchSort.field('id'),
            SearchSort.field('id', direction: SearchSortDirection.descending),
          ],
        ),
        () => SearchText.text(''),
        () => SearchText.text('title:espresso'),
        () => SearchText.field('title', 'a:b'),
        () => SearchText.field('title,body', 'espresso'),
        () => SearchFilter.expression('   '),
        () => SearchSort.field('id:desc'),
        () => SearchSort.distance(latitude: double.nan, longitude: 0),
        () => SearchSort.distance(latitude: 91, longitude: 0),
        () => SearchSort.distance(latitude: 0, longitude: -181),
      ];
      for (final create in invalid) {
        expect(create, throwsArgumentError);
      }
      for (final id in [0, -1, 2147483648]) {
        await expectLater(
          client.search.similar(entity: 'articles', recordId: id),
          throwsArgumentError,
        );
      }
      for (final limit in [0, -1, 2147483648]) {
        await expectLater(
          client.search.similar(entity: 'articles', recordId: 1, limit: limit),
          throwsArgumentError,
        );
      }
      expect(api.requests, isEmpty);
    },
  );

  test('response maps and nested highlights are immutable snapshots', () {
    final source = _hit();
    final result = SearchPage.fromJson(
      _page(
        items: [source],
        facets: {
          'status': {'published': 2},
        },
      ),
    );
    (source['metadata']! as Map<String, Object?>)['tags'] = ['mutated'];
    (source['_formatted']! as Map<String, Object?>)['title'] = 'mutated';
    final hit = result.items.single;
    expect((hit.data['metadata']! as Map)['tags'], ['one']);
    expect(hit.untrustedFormatted!['title'], startsWith('<mark>'));
    expect(() => result.items.clear(), throwsUnsupportedError);
    expect(() => hit.data['title'] = 'changed', throwsUnsupportedError);
    expect(
      () => (hit.data['metadata']! as Map)['tags'] = <Object?>[],
      throwsUnsupportedError,
    );
    expect(
      () => ((hit.data['metadata']! as Map)['tags']! as List).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => hit.untrustedFormatted!['title'] = 'changed',
      throwsUnsupportedError,
    );
    expect(
      () => result.facetDistribution!['status']!['published'] = 0,
      throwsUnsupportedError,
    );
  });

  test(
    'public search decoders reject cycles with redacted protocol errors',
    () {
      final mapCycle = <String, Object?>{};
      mapCycle['private-search-value'] = mapCycle;
      final listCycle = <Object?>[];
      listCycle.add(listCycle);
      final mixedCycle = <String, Object?>{};
      mixedCycle['child'] = <Object?>[mixedCycle];

      for (final cycle in <Object>[mapCycle, listCycle, mixedCycle]) {
        final source = {..._hit(), 'metadata': cycle};
        final failure = throwsA(
          isA<ProtocolException>().having(
            (error) => error.toString(),
            'redacted error',
            isNot(contains('private-search-value')),
          ),
        );
        expect(() => SearchHit.fromJson(source), failure);
        expect(() => SearchPage.fromJson(_page(items: [source])), failure);
      }
    },
  );

  test('public search decoder rejects non-JSON values and wrong map keys', () {
    final malformed = <Object?>[
      <Object?, Object?>{7: 'private-search-value'},
      <Object?, Object?>{
        'nested': <Object?>['private-search-value'],
      },
      <Object?>{'private-search-value'},
      Object(),
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ];
    for (final value in malformed) {
      expect(
        () => SearchHit.fromJson({..._hit(), 'metadata': value}),
        throwsA(
          isA<ProtocolException>().having(
            (error) => error.toString(),
            'redacted error',
            isNot(contains('private-search-value')),
          ),
        ),
      );
    }
  });

  test('repeated noncyclic JSON references become immutable snapshots', () {
    final values = <Object?>[null, true, 7, 1.25, 'original'];
    final shared = <String, Object?>{'values': values};
    final hit = SearchHit.fromJson({
      ..._hit(),
      'metadata': <String, Object?>{'first': shared, 'second': shared},
      '_formatted': shared,
    });
    shared['added'] = 'later';
    values.clear();
    final metadata = hit.data['metadata']! as Map<String, Object?>;
    for (final snapshot in [
      metadata['first']! as Map<String, Object?>,
      metadata['second']! as Map<String, Object?>,
      hit.untrustedFormatted!,
    ]) {
      expect(snapshot, {
        'values': [null, true, 7, 1.25, 'original'],
      });
      expect(() => snapshot.clear(), throwsUnsupportedError);
      expect(
        () => (snapshot['values']! as List<Object?>).clear(),
        throwsUnsupportedError,
      );
    }
  });

  test(
    'malformed hit, facet and pagination responses produce protocol errors',
    () async {
      final malformed = <Object?>[
        [],
        {
          ..._page(),
          'items': ['not an object'],
        },
        _page(
          items: [
            {..._hit(), 'id': 1},
          ],
        ),
        _page(
          items: [
            {..._hit(), '__entity': ''},
          ],
        ),
        _page(
          items: [
            {..._hit(), '__url': null},
          ],
        ),
        _page(
          items: [
            {..._hit(), '_formatted': '<mark>bad shape</mark>'},
          ],
        ),
        _page(
          facets: {
            'status': {'published': -1},
          },
        ),
        _page(
          facets: {
            'status': {'published': 1.5},
          },
        ),
        _page(facets: {'status': 'not a count map'}),
        {..._page(), 'page': 0},
        {..._page(), 'has_next_page': 'false'},
      ];
      for (final data in malformed) {
        api.handle = (_) => WireReply.json(data);
        await expectLater(
          client.search.queryPublic(),
          throwsA(isA<ProtocolException>()),
        );
      }
      // The request cap is not used to reject a server's valid larger envelope.
      api.handle = (_) => WireReply.json(_page(pageSize: 101));
      expect((await client.search.queryPublic()).pageSize, 101);
    },
  );

  test(
    'similarity refuses a page envelope instead of silently treating it as a list',
    () async {
      await signIn();
      await expectLater(
        client.search.similar(entity: 'articles', recordId: 1),
        throwsA(isA<ProtocolException>()),
      );
    },
  );

  test(
    'old authenticated search results are fenced after account replacement',
    () async {
      await signIn();
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/search')
          ? release.future
          : original(request);
      final pending = client.search.query();
      final rejected = expectLater(
        pending,
        throwsA(isA<SessionChangedException>()),
      );
      await api.waitFor('/search');
      await signIn('b');
      release.complete(
        WireReply.json(_page(items: [_hit(title: 'account A only')])),
      );
      await rejected;
      expect(client.auth.currentSession!.accessToken, 'access-b');
    },
  );

  test(
    'public search survives account replacement because it carries no identity',
    () async {
      await signIn();
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/search/public')
          ? release.future
          : original(request);
      final pending = client.search.queryPublic();
      await api.waitFor('/search/public');
      await signIn('b');
      release.complete(WireReply.json(_page(items: [_publicHit()])));
      expect((await pending).items.single.id, '1');
      expect(api.at('/search/public').single.authorization, isNull);
    },
  );

  test(
    'cancelling one search aborts its wait without closing the reusable client',
    () async {
      final release = Completer<WireReply>();
      api.handle = (request) => request.uri.queryParameters['q'] == 'slow'
          ? release.future
          : WireReply.json(_page());
      final cancellation = CancellationToken();
      final pending = client.search.queryPublic(
        query: SearchQuery(text: SearchText.text('slow')),
        cancellation: cancellation,
      );
      final rejected = expectLater(
        pending,
        throwsA(
          isA<TransportException>()
              .having(
                (error) => error.failure,
                'failure',
                TransportFailure.cancelled,
              )
              .having(
                (error) => error.outcomeUncertain,
                'outcomeUncertain',
                isFalse,
              ),
        ),
      );
      await api.waitFor('/search/public');
      cancellation.cancel();
      await rejected;
      expect((await client.search.queryPublic()).items, isEmpty);
      release.complete(WireReply.json(_page()));
    },
  );
}

Map<String, Object?> _tokens(String suffix) => {
  'access_token': 'access-$suffix',
  'refresh_token': 'refresh-$suffix',
  'expires_in': 3600,
};

Map<String, Object?> _hit({
  String id = '1',
  String entity = 'articles',
  String title = 'Article',
}) => {
  'id': id,
  '__entity': entity,
  '__url': '/org/search-tests/entities/$entity/items/$id',
  '__name': title,
  'title': title,
  'private_body': 'signed-in record content',
  'metadata': <String, Object?>{
    'tags': <Object?>['one'],
  },
  '_formatted': <String, Object?>{
    'title': '<mark>Lagos</mark><img src=x onerror=alert(1)>',
  },
};

Map<String, Object?> _publicHit() => {
  'id': '1',
  '__entity': 'articles',
  '__url': '/org/search-tests/entities/articles/items/1',
  'title': 'Public article',
};

Map<String, Object?> _page({
  List<Object?> items = const [],
  int page = 1,
  int pageSize = 20,
  int totalItems = 0,
  int totalPages = 0,
  Object? facets,
}) => {
  'items': items,
  'page': page,
  'page_size': pageSize,
  'total_items': totalItems,
  'total_pages': totalPages,
  'has_next_page': page < totalPages,
  'has_previous_page': page > 1,
  'retrieval_time': 1.25,
  'facet_distribution': facets,
};
