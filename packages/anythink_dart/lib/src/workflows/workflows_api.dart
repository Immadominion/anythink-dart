import 'dart:convert';

import '../cancellation.dart';
import '../errors.dart';
import '../http/api_transport.dart';

/// Invokes configured workflows as the signed-in application user.
///
/// Both operations require `anythink_workflows:trigger` and return after the
/// server queues a job, not when its steps finish. No job ID, completion result,
/// polling, management permission, API key, or automatic retry is invented.
/// After a transport failure, reconcile before explicitly repeating a call.
final class WorkflowsApi {
  const WorkflowsApi(this._transport);
  final ApiTransport _transport;

  /// Queues an enabled API-route trigger. Routes are single path segments and
  /// matched case-insensitively by the server; this method preserves the input.
  ///
  /// [data] is a finite JSON value sent directly as the body. Null omits the
  /// body, which the server documents as empty trigger data. Optional [id] and
  /// [entityName] become the trigger's record ID and entity name.
  Future<void> triggerApi(
    String route, {
    Object? data,
    int? id,
    String? entityName,
    CancellationToken? cancellation,
  }) async {
    _name(route, 'route');
    if (id != null) _positiveId(id);
    if (entityName != null) _name(entityName, 'entity name');
    final body = _snapshot(data, Set<Object>.identity());
    final response = await _transport.request(
      'POST',
      ['workflows', 'api', route],
      query: {if (id != null) 'id': '$id', 'entity_name': ?entityName},
      body: body,
      cancellation: cancellation,
    );
    _queued(response);
  }

  /// Queues a workflow by ID. For a configured Manual trigger, [entityName]
  /// must be one of that trigger's entities; the server enforces that rule.
  /// Other trigger types can be invoked without an entity.
  ///
  /// [data] is encoded once into the endpoint's required JSON *string* field.
  /// Pass a JSON object/list/value, not a pre-encoded JSON document. Null omits
  /// that optional field. This is not the raw body used by [triggerApi].
  Future<void> trigger(
    int workflowId, {
    String? entityName,
    int? entityId,
    Object? data,
    CancellationToken? cancellation,
  }) async {
    _positiveId(workflowId);
    if (entityId != null) _positiveId(entityId);
    if (entityName != null) _name(entityName, 'entity name');
    final snapshot = _snapshot(data, Set<Object>.identity());
    final response = await _transport.request(
      'POST',
      ['workflows', '$workflowId', 'trigger'],
      body: {
        'entity_name': ?entityName,
        'entity_id': ?entityId,
        if (data != null) 'data': jsonEncode(snapshot),
      },
      cancellation: cancellation,
    );
    _queued(response);
  }
}

void _positiveId(int value) {
  if (value < 1) {
    throw ArgumentError('Workflow and record IDs must be positive.');
  }
}

void _name(String value, String field) {
  if (value.isEmpty ||
      value.trim() != value ||
      value == '.' ||
      value == '..' ||
      RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(value)) {
    throw ArgumentError('Workflow $field must be a nonempty single segment.');
  }
}

void _queued(ApiResponse response) {
  if (response.statusCode != 204) {
    throw const ProtocolException(
      'Workflow invocation did not return its documented queued acknowledgment.',
    );
  }
}

// Snapshot before asynchronous auth/storage work, and fail with a fixed error
// rather than a JsonUnsupportedObjectError that could print the private input.
Object? _snapshot(Object? value, Set<Object> ancestors) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List<Object?>) {
    if (!ancestors.add(value)) {
      throw ArgumentError('Workflow data cannot contain cyclic JSON.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((item) => _snapshot(item, ancestors)),
      );
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is Map<String, Object?>) {
    if (!ancestors.add(value)) {
      throw ArgumentError('Workflow data cannot contain cyclic JSON.');
    }
    try {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key: _snapshot(entry.value, ancestors),
      });
    } finally {
      ancestors.remove(value);
    }
  }
  throw ArgumentError('Workflow data must contain only finite JSON values.');
}
