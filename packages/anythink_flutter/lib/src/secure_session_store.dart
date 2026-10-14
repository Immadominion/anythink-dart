import 'dart:async';
import 'dart:convert';

import 'package:anythink_dart/anythink_dart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The secure-persistence operation that failed.
enum SecureSessionStoreOperation { read, write, clear }

/// A failure category that is safe to include in application diagnostics.
enum SecureSessionStoreFailure {
  /// The native storage implementation reported an error.
  platform,

  /// Flutter could not find the platform storage implementation.
  unavailable,

  /// An unexpected exception occurred at the storage boundary.
  unexpected,
}

/// A redacted storage failure.
///
/// Native error messages, details, session values and the original exception are
/// intentionally not retained. They can contain sensitive values. This error
/// never means that stored credentials have been deleted or invalidated.
final class SecureSessionStoreException implements Exception {
  const SecureSessionStoreException({
    required this.operation,
    required this.failure,
    this.platformCode,
  });

  final SecureSessionStoreOperation operation;
  final SecureSessionStoreFailure failure;

  /// A recognized upstream platform error code, never an arbitrary value.
  final String? platformCode;

  @override
  String toString() =>
      'SecureSessionStoreException(${operation.name}, ${failure.name}'
      '${platformCode == null ? '' : ', $platformCode'})';
}

/// Persists the core SDK's opaque session envelope with Flutter secure storage.
///
/// Use one store and one session owner per project in an application isolate.
/// Calls on this instance are ordered, but this is not a cross-isolate lock.
/// The core SDK owns envelope serialization, migration and validation.
///
/// A complete envelope is written under one key. This avoids separate writes
/// for a token pair; it does not promise transactional durability across process
/// death or recover a refresh response lost after server-side token rotation.
///
/// Flutter bindings must be initialized before the first storage operation.
/// See the package README for native entitlements and Android backup exclusions.
final class SecureSessionStore implements SessionStore {
  SecureSessionStore({
    required Uri apiOrigin,
    required String projectId,
    FlutterSecureStorage? storage,
    bool allowWebPersistence = false,
  }) : storageKey = _storageKey(apiOrigin, projectId),
       _storage = storage ?? _defaultStorage {
    if (kIsWeb && !allowWebPersistence) {
      throw UnsupportedError(
        'Browser session persistence requires explicit '
        'allowWebPersistence: true and an application security review.',
      );
    }
  }

  static const _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false, migrateWithBackup: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
  );

  /// The stable project-scoped key, useful when planning an explicit migration.
  ///
  /// It contains encoded public configuration, never session credentials.
  final String storageKey;

  final FlutterSecureStorage _storage;
  Future<void> _pending = Future<void>.value();

  @override
  Future<String?> read() => _run(
    SecureSessionStoreOperation.read,
    () => _storage.read(key: storageKey),
  );

  @override
  Future<void> write(String value) => _run(
    SecureSessionStoreOperation.write,
    () => _storage.write(key: storageKey, value: value),
  );

  /// Deletes only this project's envelope, never other secure-storage entries.
  @override
  Future<void> clear() => _run(
    SecureSessionStoreOperation.clear,
    () => _storage.delete(key: storageKey),
  );

  Future<T> _run<T>(
    SecureSessionStoreOperation operation,
    Future<T> Function() action,
  ) {
    final result = _pending.then((_) async {
      try {
        return await action();
      } on PlatformException catch (error, stack) {
        Error.throwWithStackTrace(
          SecureSessionStoreException(
            operation: operation,
            failure: SecureSessionStoreFailure.platform,
            platformCode: _safeCode(error.code),
          ),
          stack,
        );
      } on MissingPluginException catch (_, stack) {
        Error.throwWithStackTrace(
          SecureSessionStoreException(
            operation: operation,
            failure: SecureSessionStoreFailure.unavailable,
          ),
          stack,
        );
      } catch (_, stack) {
        Error.throwWithStackTrace(
          SecureSessionStoreException(
            operation: operation,
            failure: SecureSessionStoreFailure.unexpected,
          ),
          stack,
        );
      }
    });
    // An unsuccessful operation is returned to its caller but must not poison
    // the queue. Later operations may succeed after a device is unlocked.
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static String? _safeCode(String code) {
    // A shape check cannot prove that an arbitrary code is not a credential.
    // Preserve only fixed codes emitted by the supported upstream platforms.
    const knownCodes = {
      'Exception encountered',
      'Unexpected security result code',
      'Missing Parameter',
      'null',
      'unsupported_platform',
    };
    return knownCodes.contains(code) ? code : null;
  }

  static String _storageKey(Uri origin, String projectId) {
    if (origin.scheme.toLowerCase() != 'https' ||
        origin.host.isEmpty ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/')) {
      throw ArgumentError(
        'apiOrigin must be an HTTPS origin without credentials, '
        'a path, a query or a fragment.',
      );
    }
    if (projectId.trim().isEmpty) {
      throw ArgumentError('projectId must not be empty.');
    }
    final normalized = Uri(
      scheme: 'https',
      host: origin.host.toLowerCase(),
      port: origin.port == 443 ? null : origin.port,
    );
    final namespace = jsonEncode([normalized.toString(), projectId]);
    final encoded = base64Url
        .encode(utf8.encode(namespace))
        .replaceAll('=', '');
    return 'anythink.session.v1.$encoded';
  }
}
