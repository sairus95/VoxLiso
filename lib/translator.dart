import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'phone_translator.dart';
import 'text_tools.dart';

/// Résultat d'une traduction : textes traduits et moteur utilisé.
class TranslationResult {
  TranslationResult(this.texts, this.engine);
  final List<String> texts;

  /// « téléphone » (Firefox / Apple), « Azure », « DeepL » ou « hors ligne » (ML Kit).
  final String engine;
}

/// Traduction des sous-titres, dans cet ordre (choix de l'utilisateur, 24/11/2026 :
/// « DeepL d'abord ») :
///  - DeepL, avec une clé : les traductions les plus naturelles, tant que son
///    quota dure ; puis Microsoft Azure Translator, avec une clé ;
///  - le traducteur du téléphone (Firefox sur Android, Apple sur iPhone) :
///    gratuit, sans limite et sans internet, une fois les langues téléchargées
///    (elles se téléchargent en Wi-Fi pendant que DeepL traduit, pour la suite) ;
///  - enfin ML Kit (hors ligne, moins bon), si ses langues sont là.
/// Un moteur en ligne en panne (réseau, quota, clé refusée) est mis en pause
/// quelque temps : les sous-titres suivants n'attendent pas sa réponse.
class SubtitleTranslator {
  SubtitleTranslator({PhoneTranslator? phone, bool usePhone = true})
      : phone = usePhone ? (phone ?? PhoneTranslator.create()) : null {
    this.phone?.onChange = () => onChange?.call();
  }

  /// Traducteur du téléphone (null : ordinateur, tests).
  final PhoneTranslator? phone;

  /// Le traducteur du téléphone fonctionne ici (vérifié par [refresh]).
  bool phoneReady = false;

  /// Appelé quand un téléchargement de langue avance (pour les réglages).
  void Function()? onChange;

  /// Clé et région de Microsoft Azure Translator (clé vide = pas d'Azure ;
  /// région vide ou « global » pour une ressource globale).
  String azureKey = '';
  String azureRegion = '';

  /// Dernière erreur Azure, pour l'afficher dans les réglages.
  String? azureError;

  /// Clé de l'API DeepL (vide = pas de DeepL).
  String deeplKey = '';

  /// Dernière erreur DeepL, pour l'afficher dans les réglages.
  String? deeplError;

  /// Moteurs en ligne en pause après une panne : jusqu'à quand, et pour quelle clé
  /// (une nouvelle clé lève la pause).
  DateTime? _deeplPausedUntil;
  String _deeplPausedKey = '';
  DateTime? _azurePausedUntil;
  String _azurePausedKey = '';

  /// Durée de pause d'un moteur en ligne après une réponse [status]
  /// (null : pas de réponse, réseau coupé ou trop lent).
  static Duration pauseAfter(int? status) => switch (status) {
        456 || 403 || 401 => const Duration(hours: 6), // quota épuisé, clé refusée
        429 => const Duration(seconds: 20), // surchargé
        _ => const Duration(minutes: 1), // réseau, autre erreur
      };

  static bool _paused(DateTime? until, String pausedKey, String key) =>
      until != null && pausedKey == key && DateTime.now().isBefore(until);
  final OnDeviceTranslatorModelManager _models = OnDeviceTranslatorModelManager();
  final Map<String, OnDeviceTranslator> _translators = {};
  final Map<String, bool> _downloaded = {};
  final Set<String> _downloading = {};

  static TranslateLanguage? _lang(String code) =>
      TranslateLanguage.values.where((l) => l.bcpCode == code).firstOrNull;

  /// La traduction hors ligne connaît-elle cette langue ?
  static bool canTranslate(String code) => _lang(code) != null;

  static String _bcp(String code) => _lang(code)!.bcpCode;

  static const List<String> _main = ['fr', 'de', 'es', 'it', 'en', 'pt'];

  /// Langues en cours de téléchargement automatique (Wi-Fi), pour l'afficher.
  final Set<String> autoDownloading = {};

  bool isDownloading(String code) =>
      phoneReady ? phone!.isDownloading(code) : _downloading.contains(code);

  /// Avancement d'un téléchargement (0 à 1), si connu.
  double? downloadProgress(String code) => phoneReady ? phone!.progress(code) : null;

  /// État connu (sans interroger le téléphone) : null = pas encore vérifié.
  bool? knownDownloaded(String code) =>
      phoneReady ? phone!.knownInstalled(code) : _downloaded[code];

  /// Une langue téléchargée peut-elle être supprimée depuis VoxLiso ?
  bool get canDelete => phoneReady && phone!.canDelete;

  /// Nom du traducteur du téléphone (« Firefox », « Apple »), ou null (ML Kit).
  String? get phoneLabel => phoneReady ? phone!.label : null;

  Future<bool> isDownloaded(String code) async {
    if (phoneReady) return phone!.isInstalled(code);
    return _mlkitDownloaded(code);
  }

  Future<bool> _mlkitDownloaded(String code) async {
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
    phoneReady = phone != null && await phone!.isAvailable();
    for (final code in _main) {
      await isDownloaded(code);
    }
  }

  /// Vérifie l'état de quelques langues (celles affichées dans les réglages).
  Future<void> refreshLanguages(Iterable<String> codes) async {
    for (final code in codes) {
      await isDownloaded(code);
    }
  }

  /// Télécharge une langue (une seule fois). [wifiOnly] : attendre le Wi-Fi (ML Kit).
  Future<bool> download(String code, {bool wifiOnly = false}) async {
    if (phoneReady) return phone!.download(code);
    return _mlkitDownload(code, wifiOnly: wifiOnly);
  }

  Future<bool> _mlkitDownload(String code, {bool wifiOnly = false}) async {
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
    if (phoneReady) return phone!.delete(code);
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
  Future<String?> translate(String text, String from, String to, {bool autoDownload = true}) async {
    if (from == to) return text;
    if (!canTranslate(from) || !canTranslate(to)) return null;
    final fromOk = _downloaded[from] ?? await _mlkitDownloaded(from);
    final toOk = _downloaded[to] ?? await _mlkitDownloaded(to);
    if (!fromOk || !toOk) {
      if (!autoDownload) return null;
      // Langue manquante : téléchargement automatique en Wi-Fi, pour la suite.
      for (final c in [if (!fromOk) from, if (!toOk) to]) {
        if (autoDownloading.add(c)) {
          _mlkitDownload(c, wifiOnly: true).whenComplete(() => autoDownloading.remove(c));
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
  /// DeepL / Azure (avec une clé), sinon le traducteur du téléphone, sinon ML Kit.
  /// Renvoie null si aucune traduction n'est possible.
  Future<TranslationResult?> translateAll(List<String> texts, String from, String to) async {
    if (from == to) return TranslationResult(texts, '');
    final prepared = [for (final t in texts) prepareForTranslation(t)];
    final p = phoneReady ? phone : null;
    final phoneNow = p != null && await p.canTranslateNow(from, to);
    // Langue pas encore sur le téléphone : téléchargement en Wi-Fi, pour quand
    // DeepL ne sera plus là (quota épuisé, pas de réseau).
    if (p != null && !phoneNow) {
      autoDownloading
        ..clear()
        ..addAll(p.autoDownload(from, to));
    } else {
      autoDownloading.clear();
    }

    final dKey = deeplKey.trim();
    if (dKey.isNotEmpty && !_paused(_deeplPausedUntil, _deeplPausedKey, dKey)) {
      final online = await _deepl(prepared, from, to);
      if (online != null) return TranslationResult(online, 'DeepL');
    }
    final aKey = azureKey.trim();
    if (aKey.isNotEmpty && !_paused(_azurePausedUntil, _azurePausedKey, aKey)) {
      final online = await _azure(prepared, from, to);
      if (online != null) return TranslationResult(online, 'Azure');
    }
    if (phoneNow && p != null) {
      final out = await p
          .translate(prepared, from, to)
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      if (out != null) return TranslationResult(out, 'téléphone');
    }
    final out = <String>[];
    for (final t in prepared) {
      // Avec le traducteur du téléphone, ML Kit ne télécharge rien tant que le
      // téléphone prépare ces langues (pas de double téléchargement).
      final r = await translate(t, from, to, autoDownload: p == null || autoDownloading.isEmpty)
          .timeout(const Duration(seconds: 6), onTimeout: () => null);
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
        // Pas de langue source : DeepL la reconnaît lui-même sur tout le sous-titre.
        // Une langue mal reconnue par VoxLiso (sous-titre court, nom propre)
        // donnait sinon une traduction bizarre.
        'target_lang': deeplTarget(to),
      }));
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        deeplError = switch (res.statusCode) {
          403 => 'Clé DeepL refusée : vérifiez-la. Autre traducteur en attendant.',
          456 => 'Quota DeepL atteint : traducteur du téléphone à la place.',
          429 => 'DeepL est surchargé : autre traducteur pour quelques sous-titres.',
          _ => 'DeepL a répondu ${res.statusCode} : autre traducteur.',
        };
        _pauseDeepl(key, res.statusCode);
        return null;
      }
      final list = (jsonDecode(body) as Map<String, dynamic>)['translations'] as List;
      deeplError = null;
      _deeplPausedUntil = null;
      final out = [for (final t in list) (t as Map)['text'].toString()];
      return out.length == texts.length ? out : null;
    } on TimeoutException {
      deeplError = 'DeepL ne répond pas : autre traducteur pendant une minute.';
      _pauseDeepl(key, null);
      return null;
    } catch (_) {
      deeplError = 'Pas de connexion à DeepL : autre traducteur pendant une minute.';
      _pauseDeepl(key, null);
      return null;
    }
  }

  void _pauseDeepl(String key, int? status) {
    _deeplPausedKey = key;
    _deeplPausedUntil = DateTime.now().add(pauseAfter(status));
  }

  void _pauseAzure(String key, int? status) {
    _azurePausedKey = key;
    _azurePausedUntil = DateTime.now().add(pauseAfter(status));
  }

  /// Essaie un moteur en ligne seul (« Azure » ou « DeepL ») sur une phrase
  /// d'exemple, pour le bouton « Tester » des réglages. Renvoie la traduction,
  /// ou null (l'erreur est dans [azureError] / [deeplError]).
  Future<String?> testOnline(String engine, String to) async {
    const sample = ['Wo ist der Bahnhof, bitte?'];
    final r = engine == 'Azure' ? await _azure(sample, 'de', to) : await _deepl(sample, 'de', to);
    return r?.first;
  }

  /// Langue cible pour DeepL : variante pour l'anglais, le portugais et le
  /// chinois (simplifié), « NB » pour le norvégien.
  static String deeplTarget(String to) => switch (to) {
        'en' => 'EN-US',
        'pt' => 'PT-PT',
        'zh' => 'ZH-HANS',
        'no' => 'NB',
        _ => to.toUpperCase(),
      };

  /// Code de langue pour Azure : norvégien « nb », tagalog « fil », et
  /// portugais du Portugal (« pt-pt ») en traduction, comme la voix pt-PT.
  static String azureLang(String code, {bool target = false}) => switch (code) {
        'no' => 'nb',
        'tl' => 'fil',
        'zh' => 'zh-Hans',
        'pt' when target => 'pt-pt',
        _ => code,
      };

  /// Lit la réponse d'Azure : `[{"translations":[{"text":…,"to":…}]}, …]`.
  static List<String>? parseAzure(String body, int expected) {
    try {
      final list = jsonDecode(body) as List;
      final out = [
        for (final item in list) (((item as Map)['translations'] as List).first as Map)['text'].toString(),
      ];
      return out.length == expected ? out : null;
    } catch (_) {
      return null;
    }
  }

  /// Message clair pour une erreur d'Azure (code HTTP et code détaillé).
  static String azureErrorMessage(int status, String body) {
    int? code;
    try {
      code = (((jsonDecode(body) as Map)['error'] as Map)['code'] as num?)?.toInt();
    } catch (_) {}
    if (status == 401) return 'Clé Azure refusée : vérifiez la clé et la région.';
    if (status == 403 && code == 403001) {
      return 'Quota gratuit Azure du mois atteint : autre traduction en attendant.';
    }
    if (status == 429) return 'Azure est surchargé : autre traduction pour ce sous-titre.';
    if (status == 400 && (code == 400035 || code == 400036)) {
      return 'Azure ne traduit pas cette langue : autre traduction.';
    }
    return 'Azure a répondu $status${code != null ? ' ($code)' : ''}.';
  }

  Future<List<String>?> _azure(List<String> texts, String from, String to) async {
    final key = azureKey.trim();
    final region = azureRegion.trim().toLowerCase().replaceAll(' ', '');
    try {
      final req = await _http.postUrl(Uri.https('api.cognitive.microsofttranslator.com', '/translate', {
        'api-version': '3.0',
        'from': azureLang(from),
        'to': azureLang(to, target: true),
      }));
      req.headers
        ..set('Ocp-Apim-Subscription-Key', key)
        ..contentType = ContentType.json;
      // Ressource régionale (westeurope, francecentral…) : la région est obligatoire.
      if (region.isNotEmpty && region != 'global') {
        req.headers.set('Ocp-Apim-Subscription-Region', region);
      }
      req.write(jsonEncode([for (final t in texts) {'Text': t}]));
      final res = await req.close().timeout(const Duration(seconds: 5));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        azureError = azureErrorMessage(res.statusCode, body);
        // Langue non traduite par Azure : pas de pause (les autres langues marchent).
        if (res.statusCode != 400) _pauseAzure(key, res.statusCode);
        return null;
      }
      final out = parseAzure(body, texts.length);
      azureError = out == null ? 'Réponse d\'Azure illisible.' : null;
      if (out != null) _azurePausedUntil = null;
      return out;
    } on TimeoutException {
      azureError = 'Azure ne répond pas : autre traduction.';
      _pauseAzure(key, null);
      return null;
    } catch (_) {
      azureError = 'Pas de connexion à Azure : autre traduction.';
      _pauseAzure(key, null);
      return null;
    }
  }

  Future<void> close() async {
    _http.close(force: true);
    await phone?.close();
    for (final t in _translators.values) {
      await t.close();
    }
    _translators.clear();
  }
}
