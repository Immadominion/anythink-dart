import 'dart:async';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'push_native_exception.dart';

enum PushSyncStatus {
  signedOut,
  permissionRequired,
  permissionDenied,
  apnsPending,
  tokenUnavailable,
  registered,
  alreadyRegistered,
  superseded,
}

/// Registration metadata only. Device credentials are never exposed here.
final class PushSyncResult {
  const PushSyncResult(this.status, {this.registration});
  final PushSyncStatus status;
  final DeviceRegistration? registration;

  @override
  String toString() => 'PushSyncResult(${status.name})';
}

/// Connects an app-owned Firebase instance to an app-owned Anythink client.
///
/// Initialize Firebase and restore/sign in to Anythink in your application.
/// [start] observes token/session changes and foreground resumes, but never
/// requests notification permission or changes Firebase auto-initialization.
/// Only [requestPermission] requests OS permission.
///
/// Stopping this adapter does not revoke previously registered devices. Anythink
/// does not document a consumer unregister/rebind endpoint. Account switching
/// can return a backend conflict, and existing notifications may still arrive.
final class AnythinkFirebasePush with WidgetsBindingObserver {
  AnythinkFirebasePush({
    required this.client,
    required this.messaging,
    JsonObject metadata = const {},
    this.onError,
  }) : metadata = _snapshotMetadata(metadata);

  final AnythinkClient client;
  final FirebaseMessaging messaging;

  /// An immutable JSON snapshot taken before any native or network work.
  final JsonObject metadata;

  /// Receives failures from automatic token/auth/lifecycle synchronization.
  /// Explicit method calls report errors through their returned futures.
  /// Without a callback, automatic failures use [FlutterError.reportError].
  final void Function(Object error, StackTrace stackTrace)? onError;

  final _results = StreamController<PushSyncResult>.broadcast();
  StreamSubscription<String>? _tokenSubscription;
  StreamSubscription<AuthState>? _authSubscription;
  WidgetsBinding? _binding;
  Future<void> _tail = Future.value();
  Future<RemoteMessage?>? _initialMessageOperation;
  bool _initialMessageConsumed = false;
  CancellationToken? _activeCancellation;
  bool _started = false;
  bool _disposed = false;
  int _epoch = 0;
  int? _observedGeneration;
  int? _registeredGeneration;
  String? _registeredToken;
  DeviceRegistration? _registration;

  bool get isStarted => _started;
  bool get isDisposed => _disposed;
  Stream<PushSyncResult> get results => _results.stream;

  /// Raw foreground messages. The application owns subscriptions and routing.
  /// Receipt is not an Anythink action-button response.
  Stream<RemoteMessage> get messages => FirebaseMessaging.onMessage;

  /// Raw taps from background. This does not consume the terminated launch tap.
  Stream<RemoteMessage> get openedMessages =>
      FirebaseMessaging.onMessageOpenedApp;

  /// Returns at most one nonnull terminated launch message per adapter instance.
  ///
  /// Only one native lookup runs at a time. Concurrent callers other than its
  /// owner receive null after success, or the same redacted error on failure.
  /// A later explicit call may retry after null or an error. Disposal rejects
  /// late results. This is not a process-wide guard across adapter instances;
  /// keep one application-owned adapter and validate routing against its session.
  Future<RemoteMessage?> getInitialMessage() {
    _checkUsable();
    if (_initialMessageConsumed) return Future.value();
    final pending = _initialMessageOperation;
    if (pending != null) return pending.then((_) => null);
    final operation = _readInitialMessage();
    _initialMessageOperation = operation;
    return operation;
  }

  Future<RemoteMessage?> _readInitialMessage() async {
    try {
      final message = await _native(
        PushNativeOperation.initialMessage,
        messaging.getInitialMessage,
      );
      _checkUsable();
      if (message != null) _initialMessageConsumed = true;
      return message;
    } catch (_) {
      _checkUsable();
      rethrow;
    } finally {
      _initialMessageOperation = null;
    }
  }

  void _checkUsable() {
    if (_disposed) throw StateError('This push adapter has been disposed.');
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      throw UnsupportedError('This adapter supports Android and iOS only.');
    }
  }

  /// Starts listeners once and checks the current token without prompting.
  /// A failed first synchronization leaves the listeners attached for retry.
  Future<PushSyncResult> start() {
    _checkUsable();
    if (!_started) {
      _started = true;
      _observedGeneration = client.auth.generation;
      _binding = WidgetsBinding.instance..addObserver(this);
      _tokenSubscription = messaging.onTokenRefresh.listen(
        (_) => _automaticallySynchronize(),
        onError: (Object _, StackTrace _) => _reportError(
          const PushNativeException(PushNativeOperation.tokenRefresh),
          StackTrace.current,
        ),
      );
      _authSubscription = client.auth.states.listen(
        (state) {
          if (client.auth.generation != _observedGeneration) {
            _observedGeneration = client.auth.generation;
            _invalidate();
          }
          if (state.status == AuthStatus.authenticated ||
              state.status == AuthStatus.signedOut) {
            _automaticallySynchronize();
          }
        },
        onError: _reportError,
        onDone: _invalidate,
      );
    }
    return synchronize();
  }

  /// The only adapter method that can display the OS permission prompt.
  /// After it succeeds, call [synchronize] to register the device.
  Future<NotificationSettings> requestPermission({
    bool alert = true,
    bool badge = true,
    bool sound = true,
    bool provisional = false,
  }) {
    _checkUsable();
    return _native(
      PushNativeOperation.permissionRequest,
      () => messaging.requestPermission(
        alert: alert,
        badge: badge,
        sound: sound,
        provisional: provisional,
      ),
    );
  }

  /// Reads permission and native token, then registers for the current session.
  /// Calls are serialized. Successful duplicate tokens in one auth generation
  /// are coalesced. Set [force] to refresh the backend's last-seen timestamp or
  /// restore a device entry removed by an administrator. Failed writes are not
  /// automatically replayed.
  Future<PushSyncResult> synchronize({bool force = false}) {
    _checkUsable();
    if (!_started) throw StateError('Call start before synchronizing push.');
    final epoch = _epoch;
    final generation = client.auth.generation;
    final operation = _tail.then((_) async {
      try {
        return await _synchronize(epoch, generation, force);
      } catch (_) {
        if (!_isCurrent(epoch, generation)) {
          return const PushSyncResult(PushSyncStatus.superseded);
        }
        rethrow;
      }
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  bool _isCurrent(int epoch, int generation) =>
      !_disposed &&
      _started &&
      epoch == _epoch &&
      generation == client.auth.generation;

  Future<PushSyncResult> _synchronize(
    int epoch,
    int generation,
    bool force,
  ) async {
    if (!_isCurrent(epoch, generation)) {
      return const PushSyncResult(PushSyncStatus.superseded);
    }
    PushSyncResult result(PushSyncStatus status, [DeviceRegistration? device]) {
      final value = PushSyncResult(status, registration: device);
      if (_isCurrent(epoch, generation)) _results.add(value);
      return value;
    }

    if (client.auth.currentSession == null ||
        client.auth.state.status == AuthStatus.reauthenticationRequired) {
      return result(PushSyncStatus.signedOut);
    }
    final settings = await _native(
      PushNativeOperation.notificationSettings,
      messaging.getNotificationSettings,
    );
    if (!_isCurrent(epoch, generation)) {
      return const PushSyncResult(PushSyncStatus.superseded);
    }
    if (settings.authorizationStatus == AuthorizationStatus.notDetermined) {
      return result(PushSyncStatus.permissionRequired);
    }
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      return result(PushSyncStatus.permissionDenied);
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final apns = await _native(
        PushNativeOperation.apnsToken,
        messaging.getAPNSToken,
      );
      if (!_isCurrent(epoch, generation)) {
        return const PushSyncResult(PushSyncStatus.superseded);
      }
      if (apns == null || apns.isEmpty) {
        return result(PushSyncStatus.apnsPending);
      }
    }
    // Re-read rather than trusting a queued token event: rotation can overtake
    // permission/APNs work. Firebase is the source of the current token.
    final token = await _native(
      PushNativeOperation.deviceToken,
      messaging.getToken,
    );
    if (!_isCurrent(epoch, generation)) {
      return const PushSyncResult(PushSyncStatus.superseded);
    }
    if (token == null || token.isEmpty) {
      return result(PushSyncStatus.tokenUnavailable);
    }
    if (!force &&
        _registeredGeneration == generation &&
        _registeredToken == token) {
      return result(PushSyncStatus.alreadyRegistered, _registration);
    }
    final cancellation = CancellationToken();
    _activeCancellation = cancellation;
    try {
      final device = await client.push.registerDevice(
        provider: PushProvider.fcm,
        token: token,
        metadata: {...metadata, 'platform': defaultTargetPlatform.name},
        cancellation: cancellation,
      );
      if (!_isCurrent(epoch, generation)) {
        return const PushSyncResult(PushSyncStatus.superseded);
      }
      _registeredGeneration = generation;
      _registeredToken = token;
      _registration = device;
      return result(PushSyncStatus.registered, device);
    } catch (_) {
      if (!_isCurrent(epoch, generation)) {
        return const PushSyncResult(PushSyncStatus.superseded);
      }
      rethrow;
    } finally {
      if (identical(_activeCancellation, cancellation)) {
        _activeCancellation = null;
      }
    }
  }

  void _automaticallySynchronize() {
    if (!_started || _disposed) return;
    unawaited(synchronize().then<void>((_) {}, onError: _reportError));
  }

  Future<T> _native<T>(
    PushNativeOperation operation,
    Future<T> Function() action,
  ) async {
    try {
      return await action();
    } on MissingPluginException {
      throw PushNativeException(
        operation,
        failure: PushNativeFailure.unavailable,
      );
    } catch (_) {
      // Native/Firebase messages and details can include registration tokens.
      // Do not forward them to automatic callbacks or FlutterError logging.
      throw PushNativeException(operation);
    }
  }

  void _reportError(Object error, StackTrace stack) {
    final handler = onError;
    if (handler != null) {
      try {
        handler(error, stack);
      } catch (callbackError, callbackStack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: callbackError,
            stack: callbackStack,
            library: 'anythink_flutter_push',
            context: ErrorDescription(
              'while reporting a push registration error',
            ),
          ),
        );
      }
    } else {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'anythink_flutter_push',
          context: ErrorDescription(
            'while synchronizing the native push token',
          ),
        ),
      );
    }
  }

  void _invalidate() {
    ++_epoch;
    _activeCancellation?.cancel();
    _registeredGeneration = null;
    _registeredToken = null;
    _registration = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _automaticallySynchronize();
  }

  /// Stops owned subscriptions and pending HTTP work. Does not revoke a token,
  /// clear Anythink server data, close the client, or change Firebase globals.
  /// Native plugin futures cannot be cancelled; their late results are fenced.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _started = false;
    _invalidate();
    _binding?.removeObserver(this);
    _binding = null;
    await Future.wait([
      if (_tokenSubscription != null) _tokenSubscription!.cancel(),
      if (_authSubscription != null) _authSubscription!.cancel(),
    ]);
    await _results.close();
  }
}

JsonObject _snapshotMetadata(JsonObject value) =>
    _snapshotJson(value, Set<Object>.identity())! as JsonObject;

Object? _snapshotJson(Object? value, Set<Object> ancestors) {
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is double && value.isFinite) return value;
  if (value is Map<String, Object?>) {
    if (!ancestors.add(value)) {
      throw ArgumentError('Push metadata must not contain cycles.');
    }
    try {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key: _snapshotJson(entry.value, ancestors),
      });
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is List<Object?>) {
    if (!ancestors.add(value)) {
      throw ArgumentError('Push metadata must not contain cycles.');
    }
    try {
      return List<Object?>.unmodifiable(
        value.map((item) => _snapshotJson(item, ancestors)),
      );
    } finally {
      ancestors.remove(value);
    }
  }
  throw ArgumentError('Push metadata must contain only finite JSON values.');
}
