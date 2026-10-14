import 'package:flutter/material.dart';

import 'configuration.dart';
import 'ui/app_theme.dart';
import 'ui/session_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NotesDemoApp());
}

class NotesDemoApp extends StatelessWidget {
  const NotesDemoApp({
    super.key,
    this.configuration = NativeHostConfiguration.environment,
  });
  final NativeHostConfiguration configuration;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Anythink Notes',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: SessionValidationScreen(
      configuration: configuration,
      showRecords: true,
    ),
  );
}
