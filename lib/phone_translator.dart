// Traducteur du téléphone : gratuit, sans clé, sans limite et sans internet
// une fois les langues téléchargées.
//  - Android : Bergamot, le traducteur de Firefox (modèles de Mozilla) ;
//  - iPhone (iOS 18 ou plus) : la traduction d'Apple (app Traduire).
// Sur les autres téléphones, VoxLiso garde la traduction ML Kit.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'bergamot.dart';
import 'bergamot_models.dart';
import 'system_bridge.dart';

abstract class PhoneTranslator {
  /// Le traducteur de ce téléphone, ou null (ordinateur, tests).
  static PhoneTranslator? create() {
    if (Platform.isAndroid) return BergamotTranslator();
    if (Platform.isIOS) return AppleTranslator();
    return null;
  }

  /// Nom affiché (« Firefox », « Apple »).
  String get label;

  /// Le traducteur fonctionne-t-il sur ce téléphone ? (Android 64 bits, iOS 18…)
  Future<bool> isAvailable();

  /// Langue utilisable dans les deux sens avec l'anglais (ou, sur iPhone,
  /// téléchargée). null = pas encore vérifié.
  bool? knownInstalled(String lang);
  Future<bool> isInstalled(String lang);

  /// Traduction possible tout de suite, sans téléchargement ?
  Future<bool> canTranslateNow(String from, String to);

  /// Traduit, ou renvoie null (langue absente, erreur).
  Future<List<String>?> translate(List<String> texts, String from, String to);

  /// Télécharge une langue (les deux sens avec l'anglais).
  Future<bool> download(String lang);

  /// Télécharge en silence ce qu'il faut pour [from] → [to] (Wi-Fi seulement).
  /// Renvoie les langues en cours de téléchargement.
  Set<String> autoDownload(String from, String to);

  /// Supprimer une langue est-il possible depuis VoxLiso ?
  bool get canDelete;
  Future<bool> delete(String lang);

  bool isDownloading(String lang);

  /// Avancement du téléchargement (0 à 1), ou null.
  double? progress(String lang);

  /// Appelé quand un téléchargement avance ou se termine.
  void Function()? onChange;

  /// Langue que ce traducteur ne connaît pas du tout (sinon : téléchargeable).
  Future<bool> supports(String lang);

  Future<void> close();
}

/// Android : Bergamot (dart:ffi), modèles dans le dossier privé de l'application.
class BergamotTranslator extends PhoneTranslator {
  BergamotTranslator({this.libraryPath, Directory? root, this.wifiCheck}) : _root = root;

  /// Chemin de libbergamot (tests sur ordinateur) ; null = celle de l'APK.
  final String? libraryPath;

  /// Vérifie le Wi-Fi avant un téléchargement automatique (par défaut : Android).
  final Future<bool> Function()? wifiCheck;

  Directory? _root;
  BergamotStore? _store;
  BergamotRegistry? _registry;
  Future<BergamotWorker?>? _worker;
  final Map<String, double> _progress = {};
  final Map<String, bool> _installed = {};
  DateTime _lastAuto = DateTime.fromMillisecondsSinceEpoch(0);
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  @override
  String get label => 'Firefox';

  @override
  bool get canDelete => true;

  Future<BergamotStore?> _storeReady() async {
    if (_store != null) return _store;
    var root = _root;
    if (root == null) {
      final files = await SystemBridge.filesDir();
      if (files == null) return null;
      root = Directory('$files/translation');
    }
    _root = root;
    return _store = BergamotStore(root);
  }

  Future<BergamotWorker?> _workerReady() => _worker ??= BergamotWorker.start(libraryPath);

  @override
  Future<bool> isAvailable() async => await _storeReady() != null && await _workerReady() != null;

  /// Registre de Mozilla : gardé une semaine dans le dossier des modèles.
  Future<BergamotRegistry?> registry() async {
    if (_registry != null) return _registry;
    final store = await _storeReady();
    if (store == null) return null;
    final cache = File('${store.root.path}/registry.json');
    String? json;
    final fresh = cache.existsSync() &&
        DateTime.now().difference(cache.lastModifiedSync()) < const Duration(days: 7);
    if (!fresh) {
      try {
        final req = await _http.getUrl(Uri.parse(kBergamotRegistry)).timeout(const Duration(seconds: 15));
        final res = await req.close().timeout(const Duration(seconds: 20));
        final body = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
        if (res.statusCode == 200) {
          BergamotRegistry.parse(body); // vérifie qu'il est lisible
          await store.root.create(recursive: true);
          await cache.writeAsString(body);
          json = body;
        }
      } catch (_) {}
    }
    if (json == null && cache.existsSync()) json = await cache.readAsString();
    if (json == null) return null;
    try {
      return _registry = BergamotRegistry.parse(json);
    } catch (_) {
      return null;
    }
  }

  @override
  bool? knownInstalled(String lang) => lang == 'en' ? true : _installed[lang];

  @override
  Future<bool> isInstalled(String lang) async {
    if (lang == 'en') return true;
    final store = await _storeReady();
    if (store == null) return false;
    final ok = store.installedPair(lang, 'en') != null && store.installedPair('en', lang) != null;
    _installed[lang] = ok;
    return ok;
  }

  @override
  Future<bool> canTranslateNow(String from, String to) async =>
      (await _storeReady())?.route(from, to) != null && await _workerReady() != null;

  @override
  Future<List<String>?> translate(List<String> texts, String from, String to) async {
    final store = await _storeReady();
    final route = store?.route(from, to);
    if (route == null) return null;
    final worker = await _workerReady();
    if (worker == null) return null;
    try {
      final out = await worker.translate(texts, route.first, route.length > 1 ? route[1] : null);
      if (out.length != texts.length || out.every((t) => t.trim().isEmpty)) return null;
      return out;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> supports(String lang) async {
    if (lang == 'en') return true;
    final r = await registry();
    return r == null || r.both(lang).isNotEmpty;
  }

  @override
  bool isDownloading(String lang) => _progress.containsKey(lang);

  @override
  double? progress(String lang) => _progress[lang];

  /// Installe [models] pour la langue affichée [lang].
  Future<bool> _install(String lang, List<BergamotModel> models) async {
    if (_progress.containsKey(lang)) return false;
    final store = await _storeReady();
    final r = await registry();
    if (store == null || r == null) return false;
    final missing = [for (final m in models) if (!store.hasPair(m.pair)) m];
    if (missing.isEmpty) return true;
    _progress[lang] = 0;
    onChange?.call();
    try {
      for (var i = 0; i < missing.length; i++) {
        await store.install(missing[i], r.baseUrl, client: _http, onProgress: (x) {
          _progress[lang] = (i + x) / missing.length;
          onChange?.call();
        });
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      _progress.remove(lang);
      await isInstalled(lang);
      onChange?.call();
    }
  }

  @override
  Future<bool> download(String lang) async {
    if (lang == 'en') return true;
    final r = await registry();
    if (r == null) return false;
    final models = r.both(lang);
    if (models.isEmpty) return false;
    return _install(lang, models);
  }

  /// Langues demandées par la lecture et pas encore installées.
  final Set<String> _wanted = {};

  @override
  Set<String> autoDownload(String from, String to) {
    for (final l in [from, to]) {
      if (l != 'en' && knownInstalled(l) != true) _wanted.add(l);
    }
    // Au plus un essai par minute (pas de Wi-Fi, registre injoignable…).
    if (DateTime.now().difference(_lastAuto) >= const Duration(minutes: 1)) {
      _lastAuto = DateTime.now();
      _autoInstall(from, to);
    }
    return {..._wanted, ..._progress.keys};
  }

  Future<void> _autoInstall(String from, String to) async {
    final r = await registry();
    final store = await _storeReady();
    if (r == null || store == null) return;
    final plan = r.plan(from, to);
    // Langue inconnue des modèles : rien à attendre.
    if (plan.isEmpty) {
      _wanted
        ..remove(from)
        ..remove(to);
      return;
    }
    final missing = {
      for (final m in plan)
        if (!store.hasPair(m.pair)) m: m.from == 'en' ? to : from,
    };
    _wanted
      ..removeWhere((l) => l == from || l == to)
      ..addAll(missing.values);
    if (missing.isEmpty || !await (wifiCheck ?? SystemBridge.isUnmetered)()) return;
    for (final e in missing.entries) {
      if (await _install(e.value, [e.key])) _wanted.remove(e.value);
    }
  }

  @override
  Future<bool> delete(String lang) async {
    if (lang == 'en') return false;
    final store = await _storeReady();
    if (store == null) return false;
    final worker = await _workerReady();
    for (final pair in store.pairs()) {
      final parts = pair.split('-');
      if (!parts.any((p) => BergamotRegistry.codes(lang).contains(p))) continue;
      await worker?.unload(store.dir(pair).path);
      await store.delete(pair);
    }
    _installed[lang] = false;
    onChange?.call();
    return true;
  }

  @override
  Future<void> close() async {
    (await _worker)?.close();
    _http.close(force: true);
  }
}

/// iPhone : la traduction d'Apple (cadre Translation, iOS 18 ou plus), par
/// le canal « voxliso/translation » (code Swift de native/ios).
class AppleTranslator extends PhoneTranslator {
  static const MethodChannel _channel = MethodChannel('voxliso/translation');

  bool? _available;
  final Map<String, bool> _installed = {};
  final Set<String> _downloading = {};

  @override
  String get label => 'Apple';

  @override
  bool get canDelete => false;

  /// Codes d'Apple : chinois simplifié, portugais du Brésil (seul proposé).
  static String appleCode(String lang) => switch (lang) {
        'zh' => 'zh-Hans',
        'pt' => 'pt-BR',
        'no' => 'nb',
        _ => lang,
      };

  @override
  Future<bool> isAvailable() async {
    if (_available != null) return _available!;
    try {
      _available = await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// « installed », « supported » (à télécharger) ou « unsupported ».
  Future<String> _status(String from, String to) async {
    if (!await isAvailable()) return 'unsupported';
    try {
      return await _channel.invokeMethod<String>(
              'status', {'from': appleCode(from), 'to': appleCode(to)}) ??
          'unsupported';
    } catch (_) {
      return 'unsupported';
    }
  }

  /// Langue partenaire pour vérifier une langue seule : l'anglais (ou le
  /// français pour l'anglais).
  static String _partner(String lang) => lang == 'en' ? 'fr' : 'en';

  @override
  bool? knownInstalled(String lang) => _installed[lang];

  @override
  Future<bool> isInstalled(String lang) async {
    final ok = await _status(lang, _partner(lang)) == 'installed';
    _installed[lang] = ok;
    return ok;
  }

  @override
  Future<bool> supports(String lang) async => await _status(lang, _partner(lang)) != 'unsupported';

  @override
  Future<bool> canTranslateNow(String from, String to) async =>
      await _status(from, to) == 'installed';

  @override
  Future<List<String>?> translate(List<String> texts, String from, String to) async {
    if (!await isAvailable()) return null;
    try {
      final out = await _channel.invokeListMethod<String>('translate', {
        'texts': texts,
        'from': appleCode(from),
        'to': appleCode(to),
      });
      if (out == null || out.length != texts.length || out.every((t) => t.trim().isEmpty)) {
        return null;
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  @override
  bool isDownloading(String lang) => _downloading.contains(lang);

  @override
  double? progress(String lang) => null;

  /// iOS montre sa propre fenêtre pour télécharger la langue.
  @override
  Future<bool> download(String lang) async {
    if (!await isAvailable() || !_downloading.add(lang)) return false;
    onChange?.call();
    try {
      return await _channel.invokeMethod<bool>(
              'prepare', {'from': appleCode(lang), 'to': appleCode(_partner(lang))}) ??
          false;
    } catch (_) {
      return false;
    } finally {
      _downloading.remove(lang);
      await isInstalled(lang);
      onChange?.call();
    }
  }

  /// Pas de téléchargement silencieux sur iPhone : iOS demande toujours.
  @override
  Set<String> autoDownload(String from, String to) => const {};

  @override
  Future<bool> delete(String lang) async => false;

  @override
  Future<void> close() async {}
}
