/// Numéro de version, fourni à la compilation par GitHub Actions
/// (`--dart-define=APP_VERSION=1.0.N`, même numéro que la page Releases).
const String kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// Clé DeepL intégrée à la compilation (secret GitHub `DEEPL_KEY`, jamais écrite
/// dans le code). Vide si le secret n'existe pas. Ignorée dans la version boutique.
const String kBuiltInDeeplKey = String.fromEnvironment('DEEPL_KEY');

/// Clé et région Microsoft Azure Translator intégrées à la compilation
/// (secrets GitHub `AZURE_TRANSLATOR_KEY` et `AZURE_TRANSLATOR_REGION`).
const String kBuiltInAzureKey = String.fromEnvironment('AZURE_TRANSLATOR_KEY');
const String kBuiltInAzureRegion = String.fromEnvironment('AZURE_TRANSLATOR_REGION');

/// Traduction des sous-titres : désactivée pour l'instant (demande du 24/11/2026 :
/// « enlève le système de traduction pour l'instant, lis juste en direct les
/// phrases à l'écran »). Chaque sous-titre est lu tel quel, dans sa langue. Le
/// code reste en place : `--dart-define=TRANSLATION=true` la remet.
const bool kTranslationEnabled = bool.fromEnvironment('TRANSLATION');
