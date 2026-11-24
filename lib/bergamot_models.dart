// Modèles de langue du traducteur du téléphone (Android) : ceux de Firefox
// Translations (Mozilla, MPL-2.0), listés dans le registre public de Mozilla.
//
// Les modèles traduisent entre l'anglais et une autre langue (fr-en, en-fr…).
// Pour l'allemand vers le français, on passe par l'anglais : de-en puis en-fr.
// Chaque sens fait environ 35 Mo, téléchargé une fois, puis tout se fait sur
// le téléphone, sans internet ni limite.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Registre des modèles publiés par Mozilla (≈ 200 ko).
const kBergamotRegistry = 'https://storage.googleapis.com/'
    'moz-fx-translations-data--303e-prod-translations-data/db/models.json';

/// Un fichier d'un modèle, dans le registre.
class BergamotFile {
  BergamotFile(this.path, {this.sha256, this.size});

  /// Chemin relatif à l'adresse de base du registre (fichier .gz).
  final String path;

  /// Empreinte SHA-256 du fichier décompressé (le modèle seulement).
  final String? sha256;

  /// Taille décompressée, si le registre la donne.
  final int? size;

  /// Nom du fichier décompressé (sans .gz).
  String get name {
    final last = path.split('/').last;
    return last.endsWith('.gz') ? last.substring(0, last.length - 3) : last;
  }
}

/// Un modèle publié : une langue vers une autre (souvent l'anglais).
class BergamotModel {
  BergamotModel({
    required this.from,
    required this.to,
    required this.model,
    required this.vocabs,
    this.shortlist,
  });

  /// Codes du registre (« fr », « en », « nb », « zh »…).
  final String from;
  final String to;
  final BergamotFile model;

  /// Un vocabulaire commun, ou celui de la source puis celui de la cible.
  final List<BergamotFile> vocabs;
  final BergamotFile? shortlist;

  String get pair => '$from-$to';

  List<BergamotFile> get files {
    final seen = <String>{};
    return [
      for (final f in [model, ...vocabs, if (shortlist != null) shortlist!])
        if (seen.add(f.path)) f,
    ];
  }

  /// Configuration du moteur, avec des chemins relatifs au dossier du modèle
  /// (comme Firefox : faisceau de 1, liste de mots courte, entiers 8 bits).
  String configYaml() {
    final v = vocabs.length == 1 ? [vocabs[0].name, vocabs[0].name] : [for (final f in vocabs) f.name];
    final precision = model.name.contains('alphas') ? 'int8shiftAlphaAll' : 'int8shift';
    return [
      'models:',
      '  - ${model.name}',
      'vocabs:',
      for (final n in v) '  - $n',
      if (shortlist != null) ...['shortlist:', '  - ${shortlist!.name}', '  - false'],
      'beam-size: 1',
      'normalize: 1.0',
      'word-penalty: 0',
      'max-length-break: 128',
      'mini-batch-words: 1024',
      'workspace: 128',
      'max-length-factor: 2.0',
      'skip-cost: true',
      'cpu-threads: 0',
      'quiet: true',
      'quiet-translation: true',
      'gemm-precision: $precision',
      'alignment: soft',
      '',
    ].join('\n');
  }
}

/// Le registre de Mozilla, réduit aux modèles publiés (un par sens).
class BergamotRegistry {
  BergamotRegistry(this.baseUrl, this.models);

  final String baseUrl;

  /// Par sens (« fr-en »).
  final Map<String, BergamotModel> models;

  /// Lit le registre : pour chaque sens, la version publiée pour Android, sinon
  /// la version publiée tout court (jamais les grands modèles pour ordinateur).
  static BergamotRegistry parse(String json) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    final base = (root['baseUrl'] as String).replaceAll(RegExp(r'/+$'), '');
    final out = <String, BergamotModel>{};
    final all = (root['models'] as Map<String, dynamic>?) ?? const {};
    for (final entry in all.entries) {
      final list = entry.value is List ? entry.value as List : [entry.value];
      Map<String, dynamic>? pick(String status) => list
          .whereType<Map<String, dynamic>>()
          .where((e) => e['releaseStatus'] == status)
          .firstOrNull;
      final e = pick('Release Android') ?? pick('Release');
      if (e == null) continue;
      final m = _model(entry.key, e);
      if (m != null) out[m.pair] = m;
    }
    return BergamotRegistry(base, out);
  }

  static BergamotModel? _model(String key, Map<String, dynamic> e) {
    final files = e['files'];
    if (files is! Map) return null;
    BergamotFile? file(String k) {
      final f = files[k];
      if (f is! Map || f['path'] is! String) return null;
      return BergamotFile(
        f['path'] as String,
        sha256: f['uncompressedHash'] as String?,
        size: (f['uncompressedSize'] as num?)?.toInt(),
      );
    }

    final model = file('model');
    final vocab = file('vocab');
    final src = file('srcVocab');
    final trg = file('trgVocab');
    final vocabs = vocab != null ? [vocab] : [if (src != null) src, if (trg != null) trg];
    if (model == null || vocabs.isEmpty || (vocab == null && vocabs.length != 2)) return null;
    final parts = key.split('-');
    final from = (e['sourceLanguage'] as String?) ?? parts.first;
    final to = (e['targetLanguage'] as String?) ?? (parts.length > 1 ? parts[1] : '');
    if (from.isEmpty || to.isEmpty) return null;
    return BergamotModel(
      from: from,
      to: to,
      model: model,
      vocabs: vocabs,
      shortlist: file('lexicalShortlist'),
    );
  }

  /// Codes du registre essayés pour un code de VoxLiso (norvégien : bokmål).
  static List<String> codes(String lang) => switch (lang) {
        'no' => const ['nb', 'no'],
        'nb' => const ['nb', 'no'],
        _ => [lang],
      };

  BergamotModel? find(String from, String to) {
    for (final f in codes(from)) {
      for (final t in codes(to)) {
        final m = models['$f-$t'];
        if (m != null) return m;
      }
    }
    return null;
  }

  /// Modèles nécessaires de [from] vers [to] : direct s'il existe, sinon par
  /// l'anglais. Liste vide : traduction impossible avec ces modèles.
  List<BergamotModel> plan(String from, String to) {
    if (from == to) return const [];
    final direct = find(from, to);
    if (direct != null) return [direct];
    if (from == 'en' || to == 'en') return const [];
    final a = find(from, 'en');
    final b = find('en', to);
    return a != null && b != null ? [a, b] : const [];
  }

  /// Les deux sens d'une langue avec l'anglais (ceux qui existent).
  List<BergamotModel> both(String lang) {
    if (lang == 'en') return const [];
    return [
      for (final m in [find(lang, 'en'), find('en', lang)])
        if (m != null) m,
    ];
  }
}

/// Modèles installés dans un dossier du téléphone : `<racine>/<sens>/config.yml`.
class BergamotStore {
  BergamotStore(this.root);

  final Directory root;

  /// Dossier d'un sens (« fr-en »).
  Directory dir(String pair) => Directory('${root.path}/$pair');

  bool hasPair(String pair) => File('${dir(pair).path}/config.yml').existsSync();

  /// Un sens installé pour ces codes de VoxLiso (norvégien : nb ou no).
  String? installedPair(String from, String to) {
    for (final f in BergamotRegistry.codes(from)) {
      for (final t in BergamotRegistry.codes(to)) {
        if (hasPair('$f-$t')) return '$f-$t';
      }
    }
    return null;
  }

  /// Dossiers à utiliser pour traduire de [from] vers [to], sans internet :
  /// direct, ou par l'anglais. Null si un modèle manque.
  List<String>? route(String from, String to) {
    if (from == to) return null;
    final direct = installedPair(from, to);
    if (direct != null) return [dir(direct).path];
    if (from == 'en' || to == 'en') return null;
    final a = installedPair(from, 'en');
    final b = installedPair('en', to);
    return a != null && b != null ? [dir(a).path, dir(b).path] : null;
  }

  /// Sens installés (« fr-en », « en-fr »…).
  List<String> pairs() {
    if (!root.existsSync()) return const [];
    return [
      for (final d in root.listSync().whereType<Directory>())
        if (File('${d.path}/config.yml').existsSync()) d.uri.pathSegments.where((s) => s.isNotEmpty).last,
    ]..sort();
  }

  /// Taille occupée par un sens, en octets.
  int sizeOf(String pair) {
    final d = dir(pair);
    if (!d.existsSync()) return 0;
    return d.listSync().whereType<File>().fold(0, (n, f) => n + f.lengthSync());
  }

  Future<void> delete(String pair) async {
    final d = dir(pair);
    if (d.existsSync()) await d.delete(recursive: true);
  }

  /// Télécharge et installe un modèle : chaque fichier .gz est décompressé à la
  /// volée, le modèle vérifié avec l'empreinte du registre, puis config.yml
  /// écrit en dernier (un sens sans config.yml n'est pas utilisé).
  /// [onProgress] : de 0 à 1.
  Future<void> install(
    BergamotModel m,
    String baseUrl, {
    HttpClient? client,
    void Function(double)? onProgress,
  }) async {
    final http = client ?? HttpClient();
    final tmp = Directory('${root.path}/.${m.pair}.part');
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
      await tmp.create(recursive: true);
      final files = m.files;
      // Le modèle fait l'essentiel du poids (≈ 90 %).
      final weights = [for (final f in files) identical(f, m.model) ? 0.9 : 0.1 / (files.length - 1)];
      var done = 0.0;
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        await _fetch(http, '$baseUrl/${f.path}', File('${tmp.path}/${f.name}'), f.sha256, (x) {
          onProgress?.call((done + weights[i] * x).clamp(0, 1).toDouble());
        });
        done += weights[i];
      }
      await File('${tmp.path}/config.yml').writeAsString(m.configYaml());
      final dest = dir(m.pair);
      if (dest.existsSync()) await dest.delete(recursive: true);
      await tmp.rename(dest.path);
      onProgress?.call(1);
    } finally {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
      if (client == null) http.close();
    }
  }

  static Future<void> _fetch(HttpClient http, String url, File dest, String? sha,
      void Function(double) progress) async {
    final req = await http.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 20));
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    }
    final total = res.contentLength;
    var received = 0;
    final counted = res.map((chunk) {
      received += chunk.length;
      if (total > 0) progress(received / total);
      return chunk;
    });
    final plain = url.endsWith('.gz') ? counted.transform(gzip.decoder) : counted;
    final sink = dest.openWrite();
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    await for (final chunk in plain.timeout(const Duration(seconds: 60))) {
      sink.add(chunk);
      hasher.add(chunk);
    }
    hasher.close();
    await sink.close();
    if (sha != null && digest.value.toString() != sha.toLowerCase()) {
      throw const FormatException('empreinte du modèle incorrecte');
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
