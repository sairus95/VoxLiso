import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Traduction des sous-titres sur le téléphone (ML Kit), sans internet
/// une fois les langues téléchargées (environ 30 Mo par langue, une seule fois).
class SubtitleTranslator {
  final OnDeviceTranslatorModelManager _models = OnDeviceTranslatorModelManager();
  final Map<String, OnDeviceTranslator> _translators = {};
  final Map<String, bool> _downloaded = {};
  final Set<String> _downloading = {};

  static const Map<String, TranslateLanguage> _languages = {
    'fr': TranslateLanguage.french,
    'de': TranslateLanguage.german,
    'es': TranslateLanguage.spanish,
    'it': TranslateLanguage.italian,
  };

  static String _bcp(String code) => _languages[code]!.bcpCode;

  bool isDownloading(String code) => _downloading.contains(code);

  /// État connu (sans interroger le téléphone) : null = pas encore vérifié.
  bool? knownDownloaded(String code) => _downloaded[code];

  Future<bool> isDownloaded(String code) async {
    if (!_languages.containsKey(code)) return false;
    try {
      final ok = await _models.isModelDownloaded(_bcp(code));
      _downloaded[code] = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() async {
    for (final code in _languages.keys) {
      await isDownloaded(code);
    }
  }

  /// Télécharge une langue (une seule fois). [wifiOnly] : attendre le Wi-Fi.
  Future<bool> download(String code, {bool wifiOnly = false}) async {
    if (!_languages.containsKey(code) || _downloading.contains(code)) return false;
    _downloading.add(code);
    try {
      final ok = await _models.downloadModel(_bcp(code), isWifiRequired: wifiOnly);
      _downloaded[code] = ok || await isDownloaded(code);
      return _downloaded[code]!;
    } catch (_) {
      return false;
    } finally {
      _downloading.remove(code);
    }
  }

  Future<bool> delete(String code) async {
    try {
      final ok = await _models.deleteModel(_bcp(code));
      _downloaded[code] = false;
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Traduit [text] de [from] vers [to]. Renvoie null si une des deux langues
  /// n'est pas téléchargée ou si la traduction échoue.
  Future<String?> translate(String text, String from, String to) async {
    if (from == to) return text;
    if (!_languages.containsKey(from) || !_languages.containsKey(to)) return null;
    final fromOk = _downloaded[from] ?? await isDownloaded(from);
    final toOk = _downloaded[to] ?? await isDownloaded(to);
    if (!fromOk || !toOk) return null;
    final t = _translators.putIfAbsent(
      '$from>$to',
      () => OnDeviceTranslator(sourceLanguage: _languages[from]!, targetLanguage: _languages[to]!),
    );
    try {
      final out = await t.translateText(text);
      return out.trim().isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  Future<void> close() async {
    for (final t in _translators.values) {
      await t.close();
    }
    _translators.clear();
  }
}
