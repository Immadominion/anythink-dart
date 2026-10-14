import 'dart:async';

import '../errors.dart';
import '../json.dart';
import '../wire_timestamp.dart';

/// Counts file bytes consumed/emitted by the client, not server acknowledgement.
typedef TransferProgress = void Function(int transferred, int? total);

/// A known-length byte source. The factory should open a fresh stream each time.
/// Uploads are never automatically replayed, even when the source is reusable.
/// Use File.openRead in native apps or a browser byte stream without buffering
/// the entire file in this SDK.
final class UploadSource {
  UploadSource({
    required this.filename,
    required this.length,
    required this.openRead,
    this.contentType = 'application/octet-stream',
  }) {
    if (filename.isEmpty ||
        filename.contains('\r') ||
        filename.contains('\n')) {
      throw ArgumentError('A non-empty filename without newlines is required.');
    }
    if (length < 0) {
      throw ArgumentError.value(length, 'length', 'Must be non-negative.');
    }
  }

  final String filename;
  final int length;
  final Stream<List<int>> Function() openRead;
  final String contentType;
}

/// File metadata is extensible; media probe fields may not exist immediately
/// after upload. Unknown server fields are retained in [data].
final class AnythinkFile {
  AnythinkFile.fromJson(JsonObject json)
    : id = intFromJson(json['id'], 'file.id'),
      originalFilename = _optionalString(
        json['original_file_name'],
        'original_file_name',
      ),
      contentType = _optionalString(json['file_type'], 'file_type'),
      size = _optionalInt(json['file_size'], 'file_size'),
      isPublic = json['is_public'] == null
          ? null
          : boolFromJson(json['is_public'], 'is_public'),
      data = Map.unmodifiable(json) {
    if (id < 1 || (size != null && size! < 0)) {
      throw const ProtocolException('Invalid file ID or byte size.');
    }
  }
  final int id;
  final String? originalFilename;
  final String? contentType;
  final int? size;
  final bool? isPublic;
  final JsonObject data;

  @override
  String toString() => 'AnythinkFile(id: $id)';
}

/// A short-lived bearer capability. Never log the URL or expose it publicly.
final class SignedFileUrl {
  SignedFileUrl.fromJson(JsonObject json)
    : url = _uri(json['url']),
      expiresAt = timestampFromJson(json['expires_at'], 'expires_at');
  final Uri url;
  final DateTime expiresAt;

  @override
  String toString() => 'SignedFileUrl(url: [redacted], expiresAt: $expiresAt)';
}

/// Consume or cancel [stream] to release the download connection. Stream errors
/// include cancellation/timeouts; a response object alone is not completion.
final class FileDownload {
  const FileDownload({
    required this.stream,
    required this.contentLength,
    required this.headers,
  });
  final Stream<List<int>> stream;
  final int? contentLength;
  final Map<String, String> headers;
}

final class FileDeleteResult {
  FileDeleteResult.fromJson(JsonObject json)
    : successfulDeletes = List.unmodifiable(
        listFromJson(
          json['successful_deletes'],
        ).map((v) => intFromJson(v, 'successful_deletes')),
      ),
      failedDeletes = listFromJson(json['failed_deletes']),
      totalRequested = intFromJson(json['total_requested'], 'total_requested'),
      totalDeleted = intFromJson(json['total_deleted'], 'total_deleted') {
    if (successfulDeletes.any((id) => id < 1) ||
        successfulDeletes.toSet().length != successfulDeletes.length ||
        totalRequested < 0 ||
        totalDeleted < 0 ||
        totalDeleted > totalRequested ||
        totalDeleted != successfulDeletes.length) {
      throw const ProtocolException('Inconsistent bulk file deletion result.');
    }
  }
  final List<int> successfulDeletes;

  /// Failure entry shape is not specified by the public API; retain its JSON.
  final List<Object?> failedDeletes;
  final int totalRequested;
  final int totalDeleted;
}

String? _optionalString(Object? value, String field) =>
    value == null ? null : stringFromJson(value, field);
int? _optionalInt(Object? value, String field) =>
    value == null ? null : intFromJson(value, field);
Uri _uri(Object? value) {
  final uri = Uri.tryParse(stringFromJson(value, 'url'));
  final localHttp =
      uri?.scheme == 'http' &&
      const {'localhost', '127.0.0.1', '::1'}.contains(uri?.host);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (uri.scheme != 'https' && !localHttp)) {
    throw const ProtocolException('The signed download URL is invalid.');
  }
  return uri;
}
