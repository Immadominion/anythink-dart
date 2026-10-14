import '../cancellation.dart';
import '../http/api_transport.dart';
import '../json.dart';
import 'page.dart';
import 'query.dart';

/// All documented CRUD, bulk, import, locking and public-read operations for
/// one Anythink entity. The decoder defines the application's own record model.
///
/// Writes are never automatically retried. Updates return no body; fetch the
/// record separately if the new server values are needed. Filters cannot replace
/// server permissions or row-level security.
final class RecordService<T> {
  RecordService({
    required ApiTransport transport,
    required this.entity,
    required RecordDecoder<T> decode,
  }) : _transport = transport,
       _decode = decode {
    if (entity.isEmpty ||
        entity.trim() != entity ||
        entity == '.' ||
        entity == '..' ||
        RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(entity)) {
      throw ArgumentError('Entity must be a nonempty entity name.');
    }
  }

  final ApiTransport _transport;
  final RecordDecoder<T> _decode;
  final String entity;
  List<String> get _path => ['entities', entity, 'items'];
  List<String> get _publicPath => ['entities', entity, 'public', 'items'];

  Future<Page<T>> list({
    RecordQuery? query,
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.request(
      'GET',
      _path,
      query: (query ?? RecordQuery()).toQueryParameters(),
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return Page<T>.fromJson(response.data, _decode);
  }

  Future<T> get(
    int id, {
    FieldSelection? fields,
    int? groupScope,
    CancellationToken? cancellation,
  }) async {
    _validateId(id);
    if (groupScope != null) _validateId(groupScope);
    final response = await _transport.request(
      'GET',
      [..._path, '$id'],
      query: {
        if (fields != null) 'fields': fields.encoded,
        if (groupScope != null) 'group_scope': '$groupScope',
      },
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return _decode(objectFromJson(response.data, 'record'));
  }

  Future<T> create(JsonObject values, {CancellationToken? cancellation}) async {
    final body = _recordBody(values);
    final response = await _transport.request(
      'POST',
      _path,
      body: body,
      cancellation: cancellation,
    );
    return _decode(objectFromJson(response.data, 'created record'));
  }

  /// Creates records and returns each created record. No transactional guarantee
  /// is made because the server documentation does not define one.
  Future<List<T>> bulk(
    Iterable<JsonObject> records, {
    CancellationToken? cancellation,
  }) async {
    final body = _recordsBody(records);
    final response = await _transport.request(
      'POST',
      [..._path, 'bulk'],
      body: body,
      cancellation: cancellation,
    );
    return List.unmodifiable(
      listFromJson(
        response.data,
        'created records',
      ).map((record) => _decode(objectFromJson(record, 'created record'))),
    );
  }

  /// Imports records without returning generated IDs or created models.
  Future<void> importRecords(
    Iterable<JsonObject> records, {
    CancellationToken? cancellation,
  }) async {
    final body = _recordsBody(records);
    await _transport.request(
      'POST',
      [..._path, 'import'],
      body: body,
      cancellation: cancellation,
    );
  }

  /// Partially updates only the supplied fields with PUT, as Anythink requires.
  Future<void> update(
    int id,
    JsonObject values, {
    CancellationToken? cancellation,
  }) async {
    _validateId(id);
    final body = _recordBody(values);
    await _transport.request(
      'PUT',
      [..._path, '$id'],
      body: body,
      cancellation: cancellation,
    );
  }

  Future<void> delete(int id, {CancellationToken? cancellation}) async {
    _validateId(id);
    await _transport.request('DELETE', [
      ..._path,
      '$id',
    ], cancellation: cancellation);
  }

  /// Deletes the supplied IDs using the documented POST form. Rows denied by
  /// row-level security may be skipped; success is not a per-record deletion
  /// receipt and does not prove that every requested record was deleted.
  Future<void> deleteMany(
    Iterable<int> ids, {
    CancellationToken? cancellation,
  }) async {
    final body = List<int>.unmodifiable(ids);
    if (body.isEmpty) throw ArgumentError('Supply at least one record ID.');
    for (final id in body) {
      _validateId(id);
    }
    if (body.toSet().length != body.length) {
      throw ArgumentError('Record IDs must not contain duplicates.');
    }
    await _transport.request(
      'POST',
      [..._path, 'delete-many'],
      body: body,
      cancellation: cancellation,
    );
  }

  Future<void> setLockStatus(
    int id, {
    required bool locked,
    CancellationToken? cancellation,
  }) async {
    _validateId(id);
    await _transport.request(
      'POST',
      [..._path, '$id', 'set-lock-status'],
      query: {'locked': '$locked'},
      cancellation: cancellation,
    );
  }

  /// Reads only fields marked public, without sending session credentials.
  Future<Page<T>> listPublic({
    RecordQuery? query,
    CancellationToken? cancellation,
  }) async {
    final options = query ?? RecordQuery();
    if (options.groupScope != null) {
      throw ArgumentError(
        'Group scope is available only on authenticated reads.',
      );
    }
    final response = await _transport.request(
      'GET',
      _publicPath,
      query: options.toQueryParameters(),
      authenticated: false,
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return Page<T>.fromJson(response.data, _decode);
  }

  Future<T> getPublic(
    int id, {
    FieldSelection? fields,
    CancellationToken? cancellation,
  }) async {
    _validateId(id);
    final response = await _transport.request(
      'GET',
      [..._publicPath, '$id'],
      query: {if (fields != null) 'fields': fields.encoded},
      authenticated: false,
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return _decode(objectFromJson(response.data, 'public record'));
  }
}

void _validateId(int id) {
  if (id < 1) throw ArgumentError('A record or group ID must be positive.');
}

List<JsonObject> _recordsBody(Iterable<JsonObject> records) {
  final result = records.map(_recordBody).toList(growable: false);
  if (result.isEmpty) throw ArgumentError('Supply at least one record.');
  return List.unmodifiable(result);
}

JsonObject _recordBody(JsonObject values) {
  const managed = {'id', 'locked', '__name', 'created_at', 'updated_at'};
  if (values.keys.any(managed.contains)) {
    throw ArgumentError('Server-managed record fields cannot be written.');
  }
  return _jsonSnapshot(values, Set<Object>.identity()) as JsonObject;
}

Object? _jsonSnapshot(Object? value, Set<Object> ancestors) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is List<Object?>) {
    if (!ancestors.add(value)) {
      throw ArgumentError('Record values cannot contain cyclic JSON.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((item) => _jsonSnapshot(item, ancestors)),
      );
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is Map<String, Object?>) {
    if (!ancestors.add(value)) {
      throw ArgumentError('Record values cannot contain cyclic JSON.');
    }
    try {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key: _jsonSnapshot(entry.value, ancestors),
      });
    } finally {
      ancestors.remove(value);
    }
  }
  throw ArgumentError('Record values must contain only finite JSON values.');
}
