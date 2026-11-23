/// Écriture des sous-titres : choisit le moteur de reconnaissance de ML Kit.
/// Les moteurs chinois, japonais et coréen lisent aussi l'alphabet latin.
enum SubtitleScript {
  latin('Latine'),
  chinese('Chinoise'),
  japanese('Japonaise'),
  korean('Coréenne');

  const SubtitleScript(this.label);
  final String label;

  static SubtitleScript fromName(String name) =>
      values.where((s) => s.name == name).firstOrNull ?? latin;
}

/// Langues de sous-titres prises en charge : lues avec une voix de la langue.
///
/// Les langues européennes utilisent l'alphabet latin : un seul moteur de
/// reconnaissance (ML Kit « Latin ») suffit, accents compris (é, ü, ñ, ł, ř…).
/// Le chinois, le japonais et le coréen ont chacun leur moteur ([script]).
class SubtitleLanguage {
  const SubtitleLanguage({
    required this.code,
    required this.label,
    required this.short,
    required this.ttsLocale,
    required this.sample,
    this.script = SubtitleScript.latin,
  });

  final String code;
  final String label;
  final String short;
  final String ttsLocale;
  final String sample;
  final SubtitleScript script;

  /// Écriture sans espaces entre les mots (chinois, japonais).
  bool get noSpaces => script == SubtitleScript.chinese || script == SubtitleScript.japanese;
}

const List<SubtitleLanguage> kLanguages = [
  SubtitleLanguage(
    code: 'fr',
    label: 'Français',
    short: 'FR',
    ttsLocale: 'fr-FR',
    sample: 'Bonjour ! Je vais lire les sous-titres à voix haute.',
  ),
  SubtitleLanguage(
    code: 'de',
    label: 'Deutsch',
    short: 'DE',
    ttsLocale: 'de-DE',
    sample: 'Hallo! Ich lese die Untertitel laut vor.',
  ),
  SubtitleLanguage(
    code: 'es',
    label: 'Español',
    short: 'ES',
    ttsLocale: 'es-ES',
    sample: '¡Hola! Voy a leer los subtítulos en voz alta.',
  ),
  SubtitleLanguage(
    code: 'it',
    label: 'Italiano',
    short: 'IT',
    ttsLocale: 'it-IT',
    sample: 'Ciao! Leggerò i sottotitoli ad alta voce.',
  ),
  SubtitleLanguage(
    code: 'en',
    label: 'English',
    short: 'EN',
    ttsLocale: 'en-US',
    sample: 'Hello! I will read the subtitles out loud.',
  ),
  SubtitleLanguage(
    code: 'pt',
    label: 'Português',
    short: 'PT',
    ttsLocale: 'pt-PT',
    sample: 'Olá! Vou ler as legendas em voz alta.',
  ),
  SubtitleLanguage(
    code: 'nl',
    label: 'Nederlands',
    short: 'NL',
    ttsLocale: 'nl-NL',
    sample: 'Hallo! Ik lees de ondertitels hardop voor.',
  ),
  SubtitleLanguage(
    code: 'pl',
    label: 'Polski',
    short: 'PL',
    ttsLocale: 'pl-PL',
    sample: 'Cześć! Przeczytam napisy na głos.',
  ),
  SubtitleLanguage(
    code: 'ro',
    label: 'Română',
    short: 'RO',
    ttsLocale: 'ro-RO',
    sample: 'Bună! Voi citi subtitrările cu voce tare.',
  ),
  SubtitleLanguage(
    code: 'sv',
    label: 'Svenska',
    short: 'SV',
    ttsLocale: 'sv-SE',
    sample: 'Hej! Jag läser upp undertexterna.',
  ),
  SubtitleLanguage(
    code: 'da',
    label: 'Dansk',
    short: 'DA',
    ttsLocale: 'da-DK',
    sample: 'Hej! Jeg læser underteksterne højt.',
  ),
  SubtitleLanguage(
    code: 'no',
    label: 'Norsk',
    short: 'NO',
    ttsLocale: 'nb-NO',
    sample: 'Hei! Jeg leser opp undertekstene.',
  ),
  SubtitleLanguage(
    code: 'fi',
    label: 'Suomi',
    short: 'FI',
    ttsLocale: 'fi-FI',
    sample: 'Hei! Luen tekstitykset ääneen.',
  ),
  SubtitleLanguage(
    code: 'cs',
    label: 'Čeština',
    short: 'CS',
    ttsLocale: 'cs-CZ',
    sample: 'Ahoj! Přečtu titulky nahlas.',
  ),
  SubtitleLanguage(
    code: 'sk',
    label: 'Slovenčina',
    short: 'SK',
    ttsLocale: 'sk-SK',
    sample: 'Ahoj! Prečítam titulky nahlas.',
  ),
  SubtitleLanguage(
    code: 'hu',
    label: 'Magyar',
    short: 'HU',
    ttsLocale: 'hu-HU',
    sample: 'Szia! Felolvasom a feliratokat.',
  ),
  SubtitleLanguage(
    code: 'tr',
    label: 'Türkçe',
    short: 'TR',
    ttsLocale: 'tr-TR',
    sample: 'Merhaba! Altyazıları sesli okuyacağım.',
  ),
  SubtitleLanguage(
    code: 'ca',
    label: 'Català',
    short: 'CA',
    ttsLocale: 'ca-ES',
    sample: 'Hola! Llegiré els subtítols en veu alta.',
  ),
  SubtitleLanguage(
    code: 'hr',
    label: 'Hrvatski',
    short: 'HR',
    ttsLocale: 'hr-HR',
    sample: 'Bok! Pročitat ću titlove naglas.',
  ),
  SubtitleLanguage(
    code: 'zh',
    label: '中文',
    short: 'ZH',
    ttsLocale: 'zh-CN',
    sample: '你好！我会大声朗读字幕。',
    script: SubtitleScript.chinese,
  ),
  SubtitleLanguage(
    code: 'ja',
    label: '日本語',
    short: 'JA',
    ttsLocale: 'ja-JP',
    sample: 'こんにちは！字幕を声に出して読みます。',
    script: SubtitleScript.japanese,
  ),
  SubtitleLanguage(
    code: 'ko',
    label: '한국어',
    short: 'KO',
    ttsLocale: 'ko-KR',
    sample: '안녕하세요! 자막을 소리 내어 읽어 드릴게요.',
    script: SubtitleScript.korean,
  ),
];

/// Langues lues telles quelles par défaut (les autres sont traduites en mode Auto).
const List<String> kDefaultReadLanguages = ['fr', 'de', 'es', 'it', 'en', 'pt'];

SubtitleLanguage languageFor(String code) =>
    kLanguages.firstWhere((l) => l.code == code, orElse: () => kLanguages.first);

/// Langue prise en charge correspondant à un code ML Kit (« fr », « de-AT »,
/// « nb »…), sinon null.
SubtitleLanguage? supportedLanguage(String tag) {
  var code = tag.split('-').first.toLowerCase();
  if (code == 'nb' || code == 'nn') code = 'no';
  for (final l in kLanguages) {
    if (l.code == code) return l;
  }
  return null;
}

/// Autres langues en alphabet latin (lisibles par la reconnaissance de texte),
/// sans voix ici : traduites automatiquement. Nom en français.
const Map<String, String> kOtherLanguages = {
  'sl': 'Slovène',
  'lt': 'Lituanien',
  'lv': 'Letton',
  'et': 'Estonien',
  'sq': 'Albanais',
  'id': 'Indonésien',
  'ms': 'Malais',
  'vi': 'Vietnamien',
  'tl': 'Tagalog',
  'sw': 'Swahili',
  'af': 'Afrikaans',
  'ga': 'Irlandais',
  'cy': 'Gallois',
  'is': 'Islandais',
  'gl': 'Galicien',
  'mt': 'Maltais',
  'eo': 'Espéranto',
};

/// Nom affichable d'une langue : celui d'une langue lue, sinon le nom
/// français d'une autre langue, sinon son code.
String languageName(String code) =>
    supportedLanguage(code)?.label ?? kOtherLanguages[code] ?? code.toUpperCase();

/// Langue qu'une voix sait lire (elle a une entrée dans [kLanguages]) ?
bool isReadLanguage(String code) => supportedLanguage(code) != null;

// ---------------------------------------------------------------- écritures

/// Caractère d'une écriture sans espaces (idéogrammes, kana) ou ponctuation
/// chinoise / japonaise pleine chasse.
bool isCjkRune(int r) =>
    (r >= 0x3000 && r <= 0x303F) || // ponctuation CJK (、。「」…)
    (r >= 0x3040 && r <= 0x30FF) || // hiragana, katakana
    (r >= 0x3400 && r <= 0x4DBF) || // idéogrammes (extension A)
    (r >= 0x4E00 && r <= 0x9FFF) || // idéogrammes
    (r >= 0xF900 && r <= 0xFAFF) || // idéogrammes de compatibilité
    (r >= 0xFF00 && r <= 0xFFEF); // formes pleine chasse (！？，…)

/// Syllabe ou lettre coréenne (hangul).
bool isHangulRune(int r) =>
    (r >= 0xAC00 && r <= 0xD7AF) || (r >= 0x1100 && r <= 0x11FF) || (r >= 0x3130 && r <= 0x318F);

/// Le texte contient-il du chinois ou du japonais ?
bool hasCjk(String text) => text.runes.any(isCjkRune);

/// Poids d'un texte en temps de parole : un idéogramme, un kana ou une syllabe
/// coréenne se disent environ trois fois plus lentement qu'une lettre latine.
int speechWeight(String text) {
  var n = 0;
  for (final r in text.runes) {
    n += isCjkRune(r) || isHangulRune(r) ? 3 : 1;
  }
  return n;
}
