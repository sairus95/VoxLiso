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

  static Future<bool> openTtsSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openTtsSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
