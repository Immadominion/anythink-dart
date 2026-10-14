import 'dart:async';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:anythink_flutter_purchases/anythink_flutter_purchases.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';

import 'support/local_api.dart';

const _gid = '11111111-1111-4111-8111-111111111111';
const _otherGid = '22222222-2222-4222-8222-222222222222';

void main() {
  late LocalApi api;
  late AnythinkClient client;
  late _TestStore store;
  late AnythinkApplePurchases purchases;
  late StreamSubscription<ApplePurchaseUpdate> listener;
  late List<ApplePurchaseUpdate> updates;
  late StreamController<ApplePurchaseUpdate> observed;

  Future<void> signIn([String account = 'a']) async {
    await client.auth.signInWithPassword(
      email: '$account@example.test',
      password: 'test',
    );
    await client.auth.getUser();
  }

  Future<ApplePurchaseUpdate> emit(PurchaseDetails detail) async {
    final next = observed.stream.first;
    store.controller.add([detail]);
    return next;
  }

  setUp(() async {
    api = await LocalApi.start();
    api.handle = (request) {
      if (request.uri.path.endsWith('/token')) {
        final email = (request.body! as Map<String, Object?>)['email'];
        final account = email == 'b@example.test' ? 'b' : 'a';
        return WireReply.json({
          'access_token': 'access-$account',
          'refresh_token': 'refresh-$account',
          'expires_in': 3600,
        });
      }
      if (request.uri.path.endsWith('/users/me')) {
        final other = request.authorization == 'Bearer access-b';
        return WireReply.json({
          'id': other ? 2 : 1,
          'gid': other ? _otherGid : _gid,
        });
      }
      if (request.uri.path.endsWith('/apple/verify')) {
        return WireReply.json(_verification());
      }
      return WireReply.empty();
    };
    client = AnythinkClient(
      apiOrigin: api.origin,
      projectId: 'purchases-test',
      allowInsecureLocalhost: true,
    );
    store = _TestStore();
    purchases = AnythinkApplePurchases(client: client, store: store);
    updates = [];
    observed = StreamController<ApplePurchaseUpdate>.broadcast();
    listener = purchases.updates.listen((event) {
      updates.add(event);
      observed.add(event);
    });
    await signIn();
  });

  tearDown(() async {
    await listener.cancel();
    await observed.close();
    await purchases.close();
    await store.close();
    await client.close();
    await api.close();
    expect(api.handlerErrors, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'launch binds user GUID and does not claim verification or completion',
    () async {
      final product = ProductDetails(
        id: 'premium.monthly',
        title: 'Premium',
        description: 'Monthly',
        price: r'$5',
        rawPrice: 5,
        currencyCode: 'USD',
      );
      expect(await purchases.purchase(product), isTrue);
      expect(store.purchasedProduct, same(product));
      expect(store.accountToken, _gid);
      expect(api.at('/apple/verify'), isEmpty);
      expect(store.completed, isEmpty);
      expect(updates, isEmpty);
    },
  );

  test(
    'native events alone grant nothing; verification and completion are explicit',
    () async {
      final update = await emit(_purchase());
      expect(update.status, ApplePurchaseStatus.purchased);
      expect(api.at('/apple/verify'), isEmpty);
      expect(store.completed, isEmpty);
      final verified = await purchases.verify(update);
      expect(verified.hasKnownPlanAccess, isTrue);
      expect(api.at('/apple/verify').single.body, {
        'signed_transaction': 'header.payload.signature',
      });
      expect(api.at('/apple/verify').single.authorization, 'Bearer access-a');
      expect(store.completed, isEmpty);
      await purchases.complete(verified);
      await purchases.complete(verified);
      expect(store.completed, hasLength(1));
      expect(update.toString(), isNot(contains('payload')));
      expect(verified.toString(), isNot(contains('signature')));
    },
  );

  test('concurrent verification uses one backend call', () async {
    final update = await emit(_purchase());
    final release = Completer<WireReply>();
    final original = api.handle;
    api.handle = (request) => request.uri.path.endsWith('/apple/verify')
        ? release.future
        : original(request);
    final first = purchases.verify(update);
    final second = purchases.verify(update);
    await api.waitFor('/apple/verify');
    release.complete(WireReply.json(_verification()));
    final values = await Future.wait([first, second]);
    expect(values[0], same(values[1]));
    expect(api.at('/apple/verify'), hasLength(1));
  });

  test(
    'unknown backend plan cannot grant access or complete the purchase',
    () async {
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/apple/verify')
          ? WireReply.json({..._verification(), 'matched_known_plan': false})
          : original(request);
      final verified = await purchases.verify(await emit(_purchase()));
      expect(verified.verification.hasAccess, isTrue);
      expect(verified.hasKnownPlanAccess, isFalse);
      expect(
        () => purchases.complete(verified),
        throwsA(
          isA<ApplePurchaseException>().having(
            (error) => error.reason,
            'reason',
            ApplePurchaseFailure.unknownPlan,
          ),
        ),
      );
      expect(store.completed, isEmpty);
    },
  );

  test(
    'server rejection never completes and can be explicitly retried',
    () async {
      final update = await emit(_purchase());
      final original = api.handle;
      var reject = true;
      api.handle = (request) =>
          request.uri.path.endsWith('/apple/verify') && reject
          ? WireReply.json({'error': 'invalid_transaction'}, status: 403)
          : original(request);
      await expectLater(purchases.verify(update), throwsA(isA<ApiException>()));
      expect(store.completed, isEmpty);
      reject = false;
      expect((await purchases.verify(update)).hasKnownPlanAccess, isTrue);
      expect(api.at('/apple/verify'), hasLength(2));
    },
  );

  test(
    'mismatched appAccountToken and unsupported receipts never reach backend',
    () async {
      await expectLater(
        purchases.verify(await emit(_purchase(account: _otherGid))),
        throwsA(
          isA<ApplePurchaseException>().having(
            (error) => error.reason,
            'reason',
            ApplePurchaseFailure.accountMismatch,
          ),
        ),
      );
      final generic = PurchaseDetails(
        productID: 'premium.monthly',
        purchaseID: '123',
        verificationData: PurchaseVerificationData(
          localVerificationData: '',
          serverVerificationData: 'storekit-one-base64-receipt',
          source: 'app_store',
        ),
        transactionDate: null,
        status: PurchaseStatus.purchased,
      );
      await expectLater(
        purchases.verify(await emit(generic)),
        throwsA(
          isA<ApplePurchaseException>().having(
            (error) => error.reason,
            'reason',
            ApplePurchaseFailure.unsupportedTransaction,
          ),
        ),
      );
      await expectLater(
        purchases.verify(await emit(_purchase(jws: 'not-a-jws'))),
        throwsA(
          isA<ApplePurchaseException>().having(
            (error) => error.reason,
            'reason',
            ApplePurchaseFailure.missingProof,
          ),
        ),
      );
      expect(api.at('/apple/verify'), isEmpty);
    },
  );

  test(
    'legacy unbound restore requires explicit opt-in on a restored event',
    () async {
      final restored = await emit(
        _purchase(status: PurchaseStatus.restored, account: null),
      );
      await expectLater(
        purchases.verify(restored),
        throwsA(isA<ApplePurchaseException>()),
      );
      expect(
        (await purchases.verify(
          restored,
          allowLegacyUnboundRestore: true,
        )).hasKnownPlanAccess,
        isTrue,
      );
      final unboundNew = await emit(_purchase(account: null, id: '124'));
      await expectLater(
        purchases.verify(unboundNew, allowLegacyUnboundRestore: true),
        throwsA(isA<ApplePurchaseException>()),
      );
      expect(api.at('/apple/verify'), hasLength(1));
    },
  );

  test(
    'strict verification cannot inherit another callers legacy restore opt-in',
    () async {
      final restored = await emit(
        _purchase(status: PurchaseStatus.restored, account: null),
      );
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/apple/verify')
          ? release.future
          : original(request);
      final allowed = purchases.verify(
        restored,
        allowLegacyUnboundRestore: true,
      );
      await api.waitFor('/apple/verify');
      final strictRejected = expectLater(
        () => purchases.verify(restored),
        throwsA(
          isA<ApplePurchaseException>().having(
            (error) => error.reason,
            'reason',
            ApplePurchaseFailure.accountMismatch,
          ),
        ),
      );
      release.complete(WireReply.json(_verification()));
      await strictRejected;
      expect((await allowed).hasKnownPlanAccess, isTrue);
      expect(api.at('/apple/verify'), hasLength(1));
    },
  );

  test(
    'account replacement during verification prevents stale delivery',
    () async {
      final update = await emit(_purchase());
      final release = Completer<WireReply>();
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/apple/verify')
          ? release.future
          : original(request);
      final pending = purchases.verify(update);
      final stale = expectLater(
        pending,
        throwsA(isA<SessionChangedException>()),
      );
      await api.waitFor('/apple/verify');
      await signIn('b');
      release.complete(WireReply.json(_verification()));
      await stale;
      expect(store.completed, isEmpty);
    },
  );

  test(
    'logout invalidates a verified handle before native completion',
    () async {
      final verified = await purchases.verify(await emit(_purchase()));
      expect(verified.hasKnownPlanAccess, isTrue);
      await client.auth.signOut();
      expect(verified.hasKnownPlanAccess, isFalse);
      expect(
        () => purchases.complete(verified),
        throwsA(isA<SessionChangedException>()),
      );
      expect(store.completed, isEmpty);
    },
  );

  test('server account and product mismatches reject verification', () async {
    final original = api.handle;
    for (final wrong in [
      {..._verification(), 'bound_user_id': 2},
      {..._verification(), 'product_id': 'other.product'},
      {..._verification(), 'provider': 'stripe'},
    ]) {
      api.handle = (request) => request.uri.path.endsWith('/apple/verify')
          ? WireReply.json(wrong)
          : original(request);
      await expectLater(
        purchases.verify(await emit(_purchase())),
        throwsA(isA<ProtocolException>()),
      );
    }
    expect(store.completed, isEmpty);
  });

  for (final status in [401, 500]) {
    test(
      'refresh failure $status invalidates purchase access and actions',
      () async {
        final update = await emit(_purchase());
        final verified = await purchases.verify(update);
        final generation = client.auth.generation;
        final original = api.handle;
        api.handle = (request) => request.uri.path.endsWith('/refresh')
            ? WireReply.json({'error': 'refresh_failed'}, status: status)
            : original(request);

        await expectLater(
          client.auth.refreshSession(),
          throwsA(isA<ApiException>()),
        );
        expect(client.auth.generation, generation);
        expect(client.auth.state.status, AuthStatus.reauthenticationRequired);
        expect(verified.isCurrentAccount, isFalse);
        expect(verified.hasKnownPlanAccess, isFalse);

        final product = ProductDetails(
          id: 'premium.monthly',
          title: 'Premium',
          description: '',
          price: r'$5',
          rawPrice: 5,
          currencyCode: 'USD',
        );
        for (final operation in <Future<Object?> Function()>[
          () => purchases.purchase(product),
          purchases.restore,
          () => purchases.restoreOriginalTransaction('123'),
          () => purchases.verify(update),
          () => purchases.complete(verified),
        ]) {
          await expectLater(operation, throwsA(isA<AuthRequiredException>()));
        }
        expect(store.purchasedProduct, isNull);
        expect(store.restoreAccount, isNull);
        expect(store.completed, isEmpty);
        expect(api.at('/apple/verify'), hasLength(1));
      },
    );
  }

  test(
    'refresh failure during store availability prevents purchase launch',
    () async {
      final available = Completer<void>();
      store.availabilityGate = available.future;
      final product = ProductDetails(
        id: 'premium.monthly',
        title: 'Premium',
        description: '',
        price: r'$5',
        rawPrice: 5,
        currencyCode: 'USD',
      );
      final pending = purchases.purchase(product);
      final rejected = expectLater(
        pending,
        throwsA(isA<AuthRequiredException>()),
      );
      await store.availabilityStarted.future;
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/refresh')
          ? WireReply.json({'error': 'refresh_failed'}, status: 500)
          : original(request);
      await expectLater(
        client.auth.refreshSession(),
        throwsA(isA<ApiException>()),
      );
      available.complete();
      await rejected;
      expect(store.purchasedProduct, isNull);
    },
  );

  test(
    'restore and original transaction ID verification are separate operations',
    () async {
      await purchases.restore();
      expect(store.restoreAccount, _gid);
      expect(api.at('/apple/verify'), isEmpty);
      final verified = await purchases.restoreOriginalTransaction(
        '1000000123456789',
      );
      expect(verified.hasKnownPlanAccess, isTrue);
      expect(api.at('/apple/verify').single.body, {
        'original_transaction_id': '1000000123456789',
      });
      expect(store.completed, isEmpty);
      await expectLater(
        purchases.restoreOriginalTransaction('not-an-id'),
        throwsArgumentError,
      );
    },
  );

  test(
    'pending cancelled and failed events are observable but cannot verify',
    () async {
      for (final (status, expected) in [
        (PurchaseStatus.pending, ApplePurchaseStatus.pending),
        (PurchaseStatus.canceled, ApplePurchaseStatus.cancelled),
        (PurchaseStatus.error, ApplePurchaseStatus.failed),
      ]) {
        final update = await emit(_purchase(status: status));
        expect(update.status, expected);
        expect(update.canVerify, isFalse);
        expect(
          () => purchases.verify(update),
          throwsA(
            isA<ApplePurchaseException>().having(
              (error) => error.reason,
              'reason',
              ApplePurchaseFailure.invalidState,
            ),
          ),
        );
      }
      expect(api.at('/apple/verify'), isEmpty);
    },
  );

  test(
    'completion failure can retry without duplicate concurrent finishes',
    () async {
      final verified = await purchases.verify(await emit(_purchase()));
      store.failCompletion = true;
      await expectLater(
        purchases.complete(verified),
        throwsA(
          isA<ApplePurchaseException>().having(
            (error) => error.reason,
            'failure',
            ApplePurchaseFailure.storeFailure,
          ),
        ),
      );
      store.failCompletion = false;
      final release = Completer<void>();
      store.completionGate = release.future;
      final first = purchases.complete(verified);
      final second = purchases.complete(verified);
      release.complete();
      await Future.wait([first, second]);
      expect(store.completed, hasLength(1));
    },
  );

  test(
    'all native operation throws are redacted without hiding core errors',
    () async {
      final product = ProductDetails(
        id: 'premium.monthly',
        title: 'Premium',
        description: '',
        price: r'$5',
        rawPrice: 5,
        currencyCode: 'USD',
      );
      final verified = await purchases.verify(await emit(_purchase()));
      final operations = <String, Future<Object?> Function()>{
        'availability': purchases.isAvailable,
        'products': () => purchases.products({'premium.monthly'}),
        'purchase': () => purchases.purchase(product),
        'restore': purchases.restore,
        'complete': () => purchases.complete(verified),
      };
      for (final entry in operations.entries) {
        store.failureMethod = entry.key;
        await expectLater(
          entry.value(),
          throwsA(
            isA<ApplePurchaseException>()
                .having(
                  (error) => error.reason,
                  'failure',
                  ApplePurchaseFailure.storeFailure,
                )
                .having(
                  (error) => error.toString(),
                  'redacted diagnostics',
                  isNot(contains('private-native-payload')),
                ),
          ),
        );
      }
      store.failureMethod = null;
      await client.auth.signOut();
      await expectLater(
        purchases.purchase(product),
        throwsA(isA<AuthRequiredException>()),
      );
      expect(store.completed, isEmpty);
    },
  );

  test(
    'unavailable store and malformed user GUID fail before purchase launch',
    () async {
      final product = ProductDetails(
        id: 'premium.monthly',
        title: 'Premium',
        description: '',
        price: r'$5',
        rawPrice: 5,
        currencyCode: 'USD',
      );
      store.available = false;
      await expectLater(
        purchases.purchase(product),
        throwsA(
          isA<ApplePurchaseException>().having(
            (error) => error.reason,
            'reason',
            ApplePurchaseFailure.storeUnavailable,
          ),
        ),
      );
      store.available = true;
      final original = api.handle;
      api.handle = (request) => request.uri.path.endsWith('/users/me')
          ? WireReply.json({'id': 1, 'gid': 'invalid-account-guid'})
          : original(request);
      await client.auth.getUser();
      await expectLater(
        purchases.purchase(product),
        throwsA(
          isA<ApplePurchaseException>().having(
            (error) => error.reason,
            'reason',
            ApplePurchaseFailure.invalidAccountIdentifier,
          ),
        ),
      );
      expect(store.purchasedProduct, isNull);
    },
  );

  test(
    'default native store rejects Android instead of inventing Play verification',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(StoreKitPurchaseStore.new, throwsUnsupportedError);
    },
  );

  test(
    'closing coordinator invalidates handles but leaves shared client alive',
    () async {
      final verified = await purchases.verify(await emit(_purchase()));
      await purchases.close();
      expect(verified.hasKnownPlanAccess, isFalse);
      expect(
        () => purchases.complete(verified),
        throwsA(isA<ClientClosedException>()),
      );
      expect((await client.auth.getUser()).id, 1);
    },
  );
}

Map<String, Object?> _verification() => {
  'subscription_id': 'sub-1',
  'bound_user_id': 1,
  'provider': 'apple',
  'product_id': 'premium.monthly',
  'plan_name': 'Premium',
  'plan_id': 1,
  'status': 'active',
  'expires_at': '2030-01-01T00:00:00Z',
  'has_access': true,
  'matched_known_plan': true,
};

SK2PurchaseDetails _purchase({
  String id = '123',
  String? account = _gid,
  String jws = 'header.payload.signature',
  PurchaseStatus status = PurchaseStatus.purchased,
}) => SK2PurchaseDetails(
  productID: 'premium.monthly',
  purchaseID: id,
  verificationData: PurchaseVerificationData(
    localVerificationData: '',
    serverVerificationData: jws,
    source: 'app_store',
  ),
  transactionDate: '1791979200000',
  status: status,
  appAccountToken: account,
);

/// Test-only native boundary. The backend client still sends real local HTTP.
final class _TestStore implements ApplePurchaseStore {
  final controller = StreamController<List<PurchaseDetails>>.broadcast();
  bool available = true;
  ProductDetails? purchasedProduct;
  String? accountToken;
  String? restoreAccount;
  final completed = <PurchaseDetails>[];
  bool failCompletion = false;
  String? failureMethod;
  Future<void>? completionGate;
  Future<void>? availabilityGate;
  final availabilityStarted = Completer<void>();
  Future<void> close() => controller.close();
  @override
  Stream<List<PurchaseDetails>> get updates => controller.stream;
  @override
  Future<bool> isAvailable() async {
    _fail('availability');
    if (!availabilityStarted.isCompleted) availabilityStarted.complete();
    await availabilityGate;
    return available;
  }

  @override
  Future<ProductDetailsResponse> products(Set<String> productIds) async {
    _fail('products');
    return ProductDetailsResponse(
      productDetails: [],
      notFoundIDs: productIds.toList(),
    );
  }

  @override
  Future<bool> purchase(
    ProductDetails product, {
    required String appAccountToken,
  }) async {
    _fail('purchase');
    purchasedProduct = product;
    accountToken = appAccountToken;
    return true;
  }

  @override
  Future<void> restore({required String appAccountToken}) async {
    _fail('restore');
    restoreAccount = appAccountToken;
  }

  @override
  Future<void> complete(PurchaseDetails purchase) async {
    _fail('complete');
    if (failCompletion) throw StateError('Injected native completion failure');
    await completionGate;
    completed.add(purchase);
  }

  void _fail(String method) {
    if (failureMethod == method) throw StateError('private-native-payload');
  }
}
