import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'system_bridge.dart';
import 'version.dart';

/// Une version publiée sur GitHub.
class UpdateInfo {
  UpdateInfo(this.version, this.url, this.size);

  /// Ex. « 1.0.27 ».
  final String version;

  /// Lien de téléchargement de l'APK.
  final String url;

  /// Taille en octets (0 si inconnue).
  final int size;
}

/// Mises à jour sans Play Store : VoxLiso regarde la dernière version publiée
/// sur GitHub (page « Releases ») et l'installe (Android).
class Updater {
  static const String repo = 'sairus95/VoxLiso';

  /// Version boutique (Play Store, App Store) : les mises à jour passent par la
  /// boutique, l'application ne doit jamais se mettre à jour elle-même.
  static const bool storeBuild = bool.fromEnvironment('STORE_BUILD');

  /// Seulement sur Android, pour l'APK compilé par GitHub (numéroté), jamais
  /// pour la version boutique.
  static bool get supported =>
      !storeBuild && Platform.isAndroid && parseVersion(kAppVersion) != null;

  /// « v1.0.27 » ou « 1.0.27 » -> [1, 0, 27] ; null si ce n'est pas un numéro.
  static List<int>? parseVersion(String v) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(v.trim());
    if (m == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
  }

  /// [candidate] est-elle plus récente que [current] ?
  static bool isNewer(String candidate, String current) {
    final a = parseVersion(candidate);
    final b = parseVersion(current);
    if (a == null || b == null) return false;
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  /// Dernière version publiée si elle est plus récente que celle installée.
  /// Lève une exception si GitHub ne répond pas.
  static Future<UpdateInfo?> check() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.https('api.github.com', '/repos/$repo/releases/latest'));
      req.headers
        ..set(HttpHeaders.userAgentHeader, 'VoxLiso/$kAppVersion')
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw HttpException('GitHub ${res.statusCode}');
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] ?? '').toString();
      if (!isNewer(tag, kAppVersion)) return null;
      for (final a in (json['assets'] as List? ?? const [])) {
        if (a is Map && a['name'].toString().toLowerCase().endsWith('.apk')) {
          return UpdateInfo(
            parseVersion(tag)!.join('.'),
            a['browser_download_url'].toString(),
            (a['size'] as num?)?.toInt() ?? 0,
          );
        }
      }
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Télécharge l'APK (progression de 0 à 1) et renvoie son chemin.
  static Future<String> download(UpdateInfo info, void Function(double progress) onProgress) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(info.url));
      req.headers.set(HttpHeaders.userAgentHeader, 'VoxLiso/$kAppVersion');
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('Téléchargement : ${res.statusCode}');
      final total = res.contentLength > 0 ? res.contentLength : info.size;
      final file = File('${Directory.systemTemp.path}/VoxLiso-${info.version}.apk');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.close();
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  /// Lance l'installation ; Android demande ensuite confirmation.
  static Future<bool> install(String path) => SystemBridge.installApk(path);
}
