import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';

/// Boundary around the native store. Inject it for tests or an alternative
/// StoreKit implementation; it never performs Anythink server verification.
abstract interface class ApplePurchaseStore {
  Stream<List<PurchaseDetails>> get updates;
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> products(Set<String> productIds);
  Future<bool> purchase(
    ProductDetails product, {
    required String appAccountToken,
  });
  Future<void> restore({required String appAccountToken});
  Future<void> complete(PurchaseDetails purchase);
}

/// The official Flutter in_app_purchase plugin with StoreKit 2 parameters.
/// StoreKit 1 receipts and Google Play purchases are not supported by this API.
final class StoreKitPurchaseStore implements ApplePurchaseStore {
  StoreKitPurchaseStore({InAppPurchase? purchases}) {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.macOS)) {
      throw UnsupportedError('Apple purchases require iOS or macOS.');
    }
    _purchases = purchases ?? InAppPurchase.instance;
  }

  late final InAppPurchase _purchases;

  @override
  Stream<List<PurchaseDetails>> get updates => _purchases.purchaseStream;
  @override
  Future<bool> isAvailable() => _purchases.isAvailable();
  @override
  Future<ProductDetailsResponse> products(Set<String> productIds) =>
      _purchases.queryProductDetails(productIds);
  @override
  Future<bool> purchase(
    ProductDetails product, {
    required String appAccountToken,
  }) {
    if (product is! AppStoreProduct2Details) {
      throw ArgumentError('Use a product returned by StoreKit 2.');
    }
    return _purchases.buyNonConsumable(
      purchaseParam: Sk2PurchaseParam(
        productDetails: product,
        applicationUserName: appAccountToken,
      ),
    );
  }

  @override
  Future<void> restore({required String appAccountToken}) =>
      _purchases.restorePurchases(applicationUserName: appAccountToken);
  @override
  Future<void> complete(PurchaseDetails purchase) {
    if (purchase is! SK2PurchaseDetails) {
      throw ArgumentError('Only StoreKit 2 transactions can be completed.');
    }
    return _purchases.completePurchase(purchase);
  }
}
