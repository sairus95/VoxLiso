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
];

SubtitleLanguage languageFor(String code) =>
    kLanguages.firstWhere((l) => l.code == code, orElse: () => kLanguages.first);
