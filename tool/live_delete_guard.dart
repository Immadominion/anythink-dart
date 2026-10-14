import 'package:anythink_dart/anythink_dart.dart';
import 'package:http/http.dart' as http;

/// Observes only response status, never credentials, response bodies or URLs.
/// The real public SDK still makes and interprets every request.
final class DeleteStatusHttpClient extends http.BaseClient {
  DeleteStatusHttpClient() : _inner = http.Client();
  final http.Client _inner;
  int? lastDeleteStatus;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final isDelete = request.method == 'DELETE';
    if (isDelete) lastDeleteStatus = null;
    final response = await _inner.send(request);
    if (isDelete) lastDeleteStatus = response.statusCode;
    return response;
  }

  @override
  void close() => _inner.close();
}

final class LiveDeleteIsolationFailure implements Exception {
  const LiveDeleteIsolationFailure();
}

/// A hidden record can be treated as absent by DELETE and return 204. That is
/// acceptable only together with a mandatory owning-user unchanged read-back.
/// GET/PUT cross-user checks independently still require 403 or 404.
Future<void> verifyDeleteIsolation({
  required Future<int?> Function() deleteAsOther,
  required Future<void> Function() verifyOwnerUnchanged,
}) async {
  try {
    final status = await deleteAsOther();
    if (status != 204) throw const LiveDeleteIsolationFailure();
  } on ApiException catch (error) {
    if (error.statusCode != 403 && error.statusCode != 404) rethrow;
  }
  await verifyOwnerUnchanged();
}
