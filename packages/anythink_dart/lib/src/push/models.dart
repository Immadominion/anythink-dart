import '../errors.dart';
import '../json.dart';
import '../wire_timestamp.dart';

enum PushProvider {
  fcm('fcm'),
  webPush('web_push');

  const PushProvider(this.value);
  final String value;
}

final class DeviceRegistration {
  DeviceRegistration.fromJson(JsonObject json)
    : id = intFromJson(json['id'], 'device.id'),
      registeredAt = timestampFromJson(json['registered_at'], 'registered_at') {
    if (id < 1) {
      throw const ProtocolException('Invalid device registration ID.');
    }
  }
  final int id;
  final DateTime registeredAt;
}

/// Native notification categories must also be registered on the device.
final class PushCategory {
  PushCategory({required this.id, required List<PushActionButton> actions})
    : actions = List.unmodifiable(actions) {
    _nonEmpty(id, 'category id');
    if (actions.isEmpty) {
      throw ArgumentError('At least one action is required.');
    }
    if (actions.map((a) => a.id).toSet().length != actions.length) {
      throw ArgumentError('Action IDs must be unique within a category.');
    }
  }
  final String id;
  final List<PushActionButton> actions;
  JsonObject toJson() => {
    'id': id,
    'actions': actions.map((a) => a.toJson()).toList(),
  };
}

final class PushActionButton {
  PushActionButton({required this.id, required this.label}) {
    _nonEmpty(id, 'action id');
    _nonEmpty(label, 'action label');
  }
  final String id;
  final String label;
  JsonObject toJson() => {'id': id, 'label': label};
}

/// A notification action credential expires one hour after its send. Keep it
/// private; it can authorize a workflow without a signed-in user session.
final class PushActionEvent {
  PushActionEvent({
    required this.notificationId,
    required this.category,
    required this.actionId,
    this.receivedAt,
    this.respondedAt,
    JsonObject data = const {},
  }) : data = Map.unmodifiable(data) {
    _nonEmpty(notificationId, 'notification credential');
    _nonEmpty(category, 'category');
    _nonEmpty(actionId, 'action id');
  }
  final String notificationId;
  final String category;
  final String actionId;
  final DateTime? receivedAt;
  final DateTime? respondedAt;
  final JsonObject data;
  JsonObject toJson() => {
    'notification_id': notificationId,
    'category': category,
    'action_id': actionId,
    if (receivedAt != null)
      'received_at': receivedAt!.toUtc().toIso8601String(),
    if (respondedAt != null)
      'responded_at': respondedAt!.toUtc().toIso8601String(),
    if (data.isNotEmpty) 'data': data,
  };
  @override
  String toString() => 'PushActionEvent(credential: [redacted])';
}

final class PushActionResult {
  PushActionResult.fromJson(JsonObject json)
    : received = json['received'] == null
          ? false
          : boolFromJson(json['received'], 'received'),
      duplicate = json['duplicate'] == null
          ? false
          : boolFromJson(json['duplicate'], 'duplicate') {
    if (!received && !duplicate) {
      throw const ProtocolException(
        'The push action response did not confirm receipt.',
      );
    }
  }

  /// Receipt is not proof of successful workflow completion or device delivery.
  final bool received;

  /// This action was already reported; the backend did not start it again.
  final bool duplicate;
}

void _nonEmpty(String value, String field) {
  if (value.trim().isEmpty) {
    throw ArgumentError('A non-empty $field is required.');
  }
}
