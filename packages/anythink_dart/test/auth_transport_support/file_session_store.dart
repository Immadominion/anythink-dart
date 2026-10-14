import 'dart:io';

import 'package:anythink_dart/src/auth/session_store.dart';

/// Test persistence uses actual filesystem reads and atomic file replacement.
/// This deliberately does not claim to be encrypted production storage.
final class FileSessionStore implements SessionStore {
  FileSessionStore(this.file);
  final File file;

  @override
  Future<String?> read() async =>
      await file.exists() ? file.readAsString() : null;

  @override
  Future<void> write(String value) async {
    final next = File('${file.path}.next');
    await next.writeAsString(value, flush: true);
    await next.rename(file.path);
  }

  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

/// Failure injection around the real filesystem store, only for storage tests.
final class FaultSessionStore implements SessionStore {
  FaultSessionStore(this.inner);
  final SessionStore inner;
  bool failRead = false;
  bool failWrite = false;
  bool failClear = false;
  int writes = 0;
  int clears = 0;
  Future<void> Function(String)? beforeWrite;
  Future<void> Function()? beforeClear;

  @override
  Future<String?> read() {
    if (failRead) throw const FileSystemException('Injected test read failure');
    return inner.read();
  }

  @override
  Future<void> write(String value) async {
    writes++;
    await beforeWrite?.call(value);
    if (failWrite) {
      throw const FileSystemException('Injected test write failure');
    }
    await inner.write(value);
  }

  @override
  Future<void> clear() async {
    clears++;
    await beforeClear?.call();
    if (failClear) {
      throw const FileSystemException('Injected test clear failure');
    }
    await inner.clear();
  }
}
