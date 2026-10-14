import 'package:anythink_flutter/anythink_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// These tests exercise lifecycle callbacks, not rendering. Use the ordinary
// async test zone so closing the real core stream controller is not trapped in
// the widget harness's fake scheduler.
Future<void> settleChecks() => Future<void>(() {});

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final originalErrorHandler = FlutterError.onError;
  late List<FlutterErrorDetails> diagnostics;

  setUp(() {
    diagnostics = [];
    FlutterError.onError = diagnostics.add;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  });
  tearDown(() {
    FlutterError.onError = originalErrorHandler;
  });
  AnythinkClient client() => AnythinkClient(
    apiOrigin: Uri.parse('https://api.example.test'),
    projectId: 'project-a',
  );

  test(
    'attach is explicit and disposing does not close the core client',
    () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final core = client();
      addTearDown(core.close);
      final bridge = AnythinkLifecycleBridge(auth: core.auth);

      expect(bridge.isAttached, isFalse);
      bridge.attach();
      bridge.attach();
      expect(bridge.isAttached, isTrue);
      bridge.detach();
      expect(bridge.isAttached, isFalse);
      bridge.attach();
      bridge.dispose();
      bridge.dispose();

      expect(bridge.isAttached, isFalse);
      expect(bridge.isDisposed, isTrue);
      expect(bridge.attach, throwsStateError);
      expect(await core.auth.refreshIfNeeded(), isNull);
      expect(core.auth.state.status, AuthStatus.signedOut);
    },
  );

  test('foreground checks coalesce and report actual core failures', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final core = client();
    await core.close();
    final errors = <Object>[];
    final bridge = AnythinkLifecycleBridge(
      auth: core.auth,
      onError: (error, _) => errors.add(error),
    );
    addTearDown(bridge.dispose);
    bridge.attach();

    for (var i = 0; i < 4; i++) {
      bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
    }
    await settleChecks();

    expect(errors, hasLength(1));
    expect(errors.single, isA<ClientClosedException>());
    bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleChecks();
    expect(errors, hasLength(2));
  });

  test('detached and background events do not call the auth client', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final core = client();
    await core.close();
    final errors = <Object>[];
    final bridge = AnythinkLifecycleBridge(
      auth: core.auth,
      onError: (error, _) => errors.add(error),
    );
    addTearDown(bridge.dispose);

    bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
    bridge.attach();
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      bridge.didChangeAppLifecycleState(state);
    }
    await settleChecks();
    bridge.detach();
    bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleChecks();

    expect(errors, isEmpty);
  });

  test('attaching to a resumed app starts a check', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final core = client();
    await core.close();
    final errors = <Object>[];
    final bridge = AnythinkLifecycleBridge(
      auth: core.auth,
      onError: (error, _) => errors.add(error),
    );
    addTearDown(bridge.dispose);

    bridge.attach();
    await settleChecks();

    expect(errors, hasLength(1));
    expect(errors.single, isA<ClientClosedException>());
  });

  test('unhandled foreground failure reaches Flutter diagnostics', () async {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final core = client();
    await core.close();
    final bridge = AnythinkLifecycleBridge(auth: core.auth);
    addTearDown(bridge.dispose);
    bridge.attach();

    bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settleChecks();

    expect(diagnostics.single.exception, isA<ClientClosedException>());
    expect(bridge.isAttached, isTrue);
  });

  test(
    'a failing application error callback does not poison later checks',
    () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final core = client();
      await core.close();
      var errors = 0;
      final bridge = AnythinkLifecycleBridge(
        auth: core.auth,
        onError: (_, _) {
          errors++;
          throw StateError('application callback failed');
        },
      );
      addTearDown(bridge.dispose);
      bridge.attach();

      bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settleChecks();
      expect(diagnostics.last.exception, isA<StateError>());
      bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settleChecks();

      expect(diagnostics.last.exception, isA<StateError>());
      expect(errors, 2);
    },
  );
}
