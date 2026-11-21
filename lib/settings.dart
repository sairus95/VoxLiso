import 'package:shared_preferences/shared_preferences.dart';

import 'voices.dart';

/// Réglages de l'application, conservés entre deux utilisations.
class AppSettings {
  AppSettings._(this._prefs);

  final SharedPreferences _prefs;

  static const double defaultRoiTop = 0.40;
  static const double defaultRoiTopLandscape = 0.62;

  /// Bords gauche et droit de la zone (caméra) : centrée par défaut, pour se
  /// concentrer sur le texte du milieu de l'image (sous-titres).
  static const double defaultRoiLeft = 0.15;
  static const double defaultRoiRight = 0.85;
  static const double defaultRoiBottomLandscape = 0.95;
  static const double defaultRoiBottom = 0.80;

  static Future<AppSettings> load() async =>
      AppSettings._(await SharedPreferences.getInstance());

  /// Code de langue : auto (détection automatique), fr, de, es, it.
  String get lang => _prefs.getString('lang') ?? 'auto';
  set lang(String v) => _prefs.setString('lang', v);
  bool get autoLang => lang == 'auto';

  /// Dernière langue détectée en mode automatique.
  String get detectedLang => _prefs.getString('detectedLang') ?? 'fr';
  set detectedLang(String v) => _prefs.setString('detectedLang', v);

  /// Vitesse de la voix : 1.0 = normale (de 0.5 à 2.0).
  double get rate => _prefs.getDouble('rate') ?? 1.0;
  set rate(double v) => _prefs.setDouble('rate', v);

  /// Zone des sous-titres, en fraction de la hauteur de l'image (0 = haut).
  double get roiTop => _prefs.getDouble('roiTop') ?? defaultRoiTop;
  set roiTop(double v) => _prefs.setDouble('roiTop', v);
  double get roiBottom => _prefs.getDouble('roiBottom') ?? defaultRoiBottom;
  set roiBottom(double v) => _prefs.setDouble('roiBottom', v);

  /// Zone des sous-titres quand le téléphone est en paysage
  /// (la télé occupe alors toute l'image : sous-titres plus bas).
  double get roiTopLandscape => _prefs.getDouble('roiTopL') ?? defaultRoiTopLandscape;
  set roiTopLandscape(double v) => _prefs.setDouble('roiTopL', v);
  double get roiBottomLandscape =>
      _prefs.getDouble('roiBottomL') ?? defaultRoiBottomLandscape;
  set roiBottomLandscape(double v) => _prefs.setDouble('roiBottomL', v);

  double get roiLeft => _prefs.getDouble('roiLeft') ?? defaultRoiLeft;
  set roiLeft(double v) => _prefs.setDouble('roiLeft', v);
  double get roiRight => _prefs.getDouble('roiRight') ?? defaultRoiRight;
  set roiRight(double v) => _prefs.setDouble('roiRight', v);

  void resetZones() {
    roiLeft = defaultRoiLeft;
    roiRight = defaultRoiRight;
    roiTop = defaultRoiTop;
    roiBottom = defaultRoiBottom;
    roiTopLandscape = defaultRoiTopLandscape;
    roiBottomLandscape = defaultRoiBottomLandscape;
    screenTop = defaultScreenTop;
    screenBottom = defaultScreenBottom;
    screenTopLandscape = defaultScreenTopLandscape;
    screenBottomLandscape = defaultScreenBottomLandscape;
  }

  /// Couper la phrase en cours quand un nouveau sous-titre apparaît.
  bool get interrupt => _prefs.getBool('interrupt') ?? false;
  set interrupt(bool v) => _prefs.setBool('interrupt', v);

  /// Ignorer les descriptions sonores : [Musique], (rires)…
  bool get removeSoundTags => _prefs.getBool('removeSoundTags') ?? true;
  set removeSoundTags(bool v) => _prefs.setBool('removeSoundTags', v);

  /// Réactivité : 0 = rapide, 1 = normale, 2 = stable.
  int get reactivity => _prefs.getInt('reactivity') ?? 1;
  set reactivity(int v) => _prefs.setInt('reactivity', v);

  /// Analyse par photos successives au lieu du flux vidéo (plus lent, plus robuste).
  bool get photoMode => _prefs.getBool('photoMode') ?? false;
  set photoMode(bool v) => _prefs.setBool('photoMode', v);

  /// Voix choisie pour une langue (null = automatique : la plus naturelle).
  TtsVoice? voiceFor(String lang) => TtsVoice.fromJson(_prefs.getString('voice_$lang'));
  void setVoiceFor(String lang, TtsVoice? v) => v == null
      ? _prefs.remove('voice_$lang')
      : _prefs.setString('voice_$lang', v.toJson());

  /// Voix du 2e personnage dans les dialogues (null = automatique).
  TtsVoice? voice2For(String lang) => TtsVoice.fromJson(_prefs.getString('voice2_$lang'));
  void setVoice2For(String lang, TtsVoice? v) => v == null
      ? _prefs.remove('voice2_$lang')
      : _prefs.setString('voice2_$lang', v.toJson());

  /// Une voix différente pour chaque réplique d'un dialogue (« - Oui. » / « - Non. »).
  bool get dialogueVoices => _prefs.getBool('dialogueVoices') ?? true;
  set dialogueVoices(bool v) => _prefs.setBool('dialogueVoices', v);

  /// Langue de traduction : '' = pas de traduction, sinon fr / de / es / it.
  String get translateTo => _prefs.getString('translateTo') ?? '';
  set translateTo(String v) => _prefs.setString('translateTo', v);

  /// Source des sous-titres : « camera » (télé, ordinateur) ou « screen »
  /// (vidéos regardées sur le téléphone lui-même, Android seulement).
  String get source => _prefs.getString('source') ?? 'camera';
  set source(String v) => _prefs.setString('source', v);
  bool get screenSource => source == 'screen';

  /// Zone des sous-titres sur l'écran du téléphone, en portrait (vidéo en haut
  /// de l'écran, comme YouTube) et en paysage (vidéo en plein écran).
  static const double defaultScreenTop = 0.12;
  static const double defaultScreenBottom = 0.45;
  static const double defaultScreenTopLandscape = 0.65;
  static const double defaultScreenBottomLandscape = 0.98;
  double get screenTop => _prefs.getDouble('screenTop') ?? defaultScreenTop;
  set screenTop(double v) => _prefs.setDouble('screenTop', v);
  double get screenBottom => _prefs.getDouble('screenBottom') ?? defaultScreenBottom;
  set screenBottom(double v) => _prefs.setDouble('screenBottom', v);
  double get screenTopLandscape =>
      _prefs.getDouble('screenTopL') ?? defaultScreenTopLandscape;
  set screenTopLandscape(double v) => _prefs.setDouble('screenTopL', v);
  double get screenBottomLandscape =>
      _prefs.getDouble('screenBottomL') ?? defaultScreenBottomLandscape;
  set screenBottomLandscape(double v) => _prefs.setDouble('screenBottomL', v);

  /// Tutoriel déjà vu.
  bool get tutorialSeen => _prefs.getBool('tutorialSeen') ?? false;
  set tutorialSeen(bool v) => _prefs.setBool('tutorialSeen', v);

  /// Mode grands boutons (personnes malvoyantes) : textes et boutons agrandis,
  /// boutons pour déplacer la zone, annonces vocales.
  bool get largeMode => _prefs.getBool('largeMode') ?? false;
  set largeMode(bool v) => _prefs.setBool('largeMode', v);

  /// Historique des sous-titres lus (JSON), conservé entre deux lancements.
  String? get historyJson => _prefs.getString('history');
  set historyJson(String? v) =>
      v == null ? _prefs.remove('history') : _prefs.setString('history', v);

  /// Vue 16:9 (format télé) même téléphone debout : l'aperçu montre la bande
  /// centrale de l'image et seul le texte visible y est lu.
  bool get frame169 => _prefs.getBool('frame169') ?? true;
  set frame169(bool v) => _prefs.setBool('frame169', v);

  /// Clé de l'API DeepL (facultative) : traduction en ligne de meilleure qualité.
  String get deeplKey => _prefs.getString('deeplKey') ?? '';
  set deeplKey(String v) => _prefs.setString('deeplKey', v.trim());

  /// Zoom de la caméra.
  double get zoom => _prefs.getDouble('zoom') ?? 1.0;
  set zoom(double v) => _prefs.setDouble('zoom', v);

  /// Nombre d'images identiques à attendre avant de lire un sous-titre.
  int get stableFrames => const [1, 2, 3][reactivity.clamp(0, 2)];

  /// Délai minimal entre deux analyses d'image.
  Duration get frameInterval =>
      Duration(milliseconds: const [250, 350, 450][reactivity.clamp(0, 2)]);
}
