/// Langues de sous-titres prises en charge.
///
/// Les quatre langues utilisent l'alphabet latin : un seul moteur de
/// reconnaissance (ML Kit « Latin ») suffit, accents compris (é, ü, ñ, ò…).
/// Seule la voix de synthèse change d'une langue à l'autre.
class SubtitleLanguage {
  const SubtitleLanguage({
    required this.code,
    required this.label,
    required this.short,
    required this.ttsLocale,
    required this.sample,
  });

  final String code;
  final String label;
  final String short;
  final String ttsLocale;
  final String sample;
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
];

SubtitleLanguage languageFor(String code) =>
    kLanguages.firstWhere((l) => l.code == code, orElse: () => kLanguages.first);

/// Langue prise en charge correspondant à un code ML Kit (« fr », « de-AT »…), sinon null.
SubtitleLanguage? supportedLanguage(String tag) {
  final code = tag.split('-').first.toLowerCase();
  for (final l in kLanguages) {
    if (l.code == code) return l;
  }
  return null;
}

/// Autres langues en alphabet latin (lisibles par la reconnaissance de texte),
/// traduites automatiquement : nom en français.
const Map<String, String> kOtherLanguages = {
  'pt': 'Portugais',
  'nl': 'Néerlandais',
  'pl': 'Polonais',
  'ro': 'Roumain',
  'sv': 'Suédois',
  'da': 'Danois',
  'no': 'Norvégien',
  'fi': 'Finnois',
  'cs': 'Tchèque',
  'sk': 'Slovaque',
  'hu': 'Hongrois',
  'tr': 'Turc',
  'ca': 'Catalan',
  'hr': 'Croate',
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

/// Nom affichable d'une langue : celui des 4 langues lues, sinon le nom
/// français d'une autre langue, sinon son code.
String languageName(String code) =>
    supportedLanguage(code)?.label ?? kOtherLanguages[code] ?? code.toUpperCase();

/// Langue lue directement par une voix (fr, de, es, it) ?
bool isReadLanguage(String code) => supportedLanguage(code) != null;
