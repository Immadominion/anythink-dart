import 'package:anythink_dart/anythink_dart.dart';

/// Failures before the Anythink token exchange. Backend failures retain their
/// original [AnythinkException] type instead.
enum NativeSignInFailure {
  canceled,
  interrupted,
  unsupportedPlatform,
  unavailable,
  invalidConfiguration,
  missingIdentityToken,
  missingUserIdentifier,
  operationInProgress,
  providerFailure,
}

/// A credential-free provider failure suitable for application diagnostics.
///
/// Raw plugin messages, details, account identifiers, and tokens are deliberately
/// omitted. Configure provider diagnostics separately if needed, taking care not
/// to log credentials or personal information.
final class NativeSignInException implements Exception {
  const NativeSignInException({required this.provider, required this.failure});

  final NativeProvider provider;
  final NativeSignInFailure failure;

  @override
  String toString() =>
      'NativeSignInException(${provider.name}, ${failure.name})';
}
