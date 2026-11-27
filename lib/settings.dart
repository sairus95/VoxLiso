import 'package:shared_preferences/shared_preferences.dart';

import 'languages.dart';
import 'voices.dart';
import 'version.dart';

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

  /// Langues lues telles quelles (boutons de la barre de langue). En mode Auto,
  /// un sous-titre dans une autre langue est traduit ([autoTranslateTo]).
  List<String> get readLanguages {
    final saved = _prefs.getStringList('readLanguages');
    final list = [
      for (final l in kLanguages)
        if ((saved ?? kDefaultReadLanguages).contains(l.code)) l.code,
    ];
    return list.isEmpty ? List.of(kDefaultReadLanguages) : list;
  }

  set readLanguages(List<String> v) => _prefs.setStringList('readLanguages', v);

  /// Écriture des sous-titres (moteur de reconnaissance) : latin, chinese,
  /// japanese, korean. Choisie toute seule quand on choisit une langue.
  SubtitleScript get ocrScript => SubtitleScript.fromName(_prefs.getString('ocrScript') ?? 'latin');
  set ocrScript(SubtitleScript v) => _prefs.setString('ocrScript', v.name);

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

  /// Vitesse automatique : la voix accélère un peu (jusqu'à +40 %) quand
  /// les sous-titres défilent plus vite qu'elle ne parle.
  bool get autoRate => _prefs.getBool('autoRate') ?? true;
  set autoRate(bool v) => _prefs.setBool('autoRate', v);

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

  /// Hauteur de la voix principale d'une langue (1.0 = normale, 0.6 à 1.5).
  double pitchFor(String lang) => _prefs.getDouble('pitch_$lang') ?? 1.0;
  void setPitchFor(String lang, double v) => _prefs.setDouble('pitch_$lang', v);

  /// Hauteur de la voix du 2e personnage (null = automatique).
  double? pitch2For(String lang) => _prefs.getDouble('pitch2_$lang');
  void setPitch2For(String lang, double? v) =>
      v == null ? _prefs.remove('pitch2_$lang') : _prefs.setDouble('pitch2_$lang', v);

  /// Moteur de synthèse vocale (Android) : '' = celui du téléphone.
  String get ttsEngine => _prefs.getString('ttsEngine') ?? '';
  set ttsEngine(String v) => _prefs.setString('ttsEngine', v);

  /// Une voix différente pour chaque réplique d'un dialogue (« - Oui. » / « - Non. »).
  bool get dialogueVoices => _prefs.getBool('dialogueVoices') ?? true;
  set dialogueVoices(bool v) => _prefs.setBool('dialogueVoices', v);

  /// Langue de traduction : '' = pas de traduction, sinon fr / de / es / it / en / pt.
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

  /// Sous-titres dans une autre langue que fr/de/es/it/en/pt (néerlandais, polonais…) :
  /// traduits automatiquement dans cette langue (fr par défaut).
  String get autoTranslateTo => _prefs.getString('autoTranslateTo') ?? 'fr';
  set autoTranslateTo(String v) => _prefs.setString('autoTranslateTo', v);

  /// Clé de l'API DeepL (facultative) : traduction en ligne de meilleure qualité.
  String get deeplKey => _prefs.getString('deeplKey') ?? '';
  set deeplKey(String v) => _prefs.setString('deeplKey', v.trim());

  /// Clé intégrée à l'APK GitHub (secret de compilation), sauf version boutique :
  /// celle-ci partagerait le quota DeepL entre tous les utilisateurs.
  static String get builtInDeeplKey =>
      const bool.fromEnvironment('STORE_BUILD') ? '' : kBuiltInDeeplKey.trim();

  /// Clé DeepL à utiliser : celle saisie dans les réglages, sinon la clé intégrée.
  String get effectiveDeeplKey => deeplKey.isNotEmpty ? deeplKey : builtInDeeplKey;

  /// Zone miroir : si rien n'est lu dans la zone, lire aussi la même bande de
  /// l'autre côté de l'image (sous-titres placés en haut).
  bool get topSubtitles => _prefs.getBool('topSubtitles') ?? true;
  set topSubtitles(bool v) => _prefs.setBool('topSubtitles', v);

  /// Mise à jour en cours de téléchargement (gestionnaire d'Android) : numéro et version.
  int get updateDownloadId => _prefs.getInt('updateDownloadId') ?? -1;
  set updateDownloadId(int v) => _prefs.setInt('updateDownloadId', v);
  String get updateDownloadVersion => _prefs.getString('updateDownloadVersion') ?? '';
  set updateDownloadVersion(String v) => _prefs.setString('updateDownloadVersion', v);

  /// Microsoft Azure Translator : clé et région saisies dans les réglages.
  String get azureKey => _prefs.getString('azureKey') ?? '';
  set azureKey(String v) => _prefs.setString('azureKey', v.trim());
  String get azureRegion => _prefs.getString('azureRegion') ?? '';
  set azureRegion(String v) => _prefs.setString('azureRegion', v.trim());

  /// Clé Azure intégrée à l'APK GitHub (jamais dans la version boutique).
  static String get builtInAzureKey =>
      const bool.fromEnvironment('STORE_BUILD') ? '' : kBuiltInAzureKey.trim();

  /// Clé et région Azure à utiliser : celles des réglages, sinon celles intégrées.
  String get effectiveAzureKey => azureKey.isNotEmpty ? azureKey : builtInAzureKey;
  String get effectiveAzureRegion =>
      azureKey.isNotEmpty ? azureRegion : (builtInAzureKey.isEmpty ? '' : kBuiltInAzureRegion.trim());

  /// Ignorer le texte resté identique plus de 20 s (logo, heure, menu).
  bool get ignoreStatic => _prefs.getBool('ignoreStatic') ?? true;
  set ignoreStatic(bool v) => _prefs.setBool('ignoreStatic', v);

  /// Seulement les sous-titres : menus, panneaux du décor, bandeaux, heure et
  /// adresses web écartés (`SubtitleStyle`, v1.0.93).
  bool get subtitlesOnly => _prefs.getBool('subtitlesOnly') ?? true;
  set subtitlesOnly(bool v) => _prefs.setBool('subtitlesOnly', v);

  /// Écran noir pendant la lecture (caméra) : toucher pour le rallumer.
  /// En option, désactivé par défaut (nouvelle clé depuis la v1.0.33 : l'ancien
  /// réglage, activé par défaut, n'est pas repris).
  bool get blackScreen => _prefs.getBool('blackScreenOpt') ?? false;
  set blackScreen(bool v) => _prefs.setBool('blackScreenOpt', v);

  /// Mises à jour : dernière vérification (ms).
  int get lastUpdateCheck => _prefs.getInt('lastUpdateCheck') ?? 0;
  set lastUpdateCheck(int v) => _prefs.setInt('lastUpdateCheck', v);

  /// Image renforcée (zone recadrée, contrastée, agrandie) quand rien n'est lu.
  bool get enhance => _prefs.getBool('enhance') ?? true;
  set enhance(bool v) => _prefs.setBool('enhance', v);

  /// Correction des mots mal lus avec un dictionnaire par langue.
  /// Bips pour cadrer la télé avant la lecture (activés d'office en mode
  /// grands boutons, pensé pour les personnes qui voient mal).
  bool get aimBeeps => _prefs.getBool('aimBeeps') ?? largeMode;
  set aimBeeps(bool v) => _prefs.setBool('aimBeeps', v);

  /// Voix seulement dans les écouteurs (Bluetooth, filaires…) : sans eux, la
  /// voix reste coupée, pour ne pas gêner les autres.
  bool get headphonesOnly => _prefs.getBool('headphonesOnly') ?? false;
  set headphonesOnly(bool v) => _prefs.setBool('headphonesOnly', v);

  /// Profils de zone (JSON, voir zone_profiles.dart).
  String get zoneProfilesJson => _prefs.getString('zoneProfiles') ?? '[]';
  set zoneProfilesJson(String v) => _prefs.setString('zoneProfiles', v);

  bool get spellFix => _prefs.getBool('spellFix') ?? true;
  set spellFix(bool v) => _prefs.setBool('spellFix', v);

  /// Zoom de la caméra.
  double get zoom => _prefs.getDouble('zoom') ?? 1.0;
  set zoom(double v) => _prefs.setDouble('zoom', v);

  /// Nombre d'images identiques à attendre avant de lire un sous-titre.
  int get stableFrames => const [1, 2, 3][reactivity.clamp(0, 2)];

  /// Délai minimal entre deux analyses d'image.
  Duration get frameInterval =>
      Duration(milliseconds: const [250, 350, 450][reactivity.clamp(0, 2)]);
}
