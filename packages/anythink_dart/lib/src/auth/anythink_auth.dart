import 'dart:async';
import 'dart:convert';

import '../errors.dart';
import '../http/api_transport.dart';
import '../json.dart';
import '../wire_timestamp.dart';
import 'models.dart';
import 'session_store.dart';

/// Password/native authentication and a single-owner rotating session.
///
/// Use one instance for a persisted origin/project session. This class awaits
/// persistence, fences late results and never retries an uncertain rotation.
/// Identity is loaded explicitly with [getUser]; sign-in returns a token pair.
final class AnythinkAuth {
  AnythinkAuth(
    this._transport, {
    SessionStore? sessionStore,
    DateTime Function()? clock,
    this.refreshMargin = const Duration(seconds: 30),
  }) : _store = sessionStore,
       _clock = clock ?? DateTime.now {
    if (refreshMargin < Duration.zero) {
      throw ArgumentError.value(refreshMargin, 'refreshMargin');
    }
  }

  final ApiTransport _transport;
  final SessionStore? _store;
  final DateTime Function() _clock;
  final Duration refreshMargin;
  final _events = StreamController<AuthState>.broadcast();
  AuthState _state = const AuthState(AuthStatus.signedOut);
  Session? _session;
  int _generation = 0;
  bool _closed = false;
  bool _rotationUncertain = false;
  bool _storageDirty = false;
  Future<Session>? _refreshFuture;
  int? _refreshGeneration;
  Future<void> _storeTail = Future.value();

  AuthState get state => _state;
  Stream<AuthState> get states => _events.stream;
  Session? get currentSession => _session;
  int get generation => _generation;

  void _checkOpen() {
    if (_closed) throw const ClientClosedException();
  }

  void _checkGeneration(int generation) {
    _checkOpen();
    if (generation != _generation) throw const SessionChangedException();
  }

  void _emit(
    AuthStatus status, {
    AnythinkUser? user,
    AnythinkException? error,
  }) {
    if (_closed) return;
    _state = AuthState(status, user: user, error: error);
    _events.add(_state);
  }

  Future<T> _storageOperation<T>(Future<T> Function() action) {
    final result = _storeTail.then((_) => action());
    _storeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _persist(
    Session? session,
    int generation, {
    bool rotationPending = false,
  }) async {
    final store = _store;
    if (store == null) return;
    await _storageOperation(() async {
      _checkGeneration(generation);
      try {
        if (session == null) {
          await store.clear();
        } else {
          await store.write(
            jsonEncode({
              'version': 1,
              'api_origin': _transport.origin.toString(),
              'project_id': _transport.projectId,
              'rotation_pending': rotationPending,
              'session': {
                'access_token': session.accessToken,
                'refresh_token': session.refreshToken,
                'expires_at': session.expiresAt.toUtc().toIso8601String(),
              },
            }),
          );
        }
      } catch (_) {
        throw const SessionStorageException();
      }
    });
    _checkGeneration(generation);
  }

  /// Restores credentials, refreshes if required, then loads server identity.
  /// Invalid envelopes remain untouched and produce a redacted protocol error.
  Future<void> restoreSession() async {
    _checkOpen();
    if (_rotationUncertain) throw const RefreshUncertainException();
    if (_refreshFuture != null) {
      throw StateError('Cannot restore while token rotation is running.');
    }
    final generation = ++_generation;
    _session = null;
    _rotationUncertain = false;
    _storageDirty = false;
    _emit(AuthStatus.restoring);
    try {
      final serialized = await _storageOperation(() async {
        try {
          return await _store?.read();
        } catch (_) {
          throw const SessionStorageException();
        }
      });
      _checkGeneration(generation);
      if (serialized == null) {
        _emit(AuthStatus.signedOut);
        return;
      }
      Object? decoded;
      try {
        decoded = jsonDecode(serialized);
      } on FormatException {
        throw const ProtocolException('Invalid stored session JSON.');
      }
      final envelope = objectFromJson(decoded, 'stored session');
      if (envelope['version'] != 1 ||
          envelope['api_origin'] != _transport.origin.toString() ||
          envelope['project_id'] != _transport.projectId) {
        throw const ProtocolException(
          'Stored session version or scope does not match.',
        );
      }
      // Missing markers are compatible with pre-marker v1 stores. A present
      // malformed marker must never be interpreted as completed rotation.
      if (envelope.containsKey('rotation_pending') &&
          envelope['rotation_pending'] is! bool) {
        throw const ProtocolException('Invalid stored rotation marker.');
      }
      final payload = objectFromJson(envelope['session'], 'stored credentials');
      final access = stringFromJson(payload['access_token'], 'access_token');
      final refresh = stringFromJson(payload['refresh_token'], 'refresh_token');
      final expiry = timestampFromJson(payload['expires_at'], 'expires_at');
      if (access.isEmpty || refresh.isEmpty) {
        throw const ProtocolException('Stored credentials are incomplete.');
      }
      _session = Session(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: expiry.toUtc(),
      );
      if (envelope['rotation_pending'] == true) {
        _rotationUncertain = true;
        const error = RefreshUncertainException();
        _emit(AuthStatus.reauthenticationRequired, error: error);
        throw error;
      }
      await refreshIfNeeded();
      _checkGeneration(generation);
      await getUser();
    } on AnythinkException catch (error) {
      if (generation == _generation &&
          !_closed &&
          _state.status != AuthStatus.reauthenticationRequired) {
        _emit(AuthStatus.temporarilyUnavailable, error: error);
      }
      rethrow;
    }
  }

  Future<Session> signInWithPassword({
    required String email,
    required String password,
  }) => _authenticate(
    ['auth', 'v1', 'token'],
    {'email': email, 'password': password},
  );

  Future<Session> signInWithNativeToken({
    required NativeProvider provider,
    required String identityToken,
    required String userIdentifier,
    String? givenName,
    String? familyName,
    Map<String, String>? signupContext,
  }) => _authenticate(
    ['auth', 'v1', 'native', provider.name],
    {
      'identity_token': identityToken,
      'user_identifier': userIdentifier,
      'given_name': ?givenName,
      'family_name': ?familyName,
      if (signupContext != null)
        'signup_context': Map<String, String>.unmodifiable(signupContext),
    },
  );

  /// Exchanges Apple's one-use web completion code (not an arbitrary OAuth code).
  Future<Session> exchangeAppleCode(String code) =>
      _authenticate(['auth', 'v1', 'exchange'], {'code': code});

  Future<Session> completeOAuth({
    required WebProvider provider,
    required String code,
    required String state,
  }) async {
    if (provider == WebProvider.apple) {
      throw ArgumentError('Use exchangeAppleCode for the Apple web callback.');
    }
    return _authenticate(
      ['auth', 'v1', provider.name, 'callback'],
      null,
      method: 'GET',
      query: {'code': code, 'state': state},
    );
  }

  Future<Session> _authenticate(
    List<String> path,
    Object? body, {
    String method = 'POST',
    Map<String, String>? query,
  }) async {
    _checkOpen();
    final generation = ++_generation;
    _session = null;
    _rotationUncertain = false;
    _storageDirty = false;
    _emit(AuthStatus.authenticating);
    try {
      // Clear old persisted identity before attempting an account replacement.
      await _persist(null, generation);
      final response = await _transport.request(
        method,
        path,
        body: body,
        query: query,
        authenticated: false,
      );
      final session = Session.fromTokenResponse(response.data, _clock());
      if (generation != _generation || _closed) {
        await _discardSession(session);
        throw const SessionChangedException();
      }
      await _adopt(session, generation);
      return session;
    } on AnythinkException catch (error) {
      if (generation == _generation && !_closed) {
        _emit(
          _session == null
              ? AuthStatus.signedOut
              : AuthStatus.temporarilyUnavailable,
          error: error,
        );
      }
      rethrow;
    }
  }

  Future<void> _adopt(Session session, int generation) async {
    _checkGeneration(generation);
    final user = _state.user;
    _session = session;
    _storageDirty = true;
    try {
      await _persist(session, generation);
      _checkGeneration(generation);
      _storageDirty = false;
      _emit(AuthStatus.authenticated, user: user);
    } on SessionStorageException catch (error) {
      if (generation == _generation && !_closed) {
        _emit(AuthStatus.temporarilyUnavailable, user: user, error: error);
      }
      rethrow;
    }
  }

  /// Returns null when signed out. Does not rotate an uncertain refresh token.
  Future<Session?> refreshIfNeeded() async {
    _checkOpen();
    final session = _session;
    if (session == null) return null;
    if (_rotationUncertain) throw const RefreshUncertainException();
    // Join before repairing a dirty store. Otherwise an old-pair repair could
    // clear the durable pending marker while explicit rotation is in flight.
    final refreshing = _refreshFuture;
    if (refreshing != null && _refreshGeneration == _generation) {
      return refreshing;
    }
    final generation = _generation;
    if (_storageDirty) {
      await _persist(session, generation);
      _checkGeneration(generation);
      _storageDirty = false;
    }
    if (session.expiresAt.isAfter(_clock().toUtc().add(refreshMargin))) {
      return session;
    }
    return refreshSession();
  }

  /// Explicit refresh. Concurrent callers in the same identity share one request.
  Future<Session> refreshSession() {
    _checkOpen();
    if (_session == null) throw const AuthRequiredException();
    if (_rotationUncertain) throw const RefreshUncertainException();
    final existing = _refreshFuture;
    if (existing != null && _refreshGeneration == _generation) return existing;
    final generation = _generation;
    final session = _session!;
    late final Future<Session> future;
    future = _rotate(session, generation).whenComplete(() {
      if (identical(_refreshFuture, future)) {
        _refreshFuture = null;
        _refreshGeneration = null;
      }
    });
    _refreshFuture = future;
    _refreshGeneration = generation;
    return future;
  }

  Future<Session> _rotate(Session previous, int generation) async {
    // Write-ahead marker prevents replaying a consumed single-use token after
    // process death or a lost response. A restart during rotation requires a
    // new sign-in unless a complete renewed pair was successfully persisted.
    await _persist(previous, generation, rotationPending: true);
    try {
      final response = await _transport.request(
        'POST',
        ['auth', 'v1', 'refresh'],
        body: {'token': previous.refreshToken},
        authenticated: false,
      );
      final renewed = Session.fromTokenResponse(response.data, _clock());
      if (generation != _generation || _closed) {
        await _discardSession(renewed);
        throw const SessionChangedException();
      }
      await _adopt(renewed, generation);
      return renewed;
    } on ApiException catch (error) {
      _checkGeneration(generation);
      if (error.statusCode == 401) {
        _session = null;
        _storageDirty = false;
        _emit(AuthStatus.reauthenticationRequired, error: error);
        await _persist(null, generation);
      } else {
        // A server error may follow a committed rotation. The public contract
        // provides no grace/replay guarantee, so preserve the pending marker.
        _rotationUncertain = true;
        _emit(
          AuthStatus.reauthenticationRequired,
          user: _state.user,
          error: error,
        );
      }
      rethrow;
    } on TransportException catch (error) {
      _checkGeneration(generation);
      _rotationUncertain = error.outcomeUncertain;
      _emit(
        _rotationUncertain
            ? AuthStatus.reauthenticationRequired
            : AuthStatus.temporarilyUnavailable,
        user: _state.user,
        error: error,
      );
      rethrow;
    } on ProtocolException catch (error) {
      _checkGeneration(generation);
      _rotationUncertain = true;
      _emit(
        AuthStatus.reauthenticationRequired,
        user: _state.user,
        error: error,
      );
      rethrow;
    }
  }

  Future<String> accessTokenForRequest() async {
    final generation = _generation;
    final session = await refreshIfNeeded();
    _checkGeneration(generation);
    if (session == null) throw const AuthRequiredException();
    return session.accessToken;
  }

  Future<String> recoverAfterUnauthorized(String rejectedToken) async {
    final generation = _generation;
    final current = _session;
    if (current == null) throw const AuthRequiredException();
    if (_rotationUncertain) throw const RefreshUncertainException();
    if (current.accessToken != rejectedToken) return accessTokenForRequest();
    final renewed = await refreshSession();
    _checkGeneration(generation);
    return renewed.accessToken;
  }

  Future<AnythinkUser> getUser() async {
    _checkOpen();
    final generation = _generation;
    try {
      final response = await _transport.request('GET', [
        'users',
        'me',
      ], retryOnUnauthorized: true);
      final user = AnythinkUser.fromJson(objectFromJson(response.data, 'user'));
      _checkGeneration(generation);
      _emit(AuthStatus.authenticated, user: user);
      return user;
    } on AnythinkException catch (error) {
      if (generation == _generation &&
          !_closed &&
          _session != null &&
          _state.status != AuthStatus.reauthenticationRequired) {
        _emit(AuthStatus.temporarilyUnavailable, error: error);
      }
      rethrow;
    }
  }

  /// Clears local state even when the server is unavailable. A storage failure
  /// throws: callers must not report durable sign-out if persistence failed.
  Future<SignOutResult> signOut() async {
    _checkOpen();
    final previous = _session;
    final generation = ++_generation;
    _session = null;
    _rotationUncertain = false;
    _storageDirty = false;
    _emit(AuthStatus.signedOut);
    AnythinkException? storageError;
    try {
      await _persist(null, generation);
    } on SessionStorageException catch (error) {
      storageError = error;
    }
    AnythinkException? remoteError;
    if (previous != null) {
      try {
        await _transport.request(
          'POST',
          ['auth', 'v1', 'logout'],
          body: {'token': previous.refreshToken},
          authenticated: false,
        );
      } on AnythinkException catch (error) {
        remoteError = error;
      }
    }
    if (storageError != null) throw storageError;
    return SignOutResult(
      remoteRevoked: previous != null && remoteError == null,
      remoteError: remoteError,
    );
  }

  Future<void> _discardSession(Session session) async {
    try {
      await _transport.request(
        'POST',
        ['auth', 'v1', 'logout'],
        body: {'token': session.refreshToken},
        authenticated: false,
      );
    } on AnythinkException {
      /* Best-effort revocation; never commit stale state. */
    }
  }

  Future<String> signUp({
    required String firstName,
    required String lastName,
    required String email,
    required String password,
    String? referralCode,
    Map<String, String>? signupContext,
  }) async {
    final response = await _transport.request(
      'POST',
      ['auth', 'v1', 'register'],
      authenticated: false,
      body: {
        'first_name': firstName,
        'last_name': lastName,
        'email': email,
        'password': password,
        'referral_code': ?referralCode,
        'signup_context': ?signupContext,
      },
    );
    return stringFromJson(response.data, 'registration acknowledgment');
  }

  Future<String> confirmEmail({
    required String email,
    required String token,
  }) async {
    final response = await _transport.request(
      'POST',
      ['auth', 'v1', 'confirm-email'],
      authenticated: false,
      body: {'email': email, 'token': token},
    );
    return stringFromJson(response.data, 'confirmation acknowledgment');
  }

  Future<void> resendConfirmation(String email) async {
    await _transport.request(
      'POST',
      ['auth', 'v1', 'resend-confirm-email'],
      query: {'email': email},
      authenticated: false,
    );
  }

  Future<void> requestPasswordReset(String email) async {
    await _transport.request(
      'POST',
      ['auth', 'v1', 'send-password-reset'],
      query: {'email': email},
      authenticated: false,
    );
  }

  Future<void> confirmPasswordReset({
    required String email,
    required String token,
    required String password,
  }) async {
    await _transport.request(
      'POST',
      ['auth', 'v1', 'confirm-password-reset'],
      authenticated: false,
      body: {'email': email, 'token': token, 'password': password},
    );
  }

  Future<void> updateProfile({
    required String firstName,
    required String lastName,
  }) async {
    await _transport.request(
      'PUT',
      ['users', 'me'],
      body: {'first_name': firstName, 'last_name': lastName},
    );
    // A separate getUser call refreshes identity. Do not turn a successful
    // mutation into an apparent failure because a follow-up read failed.
    _emit(AuthStatus.authenticated);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _transport.request(
      'PUT',
      ['users', 'me', 'password'],
      body: {'current_password': currentPassword, 'new_password': newPassword},
    );
  }

  Future<List<Object?>> getPermissions() async {
    final response = await _transport.request('GET', [
      'users',
      'me',
      'permissions',
    ], retryOnUnauthorized: true);
    return listFromJson(response.data, 'permissions');
  }

  Future<bool> hasPermission(String name) =>
      _boolean('has-permission', {'permissionName': name});
  Future<bool> hasRole(String name) => _boolean('has-role', {'roleName': name});
  Future<bool> isAdmin() => _boolean('is-admin', null);
  Future<bool> _boolean(String action, Map<String, String>? query) async {
    final response = await _transport.request(
      'GET',
      ['users', 'me', action],
      query: query,
      retryOnUnauthorized: true,
    );
    return boolFromJson(response.data, action);
  }

  Future<List<AuthProviderInfo>> getProviders() async {
    final response = await _transport.request('GET', [
      'auth',
      'v1',
      'providers',
    ], authenticated: false);
    return List.unmodifiable(
      listFromJson(
        response.data,
      ).map((value) => AuthProviderInfo.fromJson(objectFromJson(value))),
    );
  }

  /// Starts the provider's browser flow. The exact redirect URI must be allowed
  /// by the project and registered with the provider. Attribution applies only
  /// when this flow creates a new user; it is not sent to the callback endpoint.
  Future<Uri> getAuthorizationUrl(
    WebProvider provider,
    Uri redirectUri, {
    SignupAttribution? attribution,
  }) async {
    final response = await _transport.request(
      'GET',
      ['auth', 'v1', provider.name, 'authorize'],
      authenticated: false,
      query: {
        'redirectUri': redirectUri.toString(),
        ...?attribution?.toQueryParameters(),
      },
    );
    final url = Uri.tryParse(
      stringFromJson(
        objectFromJson(response.data)['authorization_url'],
        'authorization_url',
      ),
    );
    if (url == null ||
        url.scheme != 'https' ||
        !url.hasAuthority ||
        url.userInfo.isNotEmpty) {
      throw const ProtocolException(
        'The provider returned an invalid authorization URL.',
      );
    }
    return url;
  }

  Future<JsonObject> getInvitation(String inviteToken) async {
    final response = await _transport.request('GET', [
      'users',
      'invites',
      inviteToken,
    ], authenticated: false);
    return objectFromJson(response.data, 'invitation');
  }

  Future<void> acceptInvitation({
    required String inviteToken,
    required String firstName,
    required String lastName,
    required String password,
  }) async {
    await _transport.request(
      'POST',
      ['users', 'invites', inviteToken],
      authenticated: false,
      body: {
        'first_name': firstName,
        'last_name': lastName,
        'password': password,
      },
    );
  }

  /// Disposes local resources without signing out the persisted account.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    _session = null;
    await _storeTail;
    await _events.close();
  }
}
