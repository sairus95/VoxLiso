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

  static const int minLetters = 8;
  static const int strongLetters = 15;
  static const double strongConfidence = 0.75;
  static const double weakConfidence = 0.40;

  /// [scores] : code de langue -> confiance (0..1), tel que renvoyé par ML Kit.
  /// Renvoie la langue à utiliser pour ce sous-titre.
  String update(String text, Map<String, double> scores) {
    // Un idéogramme, un kana ou une syllabe coréenne compte pour trois lettres :
    // « 你在做什么 » est aussi parlant qu'une phrase de quinze lettres.
    var letters = 0;
    for (final m in RegExp(r'\p{L}', unicode: true).allMatches(text)) {
      final r = m.group(0)!.runes.first;
      letters += isCjkRune(r) || isHangulRune(r) ? 3 : 1;
    }
    if (letters < minLetters) return current;

    String? best;
    var bestScore = 0.0;
    scores.forEach((tag, conf) {
      final code = tag.split('-').first.toLowerCase();
      if (code == 'und') return; // langue indéterminée
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
      return current;
    }
    if (bestScore >= strongConfidence && letters >= strongLetters) {
      return _switchTo(best!);
    }
    if (_pending == best) {
      _pendingCount++;
    } else {
      _pending = best;
      _pendingCount = 1;
    }
    return _pendingCount >= 2 ? _switchTo(best!) : current;
  }

  String _switchTo(String code) {
    current = code;
    _pending = null;
    _pendingCount = 0;
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
