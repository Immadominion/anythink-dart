import 'package:flutter/material.dart';

import 'configuration.dart';
import 'ui/app_theme.dart';
import 'ui/session_screen.dart';

export 'configuration.dart';
export 'ui/session_screen.dart' show SessionValidationScreen;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NativeHostApp());
}

class NativeHostApp extends StatelessWidget {
  const NativeHostApp({
    super.key,
    this.configuration = NativeHostConfiguration.environment,
  });
  final NativeHostConfiguration configuration;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Anythink Playground',
    debugShowCheckedModeBanner: false,
    theme: buildAppTheme(),
    home: SessionValidationScreen(configuration: configuration),
  );
}
