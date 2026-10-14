import 'dart:async';

import 'package:anythink_flutter/anythink_flutter.dart';
import 'package:flutter/foundation.dart';

import 'configuration.dart';

/// Owns the preview's client; provider integrations remain opt-in.
class SessionController extends ChangeNotifier {
  SessionController(
    this.configuration, {
    AnythinkClient? client,
    SessionStore? sessionStore,
  }) {
    if (configuration.isMissing) return;
    try {
      final origin = Uri.parse(configuration.apiOrigin);
      sessionStore ??= client == null
          ? SecureSessionStore(
              apiOrigin: origin,
              projectId: configuration.projectId,
            )
          : null;
      client ??= AnythinkClient(
        apiOrigin: origin,
        projectId: configuration.projectId,
        sessionStore: sessionStore,
      );
      _client = client;
      _states = client.auth.states.listen((state) {
        if (state.status == AuthStatus.reauthenticationRequired) {
          _hasSavedSession = false;
          _availabilityRevision++;
        }
        if (state.error != null) {
          message = safeFailure(state.error!);
          isError = true;
        }
        _update();
      });
      if (sessionStore != null) unawaited(_checkSavedSession(sessionStore));
      _lifecycle = AnythinkLifecycleBridge(
        auth: client.auth,
        onError: (error, _) {
          message = safeFailure(error);
          isError = true;
          _update();
        },
      );
    } catch (_) {
      invalidConfiguration = true;
    }
  }

  final NativeHostConfiguration configuration;
  AnythinkClient? _client;
  AnythinkLifecycleBridge? _lifecycle;
  StreamSubscription<AuthState>? _states;
  bool _disposed = false;
  bool _hasSavedSession = false;
  int _availabilityRevision = 0;

  bool get hasSavedSession => _hasSavedSession && !needsSignOutRetry;

  Future<void> _checkSavedSession(SessionStore store) async {
    final revision = _availabilityRevision;
    try {
      final saved = await store.read();
      if (_disposed || revision != _availabilityRevision) return;
      _hasSavedSession = saved != null && saved.isNotEmpty;
      _update();
    } catch (_) {
      // An unreadable store cannot offer a usable restore action.
    }
  }

  bool invalidConfiguration = false;
  bool busy = false;
  bool isError = false;
  bool needsSignOutRetry = false;
  String? message;

  bool get configured => _client != null;
  AnythinkClient? get client => _client;
  bool get signedIn =>
      _client?.auth.currentSession != null &&
      _client?.auth.state.status != AuthStatus.reauthenticationRequired;
  String? get validApiOrigin => _client?.apiOrigin.toString();
  AnythinkUser? get user => _client?.auth.state.user;
  String get statusLabel {
    if (!configured) {
      return invalidConfiguration ? 'Check project settings' : 'Not connected';
    }
    return switch (_client!.auth.state.status) {
      AuthStatus.signedOut => 'Signed out',
      AuthStatus.restoring => 'Restoring session',
      AuthStatus.authenticating => 'Signing in',
      AuthStatus.authenticated => 'Signed in',
      AuthStatus.temporarilyUnavailable => 'Connection interrupted',
      AuthStatus.reauthenticationRequired => 'Sign in again',
    };
  }

  Future<void> signIn(String email, String password) => _run((client) async {
    await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    needsSignOutRetry = false;
    _hasSavedSession = true;
    _lifecycle!.attach();
    await client.auth.getUser();
    return null;
  });

  Future<void> restore() => _run((client) async {
    _hasSavedSession = false;
    await client.auth.restoreSession();
    _hasSavedSession = signedIn;
    if (client.auth.currentSession == null) {
      return 'No saved session. Sign in below.';
    }
    _lifecycle!.attach();
    return null;
  });

  Future<void> refreshAccount() => _run((client) async {
    await client.auth.getUser();
    return 'Account updated.';
  });

  Future<void> signOut() => _run((client) async {
    needsSignOutRetry = true;
    _hasSavedSession = false;
    final result = await client.auth.signOut();
    needsSignOutRetry = false;
    return result.remoteError != null
        ? 'Signed out on this device. Server sign-out could not be confirmed.'
        : result.remoteRevoked
        ? 'Signed out.'
        : 'Signed out on this device.';
  });

  Future<void> _run(Future<String?> Function(AnythinkClient) operation) async {
    final client = _client;
    if (_disposed || busy || client == null) return;
    _availabilityRevision++;
    busy = true;
    message = null;
    isError = false;
    _update();
    try {
      message = await operation(client);
    } catch (error) {
      message = needsSignOutRetry
          ? 'Sign-out is incomplete. Retry to clear the saved session.'
          : safeFailure(error);
      isError = true;
    } finally {
      busy = false;
      _update();
    }
  }

  void _update() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _lifecycle?.dispose();
    unawaited(_states?.cancel());
    final client = _client;
    if (client != null) unawaited(client.close());
    super.dispose();
  }
}

String safeFailure(Object error) => switch (error) {
  ApiException(statusCode: 401) =>
    'Sign-in failed. Check your email and password.',
  ApiException(statusCode: 403) => 'This account does not have access.',
  ApiException() => 'Request failed (${error.statusCode}). Please try again.',
  TransportException() =>
    error.outcomeUncertain
        ? 'Connection lost. Check the result before trying again.'
        : 'Could not connect. Check your internet connection.',
  SessionStorageException() || SecureSessionStoreException() =>
    'Could not save this session securely. Please try again.',
  SessionChangedException() => 'Your session changed. Please try again.',
  RefreshUncertainException() =>
    'Please sign in again to restore your session.',
  AuthRequiredException() => 'Please sign in to continue.',
  ProtocolException() => 'Could not read the response. Please try again.',
  ClientClosedException() => 'Please reopen the app.',
  _ => 'Something went wrong. Please try again.',
};
