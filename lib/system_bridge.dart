import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Un moteur de synthèse vocale installé sur le téléphone (Android).
class TtsEngine {
  TtsEngine(this.name, this.label);

  /// Nom technique (ex. com.google.android.tts).
  final String name;

  /// Nom affiché (ex. « Synthèse vocale Google »).
  final String label;
}

/// Accès à quelques réglages d'Android (code natif de MainActivity).
class SystemBridge {
  static const MethodChannel _channel = MethodChannel('voxliso/system');

  static Future<List<TtsEngine>> ttsEngines() async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('ttsEngines') ?? const [];
      return [
        for (final e in raw)
          if (e is Map) TtsEngine(e['name']?.toString() ?? '', e['label']?.toString() ?? ''),
      ].where((e) => e.name.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Ouvre l'écran de téléchargement des voix du moteur [engine] (ou du moteur par défaut).
  static Future<bool> installVoices(String engine) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('installVoices', {'engine': engine}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Luminosité de l'écran pour VoxLiso seulement (0 à 1) ; -1 = celle du téléphone.
  static Future<void> setBrightness(double value) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('setBrightness', {'value': value});
    } catch (_) {}
  }

  /// Bip de cadrage : son de [hz] Hz pendant [ms] ms, au volume des médias
  /// (comme la voix ; il s'entend aussi téléphone en mode silencieux).
  static Future<void> beep(double hz, {int ms = 80}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('beep', {'hz': hz, 'ms': ms});
    } catch (_) {}
  }

  /// Mise à jour : confie le téléchargement de [url] au gestionnaire de
  /// téléchargements d'Android. Renvoie son numéro, ou -1.
  static Future<int> startDownload(String url, String name, String title) async {
    if (!Platform.isAndroid) return -1;
    try {
      return await _channel.invokeMethod<int>(
              'startDownload', {'url': url, 'name': name, 'title': title}) ??
          -1;
    } catch (_) {
      return -1;
    }
  }

  /// État d'un téléchargement : status (running, paused, pending, success,
  /// failed, missing), downloaded, total, reason, path.
  static Future<Map<String, dynamic>> downloadStatus(int id) async {
    try {
      final m = await _channel.invokeMethod<Map<dynamic, dynamic>>('downloadStatus', {'id': id});
      return m == null ? const {'status': 'missing'} : m.cast<String, dynamic>();
    } catch (_) {
      return const {'status': 'missing'};
    }
  }

  /// Annule un téléchargement ou efface son fichier.
  static Future<void> removeDownload(int id) async {
    try {
      await _channel.invokeMethod<bool>('removeDownload', {'id': id});
    } catch (_) {}
  }

  /// Installe un APK téléchargé (mise à jour) ; Android demande confirmation.
  static Future<bool> installApk(String path) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('installApk', {'path': path}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Ouvre un lien dans le navigateur.
  static Future<bool> openUrl(String url) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openTtsSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openTtsSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Connexion sans limite de données (Wi-Fi) : téléchargement automatique
  /// des langues du traducteur du téléphone.
  static Future<bool> isUnmetered() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isUnmetered') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Dossier privé de l'application (modèles de traduction).
  static Future<String?> filesDir() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('filesDir');
    } catch (_) {
      return null;
    }
  }
}
