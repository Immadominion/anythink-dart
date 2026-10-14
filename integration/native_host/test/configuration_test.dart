import 'package:anythink_native_host/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const configured = NativeHostConfiguration(
  apiOrigin: 'https://example.test',
  projectId: 'test-project',
);

void main() {
  testWidgets('missing configuration disables sign-in and hides restore', (
    tester,
  ) async {
    await tester.pumpWidget(
      const NativeHostApp(
        configuration: NativeHostConfiguration(apiOrigin: '', projectId: ''),
      ),
    );
    expect(find.text('Connect a project to enable sign-in.'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('sign-in'))).onPressed,
      isNull,
    );
    expect(find.text('Use saved session'), findsNothing);
  });

  testWidgets('invalid origin keeps request controls disabled', (tester) async {
    await tester.pumpWidget(
      const NativeHostApp(
        configuration: NativeHostConfiguration(
          apiOrigin: 'http://example.test',
          projectId: 'test-project',
        ),
      ),
    );
    expect(
      find.text('Check your project settings to enable sign-in.'),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('sign-in'))).onPressed,
      isNull,
    );
  });

  testWidgets('empty credentials are rejected locally', (tester) async {
    await tester.pumpWidget(const NativeHostApp(configuration: configured));
    await tester.tap(find.byKey(const Key('sign-in')));
    await tester.pump();
    expect(find.text('Enter your email.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(find.text('Please wait…'), findsNothing);
  });

  testWidgets('password is obscured until explicitly revealed', (tester) async {
    await tester.pumpWidget(const NativeHostApp(configuration: configured));
    final password = find.descendant(
      of: find.byKey(const Key('password-field')),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(password).obscureText, isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(tester.widget<EditableText>(password).obscureText, isFalse);
    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(tester.widget<EditableText>(password).obscureText, isTrue);
  });

  testWidgets('project diagnostics stay behind the details action', (
    tester,
  ) async {
    await tester.pumpWidget(const NativeHostApp(configuration: configured));
    expect(find.text('https://example.test'), findsNothing);
    expect(find.textContaining('Native sign-in'), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('https://example.test'), findsOneWidget);
    expect(find.text('test-project'), findsOneWidget);
    expect(find.text('Signed out'), findsOneWidget);
  });

  testWidgets('invalid origin is not echoed in project details', (
    tester,
  ) async {
    await tester.pumpWidget(
      const NativeHostApp(
        configuration: NativeHostConfiguration(
          apiOrigin: 'https://demo:do-not-display@example.test?token=hidden',
          projectId: 'test-project',
        ),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid'), findsOneWidget);
    expect(find.textContaining('do-not-display'), findsNothing);
    expect(find.textContaining('token=hidden'), findsNothing);
  });

  testWidgets(
    'small screen and large text can reach the form without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(const NativeHostApp(configuration: configured));
      await tester.ensureVisible(find.byKey(const Key('sign-in')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pump();
      expect(find.text('Enter your email.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
