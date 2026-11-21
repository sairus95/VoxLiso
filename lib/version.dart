/// Numéro de version, fourni à la compilation par GitHub Actions
/// (`--dart-define=APP_VERSION=1.0.N`, même numéro que la page Releases).
const String kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
