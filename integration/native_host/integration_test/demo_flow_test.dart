import 'dart:convert';
import 'dart:io';

import 'package:anythink_native_host/demo_main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real notes demo sign-in, read, create and sign-out',
    (tester) async {
      final cache = await getTemporaryDirectory();
      final inputFile = File('${cache.path}/anythink-demo-input.json');
      final input =
          jsonDecode(await inputFile.readAsString()) as Map<String, dynamic>;
      await inputFile.delete();
      try {
        await tester.pumpWidget(const NotesDemoApp());
        await tester.pumpAndSettle();
        if (input['phase'] == 'restore') {
          await _until(tester, find.text('Use saved session'));
          await tester.tap(find.text('Use saved session'));
          await _until(tester, find.text('Your notes.'));
          await _until(tester, find.text('A calmer place for ideas'));
          debugPrint('DEMO_PASS restart_restores_session_and_records');
          await tester.ensureVisible(find.text('Sign out'));
          await tester.tap(find.text('Sign out'));
          await _until(tester, find.text('Welcome back.'));
          expect(find.text('Use saved session'), findsNothing);
          debugPrint('DEMO_PASS sign_out_clears_workspace');
          return;
        }
        await tester.enterText(
          find.byKey(const Key('email-field')),
          input['email'] as String,
        );
        await tester.enterText(
          find.byKey(const Key('password-field')),
          input['password'] as String,
        );
        await tester.tap(find.byKey(const Key('sign-in')));
        await _until(tester, find.text('Your notes.'));
        await _until(tester, find.text('A calmer place for ideas'));
        debugPrint('DEMO_PASS sign_in_and_real_records');
        await tester.tap(find.byKey(const Key('new-note')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('note-title')),
          'A session worth keeping',
        );
        await tester.enterText(
          find.byKey(const Key('note-body')),
          'A real note, saved to Anythink from my phone.',
        );
        await tester.ensureVisible(find.byKey(const Key('save-note')));
        await tester.tap(find.byKey(const Key('save-note')));
        await _until(tester, find.text('A session worth keeping'));
        await _untilGone(tester, find.byKey(const Key('save-note')));
        await tester.tap(find.byTooltip('Reload notes'));
        await tester.pumpAndSettle();
        await _until(tester, find.text('A session worth keeping'));
        debugPrint('DEMO_PASS create_and_read_back');
        if (input['keep_session'] == true) return;
        await tester.ensureVisible(find.text('Sign out'));
        await tester.tap(find.text('Sign out'));
        await _until(tester, find.text('Welcome back.'));
        expect(find.text('A session worth keeping'), findsNothing);
        expect(find.text('Use saved session'), findsNothing);
        debugPrint('DEMO_PASS sign_out_clears_workspace');
      } catch (_) {
        fail('DEMO_FAILED redacted; inspect the app and safe API reports');
      } finally {
        input.clear();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _until(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    if (target.evaluate().isNotEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  throw StateError('Expected demo screen did not appear');
}

Future<void> _untilGone(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    if (target.evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  throw StateError('Demo save did not finish');
}
