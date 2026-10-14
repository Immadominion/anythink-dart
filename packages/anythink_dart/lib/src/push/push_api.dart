import '../cancellation.dart';
import '../errors.dart';
import '../http/api_transport.dart';
import '../json.dart';
import 'models.dart';

/// Documented consumer push endpoints only. Does not configure providers,
/// render notifications, request OS permission or run background code.
///
/// Ordinary-user unregister/rebind is not documented. Account switching needs
/// backend coordination; no invented endpoint or administrator key is used.
final class PushApi {
  const PushApi(this._transport);
  final ApiTransport _transport;

  /// Registers for the signed-in user. A token owned by another user conflicts.
  Future<DeviceRegistration> registerDevice({
    required PushProvider provider,
    required String token,
    JsonObject metadata = const {},
    CancellationToken? cancellation,
  }) async {
    if (token.trim().isEmpty) {
      throw ArgumentError('A device token is required.');
    }
    final response = await _transport.request(
      'POST',
      ['push', 'devices'],
      body: {
        'provider': provider.value,
        'token': token,
        if (metadata.isNotEmpty) 'metadata': metadata,
      },
      cancellation: cancellation,
    );
    return DeviceRegistration.fromJson(
      objectFromJson(response.data, 'device registration'),
    );
  }

  /// Replaces synced actions of each named category. Coordinate IDs across app
  /// versions and grant anythink_tenant_push_categories:update explicitly.
  /// Does not register iOS categories or render Android action buttons.
  Future<void> syncCategories({
    required String appVersion,
    required List<PushCategory> categories,
    CancellationToken? cancellation,
  }) async {
    if (appVersion.trim().isEmpty || categories.isEmpty) {
      throw ArgumentError(
        'An app version and at least one category are required.',
      );
    }
    if (categories.map((c) => c.id).toSet().length != categories.length) {
      throw ArgumentError('Category IDs must be unique.');
    }
    await _transport.request(
      'POST',
      ['push', 'categories', 'sync'],
      body: {
        'app_version': appVersion,
        'categories': categories.map((c) => c.toJson()).toList(),
      },
      cancellation: cancellation,
    );
  }

  /// Uses the signed notification credential without a user bearer token.
  /// Backend deduplication covers notification/action pairs. Expired one-hour
  /// credentials fail; the SDK does not promise offline delivery.
  Future<PushActionResult> reportAction(
    PushActionEvent event, {
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'POST',
      ['push', 'action-events'],
      body: event.toJson(),
      authenticated: false,
      cancellation: cancellation,
    );
    return PushActionResult.fromJson(
      objectFromJson(response.data, 'push action result'),
    );
  }

  Future<String> vapidPublicKey({CancellationToken? cancellation}) async {
    final response = await _transport.request(
      'GET',
      ['push', 'vapid-public-key'],
      authenticated: false,
      cancellation: cancellation,
    );
    final body = objectFromJson(response.data, 'VAPID public key');
    final key = stringFromJson(body['public_key'], 'public_key');
    if (key.trim().isEmpty) {
      throw const ProtocolException('The VAPID public key is empty.');
    }
    return key;
  }
}
