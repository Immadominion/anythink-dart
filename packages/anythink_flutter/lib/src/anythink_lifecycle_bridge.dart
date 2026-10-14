import 'dart:async';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:flutter/widgets.dart';

/// Reconciles an existing session when a Flutter app returns to the foreground.
///
/// Initialize Flutter, construct the core client and explicitly await
/// `auth.restoreSession()` before attaching this bridge. The bridge does not
/// restore a session, own the auth client, or shut it down.
///
/// Repeated resume events share one in-flight refresh check. Refresh-token
/// serialization and logout/account-switch protection remain the core's
/// responsibility. No background timer or background refresh is introduced.
final class AnythinkLifecycleBridge with WidgetsBindingObserver {
  AnythinkLifecycleBridge({required this.auth, this.onError});

  final AnythinkAuth auth;

  /// Receives asynchronous foreground-check failures.
  ///
  /// Without a callback, failures are reported through [FlutterError.reportError].
  /// A failed check does not detach the bridge or erase the session.
  final void Function(Object error, StackTrace stackTrace)? onError;

  WidgetsBinding? _binding;
  Future<void>? _inFlight;
  bool _disposed = false;

  bool get isAttached => _binding != null;
  bool get isDisposed => _disposed;

  /// Starts observing the initialized binding. Repeated calls are harmless.
  ///
  /// If the application is already resumed, a refresh check starts immediately.
  void attach() {
    if (_disposed) {
      throw StateError(
        'A disposed AnythinkLifecycleBridge cannot be attached.',
      );
    }
    if (_binding != null) return;
    final binding = WidgetsBinding.instance;
    _binding = binding;
    binding.addObserver(this);
    if (binding.lifecycleState == AppLifecycleState.resumed) {
      _checkSession();
    }
  }

  /// Stops receiving lifecycle events without closing the shared auth client.
  ///
  /// An already-started check is not cancelled: it may also serve requests made
  /// by the application's core client. Its failure is still reported.
  void detach() {
    _binding?.removeObserver(this);
    _binding = null;
  }

  /// Permanently detaches this bridge. Repeated calls are harmless.
  void dispose() {
    if (_disposed) return;
    detach();
    _disposed = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || _binding == null || state != AppLifecycleState.resumed) {
      return;
    }
    _checkSession();
  }

  void _checkSession() {
    if (_inFlight != null) return;
    // Assign the shared Future before invoking auth, so even synchronous
    // reentrant lifecycle notifications cannot start another check.
    final operation = Future<void>.microtask(_refresh);
    _inFlight = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_inFlight, operation)) _inFlight = null;
      }),
    );
  }

  Future<void> _refresh() async {
    try {
      await auth.refreshIfNeeded();
    } catch (error, stack) {
      final handler = onError;
      if (handler == null) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'anythink_flutter',
            context: ErrorDescription('while checking the foreground session'),
          ),
        );
      } else {
        try {
          handler(error, stack);
        } catch (callbackError, callbackStack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: callbackError,
              stack: callbackStack,
              library: 'anythink_flutter',
              context: ErrorDescription(
                'while reporting a session-check error',
              ),
            ),
          );
        }
      }
    }
  }
}
