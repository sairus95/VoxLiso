import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'text_tools.dart';

/// Résultat d'une traduction : textes traduits et moteur utilisé.
class TranslationResult {
  TranslationResult(this.texts, this.engine);
  final List<String> texts;

  /// « DeepL » ou « hors ligne ».
  final String engine;
}

/// Traduction des sous-titres.
///  - Avec une clé DeepL (facultative) : en ligne, meilleure qualité.
///  - Sinon, ou sans internet : sur le téléphone (ML Kit), une fois les langues
///    téléchargées (environ 30 Mo par langue, une seule fois).
class SubtitleTranslator {
  /// Clé de l'API DeepL (vide = traduction hors ligne seulement).
  String deeplKey = '';

  /// Dernière erreur DeepL, pour l'afficher dans les réglages.
  String? deeplError;
  final OnDeviceTranslatorModelManager _models = OnDeviceTranslatorModelManager();
  final Map<String, OnDeviceTranslator> _translators = {};
  final Map<String, bool> _downloaded = {};
  final Set<String> _downloading = {};

  static TranslateLanguage? _lang(String code) =>
      TranslateLanguage.values.where((l) => l.bcpCode == code).firstOrNull;

  /// La traduction hors ligne connaît-elle cette langue ?
  static bool canTranslate(String code) => _lang(code) != null;

  static String _bcp(String code) => _lang(code)!.bcpCode;

  static const List<String> _main = ['fr', 'de', 'es', 'it'];

  /// Langues en cours de téléchargement automatique (Wi-Fi), pour l'afficher.
  final Set<String> autoDownloading = {};

  bool isDownloading(String code) => _downloading.contains(code);

  /// État connu (sans interroger le téléphone) : null = pas encore vérifié.
  bool? knownDownloaded(String code) => _downloaded[code];

  Future<bool> isDownloaded(String code) async {
    if (!canTranslate(code)) return false;
    try {
      final ok = await _models.isModelDownloaded(_bcp(code));
      _downloaded[code] = ok;
      return ok;
    } catch (_) {
      return false;
    }
  }

  Future<void> refresh() async {
    for (final code in _main) {
      await isDownloaded(code);
    }
  }

  /// Télécharge une langue (une seule fois). [wifiOnly] : attendre le Wi-Fi.
  Future<bool> download(String code, {bool wifiOnly = false}) async {
    if (!canTranslate(code) || _downloading.contains(code)) return false;
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
    if (!canTranslate(from) || !canTranslate(to)) return null;
    final fromOk = _downloaded[from] ?? await isDownloaded(from);
    final toOk = _downloaded[to] ?? await isDownloaded(to);
    if (!fromOk || !toOk) {
      // Langue manquante : téléchargement automatique en Wi-Fi, pour la suite.
      for (final c in [if (!fromOk) from, if (!toOk) to]) {
        if (autoDownloading.add(c)) {
          download(c, wifiOnly: true).whenComplete(() => autoDownloading.remove(c));
        }
      }
      return null;
    }
    final t = _translators.putIfAbsent(
      '$from>$to',
      () => OnDeviceTranslator(sourceLanguage: _lang(from)!, targetLanguage: _lang(to)!),
    );
    try {
      final out = await t.translateText(text);
      return out.trim().isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// Traduit plusieurs phrases (ex. les répliques d'un dialogue) d'un coup :
  /// DeepL si une clé est réglée et que le réseau répond, sinon hors ligne.
  /// Renvoie null si aucune traduction n'est possible.
  Future<TranslationResult?> translateAll(List<String> texts, String from, String to) async {
    if (from == to) return TranslationResult(texts, '');
    final prepared = [for (final t in texts) prepareForTranslation(t)];
    if (deeplKey.trim().isNotEmpty) {
      final online = await _deepl(prepared, from, to);
      if (online != null) return TranslationResult(online, 'DeepL');
    }
    final out = <String>[];
    for (final t in prepared) {
      final r = await translate(t, from, to).timeout(const Duration(seconds: 6),
          onTimeout: () => null);
      if (r == null) return null;
      out.add(r);
    }
    return TranslationResult(out, 'hors ligne');
  }

  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 3);

  Future<List<String>?> _deepl(List<String> texts, String from, String to) async {
    final key = deeplKey.trim();
    // Les clés gratuites finissent par « :fx » et utilisent un autre serveur.
    final host = key.endsWith(':fx') ? 'api-free.deepl.com' : 'api.deepl.com';
    try {
      final req = await _http.postUrl(Uri.https(host, '/v2/translate'));
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'DeepL-Auth-Key $key')
        ..contentType = ContentType.json;
      req.write(jsonEncode({
        'text': texts,
        // DeepL écrit le norvégien « NB ».
        'source_lang': from == 'no' ? 'NB' : from.toUpperCase(),
        'target_lang': to.toUpperCase(),
      }));
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        deeplError = switch (res.statusCode) {
          403 => 'Clé DeepL refusée : vérifiez-la.',
          456 => 'Quota DeepL du mois atteint : traduction hors ligne en attendant.',
          429 => 'DeepL est surchargé : traduction hors ligne pour ce sous-titre.',
          _ => 'DeepL a répondu ${res.statusCode}.',
        };
        return null;
      }
      final list = (jsonDecode(body) as Map<String, dynamic>)['translations'] as List;
      deeplError = null;
      final out = [for (final t in list) (t as Map)['text'].toString()];
      return out.length == texts.length ? out : null;
    } on TimeoutException {
      deeplError = 'DeepL ne répond pas : traduction hors ligne.';
      return null;
    } catch (_) {
      deeplError = 'Pas de connexion à DeepL : traduction hors ligne.';
      return null;
    }
  }

  Future<void> close() async {
    _http.close(force: true);
    for (final t in _translators.values) {
      await t.close();
    }
    _translators.clear();
  }
}
