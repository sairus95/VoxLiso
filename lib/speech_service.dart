import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_tts/flutter_tts.dart';

import 'languages.dart' show speechWeight;
import 'rate_pacer.dart';
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

  /// Phrases en attente, avec le numéro du sous-titre (appel à [sayAll]) d'où elles viennent.
  final Queue<({Utterance u, int batch})> _queue = Queue();
  int _batch = 0;
  bool _speaking = false;
  String? _current; // voix ou langue réglée en ce moment
  double _pitch = 1.0;

  /// Vitesse choisie dans les réglages (1.0 = normale) et vitesse réglée sur le moteur.
  double _baseRate = 1.0;
  double _appliedRate = -1;

  /// Si vrai, un nouveau sous-titre coupe celui en cours de lecture.
  bool interrupt = false;

  /// Vitesse automatique : accélère un peu quand la voix prend du retard.
  bool autoRate = true;
  final RatePacer _pacer = RatePacer();
  DateTime? _idleSince;

  /// Accélération en cours (1.0 = aucune), pour l'afficher.
  final ValueNotifier<double> boost = ValueNotifier(1.0);

  /// Au-delà de ce retard (caractères en attente, chinois/japonais/coréen ×3),
  /// les plus anciens sous-titres en attente sont abandonnés pour ne pas
  /// décrocher de l'image : environ 12 s de parole. Avant la v1.0.62, la limite
  /// était de 4 répliques : deux dialogues courts (« - Quoi ? - Rien. ») en
  /// attente suffisaient à faire sauter des phrases sans vrai retard.
  static const int maxWaitingChars = 240;

  /// Sous-titres abandonnés depuis le début (diagnostic).
  int dropped = 0;

  /// Nombre de phrases à retirer en tête de file pour revenir sous [maxChars] :
  /// des sous-titres entiers (toutes leurs répliques), les plus anciens, jamais
  /// le dernier arrivé. [queue] : (n° de sous-titre, poids en caractères).
  static int toDrop(List<({int batch, int weight})> queue, int maxChars) {
    var total = queue.fold<int>(0, (n, e) => n + e.weight);
    if (queue.isEmpty || total <= maxChars) return 0;
    final last = queue.last.batch;
    var i = 0;
    while (total > maxChars && i < queue.length && queue[i].batch != last) {
      final b = queue[i].batch;
      while (i < queue.length && queue[i].batch == b) {
        total -= queue[i].weight;
        i++;
      }
    }
    return i;
  }

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

  /// Change de moteur de synthèse vocale (Android : Google, Samsung…).
  /// La langue, la vitesse et la voix sont à régler de nouveau ensuite.
  Future<void> setEngine(String engine) async {
    try {
      // '' = moteur par défaut du téléphone.
      var name = engine;
      if (name.isEmpty) name = (await _tts.getDefaultEngine)?.toString() ?? '';
      if (name.isEmpty) return;
      await _tts.setEngine(name).timeout(const Duration(seconds: 8));
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
    _current = null;
    _pitch = -1; // force le réglage de la hauteur à la prochaine phrase
    _appliedRate = -1;
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
    _baseRate = rate;
    await _setRate(rate);
    return available;
  }

  Future<void> _setRate(double rate) async {
    // flutter_tts : 0.5 = vitesse normale sur Android comme sur iOS.
    await _tts.setSpeechRate((0.5 * rate).clamp(0.1, 1.0).toDouble());
    _appliedRate = rate;
  }

  /// Vitesse de la phrase qui commence : vitesse choisie, accélérée si les
  /// sous-titres suivants attendent déjà (vitesse automatique).
  Future<void> _paceFor(int batch) async {
    var factor = 1.0;
    if (autoRate && !interrupt) {
      // Retard = texte encore à dire alors qu'un sous-titre suivant est déjà arrivé.
      final behind = _queue.any((e) => e.batch != batch);
      // En chinois, japonais et coréen, un caractère se dit plus lentement : il compte triple.
      final waiting = behind ? _queue.fold<int>(0, (n, e) => n + speechWeight(e.u.text)) : 0;
      factor = _pacer.next(waiting);
    } else {
      _pacer.reset();
    }
    // iPhone : la vitesse d'AVSpeech monte plus vite qu'au-dessus de la normale
    // sur Android, on y applique une accélération plus douce.
    final effective = Platform.isIOS ? 1.0 + (factor - 1.0) * 0.6 : factor;
    final rate = (_baseRate * effective).clamp(0.2, 2.0).toDouble();
    if ((rate - _appliedRate).abs() > 0.01) await _setRate(rate);
    boost.value = factor;
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

  /// Voix coupée (réglage « Voix seulement dans les écouteurs », écouteurs
  /// débranchés) : rien n'est dit, le texte reste dans l'historique.
  bool muted = false;

  /// Dit plusieurs phrases à la suite (ex. les répliques d'un dialogue).
  void sayAll(List<Utterance> items) {
    if (items.isEmpty || muted) return;
    final batch = ++_batch;
    final entries = [for (final u in items) (u: u, batch: batch)];
    if (interrupt) {
      _queue
        ..clear()
        ..addAll(entries);
      if (_speaking) _tts.stop();
    } else {
      _queue.addAll(entries);
      final n = toDrop([
        for (final e in _queue) (batch: e.batch, weight: speechWeight(e.u.text)),
      ], maxWaitingChars);
      if (n > 0) {
        final batches = <int>{};
        for (var i = 0; i < n; i++) {
          batches.add(_queue.removeFirst().batch);
        }
        dropped += batches.length;
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
    // Après un vrai silence, on repart de la vitesse choisie.
    final idle = _idleSince;
    if (idle != null && DateTime.now().difference(idle) > const Duration(seconds: 2)) {
      _pacer.reset();
    }
    try {
      while (_queue.isNotEmpty) {
        final e = _queue.removeFirst();
        final u = e.u;
        await _apply(u);
        await _paceFor(e.batch);
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
      _idleSince = DateTime.now();
      boost.value = 1.0; // plus rien à dire : plus de retard
    }
  }

  Future<void> stop() async {
    _queue.clear();
    _pacer.reset();
    boost.value = 1.0;
    await _tts.stop();
  }
}
