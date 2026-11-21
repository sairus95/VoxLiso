import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'reader_screen.dart';
import 'settings.dart';
import 'tutorial.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait (téléphone tenu en main) ou paysage (téléphone posé face à la télé).
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
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
      home: settings.tutorialSeen
          ? ReaderScreen(settings: settings)
          : Builder(
              builder: (context) => TutorialScreen(
                settings: settings,
                onDone: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(builder: (_) => ReaderScreen(settings: settings)),
                ),
              ),
            ),
    );
  }
}
