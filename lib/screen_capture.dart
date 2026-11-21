import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show Rect;

import 'package:flutter/services.dart';

/// Une ligne de texte vue sur l'écran du téléphone (coordonnées 0..1).
class ScreenLine {
  ScreenLine(this.text, this.rect);
  final String text;
  final Rect rect;
}

/// Une analyse de l'écran du téléphone.
class ScreenFrame {
  ScreenFrame(this.lines, this.landscape);
  final List<ScreenLine> lines;

  /// Écran en paysage (vidéo en plein écran).
  final bool landscape;
}

/// Lecture de l'écran du téléphone (Android) : le service natif capture
/// l'écran, y lit le texte avec ML Kit et envoie les lignes ici.
class ScreenCapture {
  static const MethodChannel _method = MethodChannel('voxliso/screen');
  static const EventChannel _events = EventChannel('voxliso/screen/lines');

  /// Disponible seulement sur Android.
  static bool get isAvailable => Platform.isAndroid;

  final StreamController<ScreenFrame> _frames = StreamController.broadcast();
  final StreamController<void> _stopped = StreamController.broadcast();
  StreamSubscription<dynamic>? _sub;

  Stream<ScreenFrame> get frames => _frames.stream;

  /// La capture s'est arrêtée (bouton « Arrêter » de la notification, etc.).
  Stream<void> get stopped => _stopped.stream;

  void listen() {
    if (!isAvailable || _sub != null) return;
    _sub = _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      if (event['stopped'] == true) {
        _stopped.add(null);
        return;
      }
      final raw = event['lines'];
      final w = (event['w'] as num?)?.toDouble() ?? 1;
      final h = (event['h'] as num?)?.toDouble() ?? 1;
      final lines = <ScreenLine>[];
      if (raw is List) {
        for (final l in raw) {
          if (l is! Map) continue;
          double d(String k) => (l[k] as num?)?.toDouble() ?? 0;
          lines.add(ScreenLine(
            l['text']?.toString() ?? '',
            Rect.fromLTRB(d('l'), d('t'), d('r'), d('b')),
          ));
        }
      }
      _frames.add(ScreenFrame(lines, w > h));
    }, onError: (_) {});
  }

  /// Demande l'autorisation de capture puis démarre. Renvoie false si refusé.
  Future<bool> start() async {
    if (!isAvailable) return false;
    try {
      return await _method.invokeMethod<bool>('start') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    if (!isAvailable) return;
    try {
      await _method.invokeMethod<bool>('stop');
    } catch (_) {}
  }

  Future<bool> isRunning() async {
    if (!isAvailable) return false;
    try {
      return await _method.invokeMethod<bool>('isRunning') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _frames.close();
    await _stopped.close();
  }
}
