/// The native operation that failed. These identifiers never contain tokens,
/// notification payloads or provider-supplied diagnostic text.
enum PushNativeOperation {
  notificationSettings,
  permissionRequest,
  apnsToken,
  deviceToken,
  initialMessage,
  tokenRefresh,
}

enum PushNativeFailure { unavailable, operationFailed }

/// Redacted failure at the Firebase/native boundary. Backend API failures retain
/// their core exception types; OS permission decisions remain structured values.
final class PushNativeException implements Exception {
  const PushNativeException(
    this.operation, {
    this.failure = PushNativeFailure.operationFailed,
  });

  final PushNativeOperation operation;
  final PushNativeFailure failure;

  @override
  String toString() =>
      'PushNativeException(${operation.name}, ${failure.name})';
}
