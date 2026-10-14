import 'package:anythink_dart/anythink_dart.dart';
import 'package:test/test.dart';

import 'local_server.dart';

void main() {
  test('wire instants require a timezone and reject normalized overflow', () {
    final invalid = [
      '2026-02-31T10:00:00Z',
      '2026-02-29T10:00:00Z',
      '2026-00-01T10:00:00Z',
      '2026-01-00T10:00:00Z',
      '2026-01-01T24:00:00Z',
      '2026-01-01T10:60:00Z',
      '2026-01-01T10:00:60Z',
      '2026-01-01T10:00:00+24:00',
      '2026-01-01T10:00:00+01:60',
      '2026-01-01T10:00:00',
      '2026-01-01',
      '2026-01-01T10:00:00Z\n',
      'fixture-private-date-value',
    ];
    for (final timestamp in invalid) {
      final parsers = <void Function()>[
        () => SignedFileUrl.fromJson({
          'url': 'https://storage.invalid/file?signature=fixture-private-url',
          'expires_at': timestamp,
        }),
        () =>
            Entitlement.fromJson({'has_access': true, 'expires_at': timestamp}),
        () =>
            DeviceRegistration.fromJson({'id': 1, 'registered_at': timestamp}),
      ];
      for (final parse in parsers) {
        expect(
          parse,
          throwsA(
            isA<ProtocolException>().having(
              (error) => error.toString(),
              'redacted diagnostic',
              isNot(contains('fixture-private')),
            ),
          ),
        );
      }
    }
  });

  test(
    'wire dates retain UTC offsets, leap days and .NET fractional precision',
    () {
      final result = DeviceRegistration.fromJson({
        'id': 1,
        'registered_at': '2028-02-29T10:00:00.1234567+01:30',
      });
      expect(
        result.registeredAt,
        DateTime.utc(2028, 2, 29, 8, 30, 0, 123, 456),
      );
      expect(result.registeredAt.isUtc, true);
      expect(
        Entitlement.fromJson({
          'has_access': false,
          'expires_at': null,
        }).expiresAt,
        isNull,
      );
    },
  );

  test(
    'file and device responses reject invalid numeric identities and sizes',
    () {
      for (final id in [0, -1]) {
        expect(
          () => AnythinkFile.fromJson({'id': id}),
          throwsA(isA<ProtocolException>()),
        );
        expect(
          () => DeviceRegistration.fromJson({
            'id': id,
            'registered_at': '2026-10-14T00:00:00Z',
          }),
          throwsA(isA<ProtocolException>()),
        );
      }
      expect(
        () => AnythinkFile.fromJson({'id': 1, 'file_size': -1}),
        throwsA(isA<ProtocolException>()),
      );
      expect(AnythinkFile.fromJson({'id': 1, 'file_size': 0}).size, 0);
    },
  );

  test('bulk file result cannot claim contradictory successes', () {
    final examples = [
      {
        'successful_deletes': [1],
        'total_requested': 1,
        'total_deleted': 2,
      },
      {
        'successful_deletes': [1],
        'total_requested': -1,
        'total_deleted': 1,
      },
      {
        'successful_deletes': [-1],
        'total_requested': 1,
        'total_deleted': 1,
      },
      {
        'successful_deletes': [1, 1],
        'total_requested': 2,
        'total_deleted': 2,
      },
      {
        'successful_deletes': <int>[],
        'total_requested': 1,
        'total_deleted': -1,
      },
    ];
    for (final json in examples) {
      expect(
        () => FileDeleteResult.fromJson({...json, 'failed_deletes': []}),
        throwsA(isA<ProtocolException>()),
      );
    }
    final partial = FileDeleteResult.fromJson({
      'successful_deletes': [1],
      'failed_deletes': [
        {'future_failure_shape': true},
      ],
      'total_requested': 2,
      'total_deleted': 1,
    });
    expect(partial.totalDeleted, 1);
    expect(partial.failedDeletes.single, {'future_failure_shape': true});
  });

  test(
    'signed URL parsing rejects unsafe schemes and redacts rejected input',
    () {
      for (final url in [
        'http://storage.invalid/file?signature=fixture-private',
        'ftp://storage.invalid/file?signature=fixture-private',
        '//storage.invalid/file?signature=fixture-private',
        'https://user:fixture-private@storage.invalid/file',
        'https://storage.invalid/file#fixture-private',
        'https:///fixture-private',
      ]) {
        expect(
          () => SignedFileUrl.fromJson({
            'url': url,
            'expires_at': '2030-01-01T00:00:00Z',
          }),
          throwsA(
            isA<ProtocolException>().having(
              (error) => error.toString(),
              'redaction',
              isNot(contains('fixture-private')),
            ),
          ),
        );
      }
      final signed = SignedFileUrl.fromJson({
        'url': 'https://storage.invalid/file?signature=fixture-private',
        'expires_at': '2030-01-01T00:00:00Z',
      });
      expect(signed.toString(), isNot(contains('fixture-private')));
    },
  );

  test('incomplete Apple success cannot unlock a feature', () {
    final complete = <String, Object?>{
      'subscription_id': 'fixture-subscription',
      'bound_user_id': 3,
      'provider': 'apple',
      'product_id': 'fixture.product',
      'status': 'active',
      'has_access': true,
      'matched_known_plan': true,
    };
    for (final invalid in <Map<String, Object?>>[
      {'bound_user_id': 0},
      {'subscription_id': ''},
      {'provider': ' '},
      {'product_id': ''},
      {'status': ''},
    ]) {
      expect(
        () => AppleVerification.fromJson({...complete, ...invalid}),
        throwsA(isA<ProtocolException>()),
      );
    }
    expect(AppleVerification.fromJson(complete).hasKnownPlanAccess, true);
  });

  test(
    'malformed file dates and empty VAPID fail through real HTTP services',
    () async {
      final server = await LocalServer.start((request) async {
        if (request.uri.path.endsWith('/url')) {
          await respondJson(request, {
            'url': 'https://storage.invalid/blob?signature=fixture-private',
            'expires_at': '2026-02-31T10:00:00Z',
          });
        } else {
          await respondJson(request, {'public_key': ' '});
        }
      });
      final transport = server.transport();
      addTearDown(() async {
        transport.close();
        await server.close();
        expect(server.errors, isEmpty);
      });
      await expectLater(
        FilesApi(transport).signedUrl(1),
        throwsA(isA<ProtocolException>()),
      );
      await expectLater(
        PushApi(transport).vapidPublicKey(),
        throwsA(isA<ProtocolException>()),
      );
    },
  );
}
