/// Base class for SDK failures. Diagnostic strings never include credentials.
sealed class AnythinkException implements Exception {
  const AnythinkException(this.message);
  final String message;
  @override
  String toString() => '$runtimeType: $message';
}

/// An unsuccessful HTTP response. [message] is deliberately generic; structured
/// field errors are available separately and should not be logged indiscriminately.
final class ApiException extends AnythinkException {
  const ApiException({
    required this.statusCode,
    this.code,
    this.traceId,
    this.serverMessage,
    this.retryAfter,
    this.fieldErrors = const {},
  }) : super('The API rejected the request.');
  final int statusCode;
  final String? code;
  final String? traceId;

  /// Bounded server-supplied message/title or plain-text error body. This is
  /// untrusted and may contain user data. It is never included in toString.
  final String? serverMessage;
  final Duration? retryAfter;
  final Map<String, List<String>> fieldErrors;
  @override
  String toString() => 'ApiException(statusCode: $statusCode)';
}

enum TransportFailure { network, timeout, cancelled }

final class TransportException extends AnythinkException {
  const TransportException(this.failure, {this.outcomeUncertain = false})
    : super('The request did not complete.');
  final TransportFailure failure;

  /// The server may have applied a mutation before its response was lost.
  final bool outcomeUncertain;
  @override
  String toString() =>
      'TransportException(${failure.name}, '
      'outcomeUncertain: $outcomeUncertain)';
}

final class ProtocolException extends AnythinkException {
  const ProtocolException(super.message);
}

final class SessionStorageException extends AnythinkException {
  const SessionStorageException() : super('Secure session persistence failed.');
}

final class AuthRequiredException extends AnythinkException {
  const AuthRequiredException() : super('A signed-in session is required.');
}

final class SessionChangedException extends AnythinkException {
  const SessionChangedException()
    : super('The session changed while this operation was running.');
}

final class RefreshUncertainException extends AnythinkException {
  const RefreshUncertainException()
    : super('Token rotation could not be confirmed. Sign in again to recover.');
}

final class ClientClosedException extends AnythinkException {
  const ClientClosedException() : super('This client is closed.');
}
