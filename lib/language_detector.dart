import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';

import 'languages.dart';

/// Décision de changement de langue à partir des scores de ML Kit.
/// Séparée de ML Kit pour pouvoir être testée.
///
/// Les sous-titres courts (« Oui. », « Ok ») sont souvent mal identifiés :
/// on ne change de langue que sur un texte assez long et une identification
/// sûre, ou si deux sous-titres de suite donnent la même nouvelle langue.
class LanguageDecision {
  LanguageDecision(this.current, {this.accept});

  /// Langues retenues en plus de fr/de/es/it (ex. le néerlandais, pour le traduire).
  /// null : seulement les 4 langues lues.
  final bool Function(String code)? accept;

  /// Langue actuelle (fr, de, es, it).
  String current;
  String? _pending;
  int _pendingCount = 0;
  int _pendingLetters = 0;

  /// Langues écrites avec leur propre écriture : jamais choisies pour un
  /// texte en alphabet latin (la voix japonaise ou chinoise épelait alors les
  /// sous-titres français lettre par lettre, retour du 28/11/2026).
  static const Set<String> cjkCodes = {'zh', 'ja', 'ko'};

  static const int minLetters = 8;

  /// Changement sur un seul sous-titre : au moins 20 lettres (15 en chinois,
  /// japonais, coréen, où l'écriture suffit à trancher) et une confiance de
  /// 0,85. Sinon il faut deux sous-titres de suite : une langue mal reconnue
  /// faisait lire ou traduire de travers (v1.0.62, avant 15 lettres et 0,75).
  static const int strongLetters = 20;
  static const int strongLettersCjk = 15;
  static const double strongConfidence = 0.85;
  static const double weakConfidence = 0.40;

  /// [scores] : code de langue -> confiance (0..1), tel que renvoyé par ML Kit.
  /// Renvoie la langue à utiliser pour ce sous-titre.
  String update(String text, Map<String, double> scores) {
    // Un idéogramme, un kana ou une syllabe coréenne compte pour trois lettres :
    // « 你在做什么 » est aussi parlant qu'une phrase de quinze lettres.
    var letters = 0;
    var cjk = false;
    for (final m in RegExp(r'\p{L}', unicode: true).allMatches(text)) {
      final r = m.group(0)!.runes.first;
      final wide = isCjkRune(r) || isHangulRune(r);
      cjk = cjk || wide;
      letters += wide ? 3 : 1;
    }
    if (letters < minLetters) return current;

    String? best;
    var bestScore = 0.0;
    scores.forEach((tag, conf) {
      final lower = tag.toLowerCase();
      final code = lower.split('-').first;
      if (code == 'und') return; // langue indéterminée
      // « ja-Latn », « zh-Latn », « hi-Latn »… : japonais, chinois, hindi écrits
      // en lettres latines, ce que ML Kit croit voir dans des mots courts ou mal
      // lus (« Ah ! Oui… »). Ce ne sont jamais des sous-titres à lire en japonais.
      if (lower.contains('-latn')) return;
      if (!cjk && cjkCodes.contains(code)) return;
      final ok = supportedLanguage(code) != null || (accept?.call(code) ?? false);
      if (ok && conf > bestScore) {
        best = code;
        bestScore = conf;
      }
    });
    if (best == null || bestScore < weakConfidence) return current;

    if (best == current) {
      _pending = null;
      _pendingCount = 0;
      _pendingLetters = 0;
      return current;
    }
    if (bestScore >= strongConfidence && letters >= (cjk ? strongLettersCjk : strongLetters)) {
      return _switchTo(best!);
    }
    if (_pending == best) {
      _pendingCount++;
      _pendingLetters += letters;
    } else {
      _pending = best;
      _pendingCount = 1;
      _pendingLetters = letters;
    }
    // Deux sous-titres de suite, assez longs à eux deux (24 lettres), ou trois :
    // dans une discussion rapide, les répliques courtes sont souvent mal reconnues.
    final enough = _pendingCount >= 3 || (_pendingCount >= 2 && _pendingLetters >= 24);
    return enough ? _switchTo(best!) : current;
  }

  String _switchTo(String code) {
    current = code;
    _pending = null;
    _pendingCount = 0;
    _pendingLetters = 0;
    return code;
  }
}

/// Détection automatique de la langue des sous-titres (ML Kit, hors ligne).
class LanguageDetector {
  LanguageDetector(String initial, {bool Function(String code)? accept})
      : decision = LanguageDecision(initial, accept: accept);

  final LanguageIdentifier _identifier = LanguageIdentifier(confidenceThreshold: 0.1);
  final LanguageDecision decision;

  String get current => decision.current;

  Future<String> detect(String text) async {
    try {
      final found = await _identifier.identifyPossibleLanguages(text);
      return decision.update(text, {
        for (final l in found) l.languageTag: l.confidence,
      });
    } catch (_) {
      return decision.current;
    }
  }

  Future<void> close() => _identifier.close();
}
