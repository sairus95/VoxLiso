import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'settings.dart';
import 'system_bridge.dart';
import 'version.dart';

/// Progression d'un téléchargement : fraction (null si inconnue) et texte à afficher.
typedef DownloadProgress = void Function(double? progress, String status);

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

/// Résultat du bouton « Rechercher une mise à jour » : message et version trouvée.
typedef UpdateCheck = ({String message, UpdateInfo? update});

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

  /// Télécharge l'APK et renvoie son chemin. Le téléchargement est confié au
  /// gestionnaire de téléchargements d'Android : il continue écran éteint ou
  /// VoxLiso fermé, reprend après une coupure de réseau et s'affiche dans les
  /// notifications. Un téléchargement déjà commencé (ou fini) pour la même
  /// version est repris au lieu d'être relancé.
  static Future<String> download(UpdateInfo info, AppSettings s, DownloadProgress onProgress) async {
    var id = s.updateDownloadVersion == info.version ? s.updateDownloadId : -1;
    if (id >= 0) {
      final status = (await SystemBridge.downloadStatus(id))['status'];
      if (status == 'missing' || status == 'failed') id = -1;
    }
    if (id < 0) {
      id = await SystemBridge.startDownload(
          info.url, 'VoxLiso-${info.version}.apk', 'VoxLiso ${info.version}');
      if (id < 0) {
        // Gestionnaire de téléchargements indisponible : téléchargement par VoxLiso.
        return _directDownload(info, (p) => onProgress(p, progressText(p)));
      }
      s.updateDownloadId = id;
      s.updateDownloadVersion = info.version;
    }
    while (true) {
      final st = await SystemBridge.downloadStatus(id);
      final done = (st['downloaded'] as num?)?.toInt() ?? 0;
      var total = (st['total'] as num?)?.toInt() ?? 0;
      if (total <= 0) total = info.size;
      final p = total > 0 ? (done / total).clamp(0.0, 1.0).toDouble() : null;
      switch (st['status']) {
        case 'success':
          final path = st['path'] as String?;
          if (path != null && File(path).existsSync()) {
            onProgress(1, 'Téléchargement terminé');
            return path;
          }
          s.updateDownloadId = -1;
          throw const FileSystemException('Fichier de mise à jour introuvable');
        case 'failed':
          s.updateDownloadId = -1;
          throw HttpException('Téléchargement échoué (${st['reason']})');
        case 'missing':
          // Annulé depuis la notification, par exemple.
          s.updateDownloadId = -1;
          throw const HttpException('Téléchargement annulé');
        case 'paused':
          onProgress(p, pausedText((st['reason'] as num?)?.toInt()));
        case 'pending':
          onProgress(p, 'En attente…');
        default:
          onProgress(p, progressText(p));
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }

  static String progressText(double? p) =>
      p == null ? 'Téléchargement…' : 'Téléchargement : ${(p * 100).round()} %';

  /// Raison d'une pause du gestionnaire de téléchargements d'Android.
  static String pausedText(int? reason) => switch (reason) {
        1 => 'Coupure : nouvel essai dans un instant…', // PAUSED_WAITING_TO_RETRY
        2 => 'En attente du réseau…', // PAUSED_WAITING_FOR_NETWORK
        3 => 'En attente du Wi-Fi…', // PAUSED_QUEUED_FOR_WIFI
        _ => 'En pause…',
      };

  /// Après la mise à jour : efface l'APK téléchargé (≈ 130 Mo) une fois la
  /// nouvelle version installée.
  static Future<void> cleanUp(AppSettings s) async {
    final v = s.updateDownloadVersion;
    if (v.isEmpty) return;
    if (isNewer(v, kAppVersion)) return; // pas encore installée
    if (s.updateDownloadId >= 0) await SystemBridge.removeDownload(s.updateDownloadId);
    s.updateDownloadId = -1;
    s.updateDownloadVersion = '';
  }

  /// Téléchargement par VoxLiso lui-même (si Android n'a pas de gestionnaire
  /// de téléchargements) : s'arrête si le téléphone se met en veille.
  static Future<String> _directDownload(UpdateInfo info, void Function(double progress) onProgress) async {
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
