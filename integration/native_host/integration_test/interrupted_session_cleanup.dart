import 'package:anythink_dart/anythink_dart.dart';

/// Recovery diagnostics only; never counts as a session-validation gate.
final class InterruptedSessionCleanup {
  const InterruptedSessionCleanup({
    required this.localCleared,
    required this.identityConfirmed,
    required this.remoteRevoked,
    required this.rotationUncertain,
  });
  final bool localCleared;
  final bool identityConfirmed;
  final bool remoteRevoked;
  final bool rotationUncertain;
}

Future<InterruptedSessionCleanup> cleanupInterruptedSession(
  AnythinkClient client,
  SessionStore store, {
  required String expectedEmail,
}) async {
  var identityConfirmed = false;
  var rotationUncertain = false;
  try {
    await client.auth.restoreSession();
    if (client.auth.currentSession != null) {
      final user = await client.auth.getUser();
      identityConfirmed =
          user.email == expectedEmail && !await client.auth.isAdmin();
    }
  } on RefreshUncertainException {
    // An old-token revoke cannot prove an unknown rotated successor revoked.
    rotationUncertain = true;
  } catch (_) {
    // A failed restore/probe must not bypass local cleanup. The failed identity
    // result prevents a remote-revocation success claim below.
  }
  rotationUncertain =
      rotationUncertain || client.auth.state.error is RefreshUncertainException;
  final signOut = await client.auth.signOut();
  return InterruptedSessionCleanup(
    localCleared:
        client.auth.currentSession == null && await store.read() == null,
    identityConfirmed: identityConfirmed,
    remoteRevoked:
        identityConfirmed &&
        !rotationUncertain &&
        signOut.remoteRevoked &&
        signOut.remoteError == null,
    rotationUncertain: rotationUncertain,
  );
}
