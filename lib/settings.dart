import 'package:shared_preferences/shared_preferences.dart';

/// Réglages de l'application, conservés entre deux utilisations.
class AppSettings {
  AppSettings._(this._prefs);

  final SharedPreferences _prefs;

  static const double defaultRoiTop = 0.40;
  static const double defaultRoiBottom = 0.80;

  static Future<AppSettings> load() async =>
      AppSettings._(await SharedPreferences.getInstance());

  /// Code de langue : fr, de, es, it.
  String get lang => _prefs.getString('lang') ?? 'fr';
  set lang(String v) => _prefs.setString('lang', v);

  /// Vitesse de la voix : 1.0 = normale (de 0.5 à 2.0).
  double get rate => _prefs.getDouble('rate') ?? 1.0;
  set rate(double v) => _prefs.setDouble('rate', v);

  /// Zone des sous-titres, en fraction de la hauteur de l'image (0 = haut).
  double get roiTop => _prefs.getDouble('roiTop') ?? defaultRoiTop;
  set roiTop(double v) => _prefs.setDouble('roiTop', v);
  double get roiBottom => _prefs.getDouble('roiBottom') ?? defaultRoiBottom;
  set roiBottom(double v) => _prefs.setDouble('roiBottom', v);

  /// Couper la phrase en cours quand un nouveau sous-titre apparaît.
  bool get interrupt => _prefs.getBool('interrupt') ?? false;
  set interrupt(bool v) => _prefs.setBool('interrupt', v);

  /// Ignorer les descriptions sonores : [Musique], (rires)…
  bool get removeSoundTags => _prefs.getBool('removeSoundTags') ?? true;
  set removeSoundTags(bool v) => _prefs.setBool('removeSoundTags', v);

  /// Réactivité : 0 = rapide, 1 = normale, 2 = stable.
  int get reactivity => _prefs.getInt('reactivity') ?? 1;
  set reactivity(int v) => _prefs.setInt('reactivity', v);

  /// Zoom de la caméra.
  double get zoom => _prefs.getDouble('zoom') ?? 1.0;
  set zoom(double v) => _prefs.setDouble('zoom', v);

  /// Nombre d'images identiques à attendre avant de lire un sous-titre.
  int get stableFrames => const [1, 2, 3][reactivity.clamp(0, 2)];

  /// Délai minimal entre deux analyses d'image.
  Duration get frameInterval =>
      Duration(milliseconds: const [250, 350, 450][reactivity.clamp(0, 2)]);
}
