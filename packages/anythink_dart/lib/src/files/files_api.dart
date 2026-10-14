import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../cancellation.dart';
import '../errors.dart';
import '../http/api_transport.dart';
import '../json.dart';
import '../records/page.dart';
import 'folders_api.dart';
import 'models.dart';

enum FileCategory { image, video, audio, document }

enum FileSortField {
  id('id'),
  originalFilename('original_file_name'),
  size('file_size'),
  createdAt('created_at'),
  updatedAt('updated_at');

  const FileSortField(this.value);
  final String value;
}

/// Permission-gated file APIs. Private storage is not documented as inheriting
/// a linked record's per-user RLS; do not assume attaching a file isolates it.
final class FilesApi {
  const FilesApi(this._transport);
  final ApiTransport _transport;

  FileFoldersApi get folders => FileFoldersApi(_transport);

  Future<AnythinkFile> upload(
    UploadSource source, {
    bool isPublic = false,
    int? folderId,
    int? entityId,
    String? fieldName,
    TransferProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    if (folderId != null && folderId < 0) {
      throw ArgumentError('Invalid folder ID.');
    }
    if ((entityId == null) != (fieldName == null)) {
      throw ArgumentError('entityId and fieldName must be supplied together.');
    }
    if (entityId != null) _id(entityId);
    if (fieldName != null && fieldName.isEmpty) {
      throw ArgumentError('Empty field name.');
    }
    final type = MediaType.parse(source.contentType);
    final response = await _transport.send(
      'POST',
      ['files'],
      query: {
        'isPublic': '$isPublic',
        if (folderId != null) 'folderId': '$folderId',
        if (entityId != null) 'entityId': '$entityId',
        'fieldName': ?fieldName,
      },
      cancellation: cancellation,
      // A consumed multipart upload is not replayed on 401 or network failure.
      requestFactory: (uri, abort) =>
          http.AbortableMultipartRequest('POST', uri, abortTrigger: abort)
            ..files.add(
              http.MultipartFile(
                'file',
                _uploadBytes(source, onProgress, cancellation),
                source.length,
                filename: source.filename,
                contentType: type,
              ),
            ),
    );
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > _transport.maxResponseBytes) {
        throw const ProtocolException(
          'File metadata exceeds the response size limit.',
        );
      }
      bytes.addAll(chunk);
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const ProtocolException('Upload response is not valid JSON.');
    }
    return AnythinkFile.fromJson(objectFromJson(body, 'uploaded file'));
  }

  Future<Page<AnythinkFile>> list({
    int page = 1,
    int pageSize = 25,
    String? search,
    FileCategory? category,
    int? folderId,
    FileSortField sortBy = FileSortField.id,
    bool descending = false,
    CancellationToken? cancellation,
  }) async {
    if (page < 1 || pageSize < 1 || pageSize > 1000) {
      throw ArgumentError(
        'Page must be positive and pageSize between 1 and 1000.',
      );
    }
    if (folderId != null && folderId < 0) {
      throw ArgumentError('Invalid folder ID.');
    }
    final response = await _transport.request(
      'GET',
      ['files'],
      query: {
        'page': '$page',
        'pageSize': '$pageSize',
        'sortBy': sortBy.value,
        'sortDirection': descending ? 'desc' : 'asc',
        'search': ?search,
        if (category != null) 'fileType': category.name,
        if (folderId != null) 'folderId': '$folderId',
      },
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return Page.fromJson(
      objectFromJson(response.data, 'files page'),
      (item) => AnythinkFile.fromJson(objectFromJson(item, 'file')),
    );
  }

  Future<AnythinkFile> get(int id, {CancellationToken? cancellation}) async {
    _id(id);
    final response = await _transport.request(
      'GET',
      ['files', '$id'],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    return AnythinkFile.fromJson(objectFromJson(response.data, 'file'));
  }

  Future<SignedFileUrl> signedUrl(
    int id, {
    CancellationToken? cancellation,
  }) async {
    _id(id);
    final response = await _transport.request(
      'GET',
      ['files', '$id', 'url'],
      retryOnUnauthorized: true,
      cancellation: cancellation,
    );
    final link = SignedFileUrl.fromJson(
      objectFromJson(response.data, 'signed file URL'),
    );
    if (link.url.scheme != 'https' && !_transport.allowInsecureLocalhost) {
      throw const ProtocolException('The signed download URL must use HTTPS.');
    }
    return link;
  }

  /// Resolve a fresh signed URL, then download without any API authorization.
  /// No file contents are buffered by this service. The caller owns the sink.
  Future<FileDownload> download(
    int id, {
    TransferProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    final generation = _transport.sessionGeneration?.call();
    void checkSession() {
      if (generation != null &&
          _transport.sessionGeneration?.call() != generation) {
        throw const SessionChangedException();
      }
    }

    final link = await signedUrl(id, cancellation: cancellation);
    checkSession();
    final response = await _transport.download(
      link.url,
      cancellation: cancellation,
    );
    return _fileDownload(
      response,
      onProgress,
      cancellation,
      checkSession: checkSession,
    );
  }

  /// The stable unauthenticated endpoint for a public file. This constructs a
  /// link only; the server returns 404 if the file is private or absent.
  Uri publicUrl(int id) {
    _id(id);
    return _transport.uriFor(['files', '$id', 'public']);
  }

  /// Streams a public file without reading session credentials. Follows the
  /// documented CDN redirect with destination validation and a five-hop cap.
  /// Private or absent files remain API failures; no authenticated fallback is
  /// attempted. Consume or cancel the returned stream.
  Future<FileDownload> downloadPublic(
    int id, {
    TransferProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    final response = await _transport.download(
      publicUrl(id),
      followRedirects: true,
      cancellation: cancellation,
    );
    return _fileDownload(response, onProgress, cancellation);
  }

  /// Metadata fields are passed through because the backend may add fields.
  /// Omitted fields are preserved by the documented partial PUT contract.
  Future<void> update(
    int id,
    JsonObject metadata, {
    CancellationToken? cancellation,
  }) async {
    _id(id);
    await _transport.request(
      'PUT',
      ['files', '$id'],
      body: metadata,
      cancellation: cancellation,
    );
  }

  Future<void> reprobe(int id, {CancellationToken? cancellation}) async {
    _id(id);
    await _transport.request('POST', [
      'files',
      '$id',
      'reprobe',
    ], cancellation: cancellation);
  }

  Future<void> delete(int id, {CancellationToken? cancellation}) async {
    _id(id);
    await _transport.request('DELETE', [
      'files',
      '$id',
    ], cancellation: cancellation);
  }

  Future<FileDeleteResult> deleteMany(
    List<int> ids, {
    CancellationToken? cancellation,
  }) async {
    if (ids.isEmpty) throw ArgumentError('At least one file ID is required.');
    for (final id in ids) {
      _id(id);
    }
    final response = await _transport.request(
      'DELETE',
      ['files'],
      body: {'file_ids': List<int>.of(ids)},
      cancellation: cancellation,
    );
    return FileDeleteResult.fromJson(
      objectFromJson(response.data, 'file delete result'),
    );
  }
}

void _id(int id) {
  if (id < 1) throw ArgumentError.value(id, 'id', 'Must be positive.');
}

FileDownload _fileDownload(
  ApiStreamResponse response,
  TransferProgress? progress,
  CancellationToken? cancellation, {
  void Function()? checkSession,
}) {
  final length = int.tryParse(response.headers['content-length'] ?? '');
  return FileDownload(
    stream: _downloadBytes(
      response.stream,
      length,
      progress,
      cancellation,
      checkSession,
    ),
    contentLength: length,
    headers: response.headers,
  );
}

Stream<List<int>> _uploadBytes(
  UploadSource source,
  TransferProgress? progress,
  CancellationToken? cancellation,
) async* {
  var transferred = 0;
  if (cancellation?.isCancelled == true) return;
  progress?.call(0, source.length);
  if (cancellation?.isCancelled == true) return;
  await for (final chunk in source.openRead()) {
    if (cancellation?.isCancelled == true) return;
    transferred += chunk.length;
    if (transferred > source.length) {
      throw const ProtocolException(
        'Upload stream exceeds its declared length.',
      );
    }
    progress?.call(transferred, source.length);
    if (cancellation?.isCancelled == true) return;
    yield chunk;
  }
  if (cancellation?.isCancelled == true) return;
  if (transferred != source.length) {
    throw const ProtocolException(
      'Upload stream ended before its declared length.',
    );
  }
}

Stream<List<int>> _downloadBytes(
  Stream<List<int>> source,
  int? length,
  TransferProgress? progress,
  CancellationToken? cancellation,
  void Function()? checkSession,
) async* {
  var transferred = 0;
  await for (final chunk in source) {
    checkSession?.call();
    _checkCancelled(cancellation);
    transferred += chunk.length;
    progress?.call(transferred, length);
    // Application progress callbacks may log out or cancel synchronously.
    // Recheck before exposing this chunk to the consumer.
    checkSession?.call();
    _checkCancelled(cancellation);
    yield chunk;
  }
  checkSession?.call();
  _checkCancelled(cancellation);
  if (transferred == 0) progress?.call(0, length);
}

void _checkCancelled(CancellationToken? cancellation) {
  if (cancellation?.isCancelled == true) {
    throw const TransportException(TransportFailure.cancelled);
  }
}
