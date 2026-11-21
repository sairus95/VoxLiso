import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter_tts/flutter_tts.dart';

/// Synthèse vocale avec une petite file d'attente.
class SpeechService {
  final FlutterTts _tts = FlutterTts();
  final Queue<String> _queue = Queue<String>();
  bool _speaking = false;

  /// Si vrai, un nouveau sous-titre coupe celui en cours de lecture.
  bool interrupt = false;

  /// Au-delà, les plus anciens sous-titres en attente sont abandonnés
  /// pour ne pas prendre de retard sur l'image.
  static const int _maxQueue = 2;

  Future<void> init() async {
    await _tts.awaitSpeakCompletion(true);
    if (Platform.isIOS) {
      await _tts.setSharedInstance(true);
      // « playback » : la voix fonctionne même si le bouton silencieux est activé.
      await _tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [IosTextToSpeechAudioCategoryOptions.mixWithOthers],
        IosTextToSpeechAudioMode.spokenAudio,
      );
    }
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  /// Choisit la langue et la vitesse. Renvoie `false` si la voix de cette
  /// langue n'est pas installée sur le téléphone.
  Future<bool> configure({required String locale, required double rate}) async {
    var available = true;
    try {
      final res = await _tts.isLanguageAvailable(locale);
      available = res == true || res == 1;
    } catch (_) {}
    await _tts.setLanguage(locale);
    // flutter_tts : 0.5 = vitesse normale sur Android comme sur iOS.
    await _tts.setSpeechRate((0.5 * rate).clamp(0.1, 1.0).toDouble());
    return available;
  }

  void say(String text) {
    if (interrupt) {
      _queue
        ..clear()
        ..add(text);
      if (_speaking) _tts.stop();
    } else {
      _queue.add(text);
      while (_queue.length > _maxQueue) {
        _queue.removeFirst();
      }
    }
    _drain();
  }

  Future<void> _drain() async {
    if (_speaking) return;
    _speaking = true;
    try {
      while (_queue.isNotEmpty) {
        final text = _queue.removeFirst();
        // Sécurité : ne jamais rester bloqué si la fin de lecture n'est pas signalée.
        final limit = Duration(seconds: 6 + text.length ~/ 6);
        try {
          await _tts.speak(text).timeout(limit);
        } on TimeoutException {
          await _tts.stop();
        }
      }
    } finally {
      _speaking = false;
    }
  }

  Future<void> stop() async {
    _queue.clear();
    await _tts.stop();
  }
}
