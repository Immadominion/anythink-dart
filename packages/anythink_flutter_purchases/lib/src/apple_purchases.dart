import 'dart:async';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';

import 'apple_store.dart';

enum ApplePurchaseStatus { pending, purchased, restored, cancelled, failed }

enum ApplePurchaseFailure {
  storeUnavailable,
  storeFailure,
  unsupportedTransaction,
  invalidAccountIdentifier,
  accountMismatch,
  missingProof,
  invalidState,
  foreignUpdate,
  unknownPlan,
}

/// Native purchase failures expose no receipt, token or platform error payload.
final class ApplePurchaseException implements Exception {
  const ApplePurchaseException(this.reason);
  final ApplePurchaseFailure reason;
  @override
  String toString() => 'ApplePurchaseException(${reason.name})';
}

/// A snapshot of a store event, scoped to the account generation when observed.
/// A purchased/restored status is not proof of an Anythink entitlement.
final class ApplePurchaseUpdate {
  ApplePurchaseUpdate._(this._owner, this._details, this.generation)
    : productId = _details.productID,
      purchaseId = _details.purchaseID,
      status = switch (_details.status) {
        PurchaseStatus.pending => ApplePurchaseStatus.pending,
        PurchaseStatus.purchased => ApplePurchaseStatus.purchased,
        PurchaseStatus.restored => ApplePurchaseStatus.restored,
        PurchaseStatus.canceled => ApplePurchaseStatus.cancelled,
        PurchaseStatus.error => ApplePurchaseStatus.failed,
      },
      _isStoreKit2 = _details is SK2PurchaseDetails,
      _appAccountToken = _details is SK2PurchaseDetails
          ? _details.appAccountToken
          : null,
      _signedTransaction = _details.verificationData.serverVerificationData,
      _pendingCompletion = _details.pendingCompletePurchase;

  final Object _owner;
  final PurchaseDetails _details;
  final bool _isStoreKit2;
  final String? _appAccountToken;
  final String _signedTransaction;
  final bool _pendingCompletion;
  final String productId;
  final String? purchaseId;
  final ApplePurchaseStatus status;
  final int generation;
  bool get canVerify =>
      status == ApplePurchaseStatus.purchased ||
      status == ApplePurchaseStatus.restored;
  @override
  String toString() => 'ApplePurchaseUpdate(${status.name})';
}

/// A server verification result bound to one store event and one account.
/// Obtain this only from [AnythinkApplePurchases.verify]. It is not a permanent
/// entitlement cache: refresh `client.subscriptions.entitlement()` as needed.
final class VerifiedApplePurchase {
  VerifiedApplePurchase._(
    this._owner,
    this.update,
    this.verification,
    this._isCurrent,
  );
  final Object _owner;
  final ApplePurchaseUpdate update;
  final AppleVerification verification;
  final bool Function() _isCurrent;

  bool get isCurrentAccount => _isCurrent();
  bool get hasKnownPlanAccess =>
      isCurrentAccount && verification.hasKnownPlanAccess;
  @override
  String toString() =>
      'VerifiedApplePurchase(hasKnownPlanAccess: $hasKnownPlanAccess)';
}

/// Explicit three-stage purchase coordinator: listen to [updates], [verify]
/// purchased/restored events with Anythink, deliver access, then [complete].
///
/// Create one coordinator for the app's store stream and subscribe immediately.
/// Purchase launch, restore and completion never imply entitlement success.
/// No Google Play, StoreKit 1 receipt, or client-side signature verification is
/// guessed here. Configure App Store products and Anythink plans first.
final class AnythinkApplePurchases {
  AnythinkApplePurchases({
    required AnythinkClient client,
    ApplePurchaseStore? store,
  }) : _client = client,
       _store = store ?? StoreKitPurchaseStore() {
    _subscription = _store.updates.listen(
      (batch) {
        if (_closed) return;
        final generation = _client.auth.generation;
        for (final details in batch) {
          _updates.add(ApplePurchaseUpdate._(this, details, generation));
        }
      },
      onError: (Object _, StackTrace _) {
        if (!_closed) {
          _updates.addError(
            const ApplePurchaseException(ApplePurchaseFailure.storeFailure),
          );
        }
      },
    );
  }

  final AnythinkClient _client;
  final ApplePurchaseStore _store;
  final _updates = StreamController<ApplePurchaseUpdate>.broadcast();
  late final StreamSubscription<List<PurchaseDetails>> _subscription;
  final _verifications = <String, Future<VerifiedApplePurchase>>{};
  final _completions = <String, Future<void>>{};
  final _completed = <String>{};
  bool _closed = false;

  Stream<ApplePurchaseUpdate> get updates => _updates.stream;

  Future<bool> isAvailable() {
    _checkOpen();
    return _native(_store.isAvailable);
  }

  Future<ProductDetailsResponse> products(Set<String> productIds) {
    _checkOpen();
    if (productIds.isEmpty || productIds.any((id) => id.trim().isEmpty)) {
      throw ArgumentError('Supply nonempty App Store product identifiers.');
    }
    final snapshot = Set<String>.unmodifiable(productIds);
    return _native(() => _store.products(snapshot));
  }

  /// Starts a subscription/non-consumable purchase. True means the store flow
  /// started, not that the user paid or has access. Results arrive on [updates].
  Future<bool> purchase(ProductDetails product) async {
    _checkOpen();
    final generation = _client.auth.generation;
    final user = await _identity(generation);
    if (!await _native(_store.isAvailable)) {
      throw const ApplePurchaseException(ApplePurchaseFailure.storeUnavailable);
    }
    _checkGeneration(generation);
    final started = await _native(
      () => _store.purchase(product, appAccountToken: user.gid),
    );
    _checkGeneration(generation);
    return started;
  }

  /// Explicit user-requested App Store restore. Each restored event must still
  /// be verified; this future does not mean all event verification has finished.
  Future<void> restore() async {
    _checkOpen();
    final generation = _client.auth.generation;
    final user = await _identity(generation);
    await _native(() => _store.restore(appAccountToken: user.gid));
    _checkGeneration(generation);
  }

  /// Verifies the exact StoreKit 2 JWS. Concurrent attempts for the same event
  /// share one request. A failed verification never completes the transaction.
  ///
  /// Missing account tokens are refused unless this is a restored transaction
  /// and [allowLegacyUnboundRestore] is explicitly true. That opt-in permits
  /// Anythink's first-verify binding rule for older purchases without a token.
  Future<VerifiedApplePurchase> verify(
    ApplePurchaseUpdate update, {
    bool allowLegacyUnboundRestore = false,
  }) {
    _validateUpdate(update);
    if (!update.canVerify) {
      throw const ApplePurchaseException(ApplePurchaseFailure.invalidState);
    }
    // This opt-in belongs to each caller. A stricter caller must not inherit
    // another caller's permission by joining an already-running verification.
    if (update._isStoreKit2 &&
        (update._appAccountToken == null || update._appAccountToken.isEmpty) &&
        (!allowLegacyUnboundRestore ||
            update.status != ApplePurchaseStatus.restored)) {
      return Future.error(
        const ApplePurchaseException(ApplePurchaseFailure.accountMismatch),
      );
    }
    final key = _key(update);
    final existing = _verifications[key];
    if (existing != null) return existing;
    late final Future<VerifiedApplePurchase> operation;
    operation = _verify(update, allowLegacyUnboundRestore).whenComplete(() {
      if (identical(_verifications[key], operation)) _verifications.remove(key);
    });
    _verifications[key] = operation;
    return operation;
  }

  Future<VerifiedApplePurchase> _verify(
    ApplePurchaseUpdate update,
    bool allowLegacyUnboundRestore,
  ) async {
    if (!update.canVerify) {
      throw const ApplePurchaseException(ApplePurchaseFailure.invalidState);
    }
    if (!update._isStoreKit2) {
      throw const ApplePurchaseException(
        ApplePurchaseFailure.unsupportedTransaction,
      );
    }
    final user = await _identity(update.generation);
    final account = update._appAccountToken;
    if (account == null || account.isEmpty) {
      if (!allowLegacyUnboundRestore ||
          update.status != ApplePurchaseStatus.restored) {
        throw const ApplePurchaseException(
          ApplePurchaseFailure.accountMismatch,
        );
      }
    } else if (account.toLowerCase() != user.gid.toLowerCase()) {
      throw const ApplePurchaseException(ApplePurchaseFailure.accountMismatch);
    }
    final jws = update._signedTransaction;
    if (jws.isEmpty ||
        jws.trim() != jws ||
        jws.split('.').length != 3 ||
        jws.split('.').any((part) => part.isEmpty)) {
      throw const ApplePurchaseException(ApplePurchaseFailure.missingProof);
    }
    final verification = await _client.subscriptions.verifyApple(
      signedTransaction: jws,
    );
    _checkGeneration(update.generation);
    _validateBinding(verification, user);
    if (verification.productId != update.productId) {
      throw const ProtocolException(
        'Apple verification returned a different product.',
      );
    }
    return VerifiedApplePurchase._(
      this,
      update,
      verification,
      () =>
          !_closed &&
          _client.auth.generation == update.generation &&
          _hasUsableSession,
    );
  }

  /// Restores using an original transaction ID supplied by the app/server.
  /// Requires App Store Connect credentials configured in Anythink. A normal
  /// purchaseID is not assumed to be the original transaction ID. This does not
  /// finish a native transaction because it has no corresponding store event.
  Future<AppleVerification> restoreOriginalTransaction(
    String originalTransactionId,
  ) async {
    _checkOpen();
    if (!RegExp(r'^[0-9]+$').hasMatch(originalTransactionId)) {
      throw ArgumentError('Supply the original Apple transaction identifier.');
    }
    final generation = _client.auth.generation;
    final user = await _identity(generation);
    final result = await _client.subscriptions.verifyApple(
      originalTransactionId: originalTransactionId,
    );
    _checkGeneration(generation);
    _validateBinding(result, user);
    return result;
  }

  /// Finishes a verified native transaction after the app has handled delivery.
  /// Unknown-plan transactions remain unfinished so configuration can be fixed
  /// and verification retried. Completion is idempotent within this coordinator.
  Future<void> complete(VerifiedApplePurchase purchase) {
    _checkOpen();
    if (!identical(purchase._owner, this)) {
      throw const ApplePurchaseException(ApplePurchaseFailure.foreignUpdate);
    }
    _validateUpdate(purchase.update);
    if (!purchase.verification.matchedKnownPlan) {
      throw const ApplePurchaseException(ApplePurchaseFailure.unknownPlan);
    }
    final key = _key(purchase.update);
    if (_completed.contains(key)) return Future.value();
    final existing = _completions[key];
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _complete(purchase).whenComplete(() {
      if (identical(_completions[key], operation)) _completions.remove(key);
    });
    _completions[key] = operation;
    return operation;
  }

  Future<void> _complete(VerifiedApplePurchase purchase) async {
    final update = purchase.update;
    if (update._pendingCompletion) {
      await _native(() => _store.complete(update._details));
    }
    _checkGeneration(update.generation);
    _completed.add(_key(update));
  }

  Future<AnythinkUser> _identity(int generation) async {
    _checkGeneration(generation);
    final user = _client.auth.state.user ?? await _client.auth.getUser();
    _checkGeneration(generation);
    if (!RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(user.gid)) {
      throw const ApplePurchaseException(
        ApplePurchaseFailure.invalidAccountIdentifier,
      );
    }
    return user;
  }

  void _validateBinding(AppleVerification verification, AnythinkUser user) {
    if (verification.boundUserId != user.id ||
        verification.provider != 'apple') {
      throw const ProtocolException(
        'Apple verification did not match the signed-in account.',
      );
    }
  }

  String _key(ApplePurchaseUpdate update) {
    final id = update.purchaseId;
    if (id == null || id.isEmpty) {
      throw const ApplePurchaseException(ApplePurchaseFailure.missingProof);
    }
    return '${update.generation}:$id';
  }

  void _validateUpdate(ApplePurchaseUpdate update) {
    _checkOpen();
    if (!identical(update._owner, this)) {
      throw const ApplePurchaseException(ApplePurchaseFailure.foreignUpdate);
    }
    _checkGeneration(update.generation);
  }

  void _checkOpen() {
    if (_closed) throw const ClientClosedException();
  }

  Future<T> _native<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on ApplePurchaseException {
      rethrow;
    } catch (_) {
      // Native plugin exceptions can carry account identifiers or receipt
      // payloads. Core/backend calls are deliberately outside this boundary.
      throw const ApplePurchaseException(ApplePurchaseFailure.storeFailure);
    }
  }

  void _checkGeneration(int generation) {
    _checkOpen();
    if (_client.auth.generation != generation) {
      throw const SessionChangedException();
    }
    if (!_hasUsableSession) throw const AuthRequiredException();
  }

  // Refresh failure can invalidate authentication without changing identity
  // generation, and an uncertain rotation may retain the previous token pair.
  bool get _hasUsableSession =>
      _client.auth.currentSession != null &&
      _client.auth.state.status != AuthStatus.reauthenticationRequired;

  /// Stops observing native events; does not close the shared Anythink client,
  /// sign out, finish pending transactions, or cancel an already-open store UI.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _updates.close();
    _completed.clear();
  }
}
