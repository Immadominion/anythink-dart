import '../cancellation.dart';
import '../errors.dart';
import '../http/api_transport.dart';
import '../json.dart';

/// One row of the documented flat folder listing, not a nested tree.
final class FileFolder {
  FileFolder.fromJson(JsonObject json)
    : id = intFromJson(json['id'], 'folder.id'),
      name = stringFromJson(json['name'], 'folder.name'),
      parentFolderId = json['parent_folder_id'] == null
          ? null
          : intFromJson(json['parent_folder_id'], 'folder.parent_folder_id'),
      userId = json['user_id'] == null
          ? null
          : intFromJson(json['user_id'], 'folder.user_id'),
      path = stringFromJson(json['path'], 'folder.path'),
      fileCount = intFromJson(json['file_count'], 'folder.file_count'),
      subFolderCount = intFromJson(
        json['sub_folder_count'],
        'folder.sub_folder_count',
      ),
      data = _snapshot(json, Set<Object>.identity()) as JsonObject {
    if (id < 1 ||
        name.trim().isEmpty ||
        path.isEmpty ||
        (parentFolderId != null && parentFolderId! < 1) ||
        (userId != null && userId! < 1) ||
        fileCount < 0 ||
        subFolderCount < 0) {
      throw const ProtocolException('Invalid folder metadata.');
    }
  }

  final int id;
  final String name;
  final int? parentFolderId;
  final int? userId;
  final String path;

  /// Includes files in descendant folders, as defined by the server.
  final int fileCount;

  /// Counts direct child folders only.
  final int subFolderCount;
  final JsonObject data;

  @override
  String toString() => 'FileFolder(id: $id)';
}

/// A breadcrumb row returned by the folder-by-ID endpoint.
final class FileFolderBreadcrumb {
  FileFolderBreadcrumb.fromJson(JsonObject json)
    : id = intFromJson(json['id'], 'breadcrumb.id'),
      name = stringFromJson(json['name'], 'breadcrumb.name'),
      data = _snapshot(json, Set<Object>.identity()) as JsonObject;

  final int id;
  final String name;
  final JsonObject data;

  @override
  String toString() => 'FileFolderBreadcrumb(id: $id)';
}

/// The folder-by-ID endpoint returns an envelope, not a bare [FileFolder].
/// Its shape was confirmed against a dedicated live validation project.
final class FileFolderDetails {
  FileFolderDetails.fromJson(JsonObject json)
    : folder = FileFolder.fromJson(objectFromJson(json['folder'], 'folder')),
      subFolders = List.unmodifiable(
        listFromJson(json['sub_folders'], 'sub_folders').map(
          (item) => FileFolder.fromJson(objectFromJson(item, 'sub_folder')),
        ),
      ),
      breadcrumbs = List.unmodifiable(
        listFromJson(json['breadcrumb'], 'breadcrumb').map(
          (item) => FileFolderBreadcrumb.fromJson(
            objectFromJson(item, 'breadcrumb row'),
          ),
        ),
      ),
      data = _snapshot(json, Set<Object>.identity()) as JsonObject;

  final FileFolder folder;
  final List<FileFolder> subFolders;

  /// Preserves the server's breadcrumb order.
  final List<FileFolderBreadcrumb> breadcrumbs;
  final JsonObject data;
}

/// Folder operations require the corresponding anythink_files permission.
///
/// The guide specifies read models but does not define mutation response bodies.
/// Writes therefore return only HTTP completion, without manufacturing a folder
/// ID or model. Read the listing again when updated metadata is needed.
final class FileFoldersApi {
  const FileFoldersApi(this._transport);
  final ApiTransport _transport;
  static const _path = ['files', 'folders'];

  /// Top-level shared folders plus the current user's personal folders.
  Future<List<FileFolder>> list({CancellationToken? cancellation}) =>
      _read(_path, cancellation);

  /// All accessible folders, flat and sorted by path by the backend. Rebuild a
  /// hierarchy from parentFolderId; null means a top-level folder in reads.
  Future<List<FileFolder>> tree({CancellationToken? cancellation}) =>
      _read([..._path, 'tree'], cancellation);

  /// Reads the folder, its subfolders and breadcrumb rows.
  Future<FileFolderDetails> get(
    int id, {
    CancellationToken? cancellation,
  }) async {
    _id(id);
    final response = await _transport.request(
      'GET',
      [..._path, '$id'],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return FileFolderDetails.fromJson(
      objectFromJson(response.data, 'folder details'),
    );
  }

  Future<List<FileFolder>> _read(
    List<String> path,
    CancellationToken? cancellation,
  ) async {
    final response = await _transport.request(
      'GET',
      path,
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return List.unmodifiable(
      listFromJson(
        response.data,
        'folders',
      ).map((item) => FileFolder.fromJson(objectFromJson(item, 'folder'))),
    );
  }

  /// Creates a folder by name. The documented request does not establish a
  /// parent field on creation; use [move] with its ID after reading the listing.
  Future<void> create(String name, {CancellationToken? cancellation}) async {
    _name(name);
    await _transport.request(
      'POST',
      _path,
      body: {'name': name},
      cancellation: cancellation,
    );
  }

  Future<void> rename(
    int id,
    String name, {
    CancellationToken? cancellation,
  }) async {
    _id(id);
    _name(name);
    await _transport.request(
      'PUT',
      [..._path, '$id'],
      body: {'name': name},
      cancellation: cancellation,
    );
  }

  /// Moves under an existing parent. The public guide does not specify the
  /// write sentinel for moving a folder back to root, so none is guessed here.
  /// Moving a file back to root uses FilesApi.update(id, {'folder_id': 0}).
  Future<void> move(
    int id, {
    required int parentFolderId,
    CancellationToken? cancellation,
  }) async {
    _id(id);
    _id(parentFolderId);
    await _transport.request(
      'PUT',
      [..._path, '$id'],
      body: {'parent_folder_id': parentFolderId},
      cancellation: cancellation,
    );
  }

  /// By default files move to the deleted folder's parent. Setting
  /// [deleteContents] true explicitly requests deletion of the contents.
  /// No write is automatically replayed after an authentication/network error.
  Future<void> delete(
    int id, {
    bool deleteContents = false,
    CancellationToken? cancellation,
  }) async {
    _id(id);
    await _transport.request(
      'DELETE',
      [..._path, '$id'],
      query: {if (deleteContents) 'deleteContents': 'true'},
      cancellation: cancellation,
    );
  }
}

void _id(int id) {
  if (id < 1) throw ArgumentError('A folder ID must be positive.');
}

void _name(String name) {
  if (name.trim().isEmpty) throw ArgumentError('A folder name is required.');
}

Object? _snapshot(Object? value, Set<Object> parents) {
  if (value == null || value is String || value is bool) return value;
  if (value is num) {
    if (!value.isFinite) {
      throw const ProtocolException('Folder metadata is not finite JSON.');
    }
    return value;
  }
  if (value is Map) {
    if (!parents.add(value)) {
      throw const ProtocolException('Folder metadata contains a cycle.');
    }
    try {
      final entries = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw const ProtocolException(
            'Folder metadata has a non-string key.',
          );
        }
        entries[entry.key as String] = _snapshot(entry.value, parents);
      }
      return Map<String, Object?>.unmodifiable(entries);
    } finally {
      parents.remove(value);
    }
  }
  if (value is List) {
    if (!parents.add(value)) {
      throw const ProtocolException('Folder metadata contains a cycle.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((item) => _snapshot(item, parents)),
      );
    } finally {
      parents.remove(value);
    }
  }
  throw const ProtocolException('Folder metadata contains a non-JSON value.');
}
