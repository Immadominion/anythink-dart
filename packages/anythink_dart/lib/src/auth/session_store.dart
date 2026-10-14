/// Persistence for one API-origin/project session.
///
/// Implementations must await each operation and propagate failures. The auth
/// coordinator owns envelope serialization and serializes writes. Store the
/// entire value together; never log it or silently fall back to plaintext.
abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}
