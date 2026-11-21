import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter_tts/flutter_tts.dart';

import 'voices.dart';

/// Une phrase à dire, avec sa langue, sa voix et sa hauteur.
class Utterance {
  const Utterance(this.text, {this.locale, this.voice, this.pitch = 1.0});
  final String text;
  final String? locale;

  /// Voix précise (sinon : voix par défaut de [locale]).
  final TtsVoice? voice;

  /// Hauteur : 1.0 = normale. Sert à distinguer deux personnages
  /// quand le téléphone n'a qu'une seule voix pour la langue.
  final double pitch;
}

/// Synthèse vocale avec une petite file d'attente.
class SpeechService {
  final FlutterTts _tts = FlutterTts();
  final Queue<Utterance> _queue = Queue();
  bool _speaking = false;
  String? _current; // voix ou langue réglée en ce moment
  double _pitch = 1.0;

  /// Si vrai, un nouveau sous-titre coupe celui en cours de lecture.
  bool interrupt = false;

  /// Au-delà, les plus anciennes phrases en attente sont abandonnées
  /// pour ne pas prendre de retard sur l'image.
  static const int _maxQueue = 4;

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

  /// Toutes les voix installées sur le téléphone (format brut de flutter_tts).
  Future<Object?> rawVoices() async {
    try {
      return await _tts.getVoices;
    } catch (_) {
      return null;
    }
  }

  /// Choisit la langue et la vitesse. Renvoie `false` si la voix de cette
  /// langue n'est pas installée sur le téléphone.
  Future<bool> configure({required String locale, required double rate}) async {
    final available = await isAvailable(locale);
    await _tts.setLanguage(locale);
    _current = 'l:$locale';
    // flutter_tts : 0.5 = vitesse normale sur Android comme sur iOS.
    await _tts.setSpeechRate((0.5 * rate).clamp(0.1, 1.0).toDouble());
    return available;
  }

  /// La voix de [locale] est-elle installée sur le téléphone ?
  Future<bool> isAvailable(String locale) async {
    try {
      final res = await _tts.isLanguageAvailable(locale);
      return res == true || res == 1;
    } catch (_) {
      return true;
    }
  }

  /// Dit [text], avec la langue / la voix données si précisées.
  void say(String text, {String? locale, TtsVoice? voice, double pitch = 1.0}) =>
      sayAll([Utterance(text, locale: locale, voice: voice, pitch: pitch)]);

  /// Dit plusieurs phrases à la suite (ex. les répliques d'un dialogue).
  void sayAll(List<Utterance> items) {
    if (items.isEmpty) return;
    if (interrupt) {
      _queue
        ..clear()
        ..addAll(items);
      if (_speaking) _tts.stop();
    } else {
      _queue.addAll(items);
      while (_queue.length > _maxQueue) {
        _queue.removeFirst();
      }
    }
    _drain();
  }

  Future<void> _apply(Utterance u) async {
    final key = u.voice != null ? 'v:${u.voice!.key}' : (u.locale != null ? 'l:${u.locale}' : null);
    if (key != null && key != _current) {
      var ok = false;
      if (u.voice != null) {
        try {
          final res = await _tts.setVoice(u.voice!.toTts());
          ok = res == 1 || res == true;
        } catch (_) {}
      }
      if (!ok) {
        await _tts.setLanguage(u.locale ?? u.voice!.locale);
      }
      _current = key;
    }
    if (u.pitch != _pitch) {
      await _tts.setPitch(u.pitch);
      _pitch = u.pitch;
    }
  }

  Future<void> _drain() async {
    if (_speaking) return;
    _speaking = true;
    try {
      while (_queue.isNotEmpty) {
        final u = _queue.removeFirst();
        await _apply(u);
        // Sécurité : ne jamais rester bloqué si la fin de lecture n'est pas signalée.
        final limit = Duration(seconds: 6 + u.text.length ~/ 6);
        try {
          await _tts.speak(u.text).timeout(limit);
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
