import 'dart:async';

/// A one-shot cancellation signal. Create a fresh token for each operation or
/// share one deliberately to cancel a group of requests.
final class CancellationToken {
  final _signal = Completer<void>();
  bool get isCancelled => _signal.isCompleted;
  Future<void> get whenCancelled => _signal.future;
  void cancel() {
    if (!_signal.isCompleted) _signal.complete();
  }
}
