import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'logo.dart';
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
    // Couleurs du logo : jaune #FFC93C sur bleu nuit #12204A.
    final scheme = ColorScheme.fromSeed(
      seedColor: kBrandYellow,
      brightness: Brightness.dark,
    ).copyWith(
      primary: kBrandYellow,
      onPrimary: kBrandNavy,
      surface: const Color(0xFF0C1533),
      surfaceContainerHighest: const Color(0xFF1C2A55),
      surfaceContainerHigh: const Color(0xFF172449),
      surfaceContainer: const Color(0xFF13203F),
      outline: const Color(0xFF6B7AA6),
      outlineVariant: const Color(0xFF34436E),
    );
    return MaterialApp(
      title: 'VoxLiso',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0C1533),
        appBarTheme: const AppBarTheme(backgroundColor: kBrandNavy),
      ),
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
