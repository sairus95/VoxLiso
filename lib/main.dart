import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'reader_screen.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // L'analyse de l'image suppose un téléphone tenu en portrait.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final settings = await AppSettings.load();
  runApp(VoxLisoApp(settings: settings));
}

class VoxLisoApp extends StatelessWidget {
  const VoxLisoApp({super.key, required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFFC107),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'VoxLiso',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      home: ReaderScreen(settings: settings),
    );
  }
}
