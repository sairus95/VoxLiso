import 'text_tools.dart';

class _Token {
  _Token(this.original, this.normalized);
  final String original;
  final String normalized;
}

/// Décide QUAND un sous-titre doit être lu, à partir des lectures
/// successives de l'OCR (plusieurs par seconde).
///
/// Problèmes réglés ici :
/// - un sous-titre reste affiché 2 à 5 secondes : il ne doit être dit qu'une
///   fois, même si l'OCR le relit avec de petites erreurs différentes ;
/// - une image floue peut donner une lecture fausse : on attend que la même
///   lecture revienne [stableFrames] fois avant de parler ;
/// - les sous-titres « en direct » (journal TV) défilent mot à mot ou ligne
///   par ligne : on ne lit que la partie nouvelle.
class SubtitleTracker {
  SubtitleTracker({this.stableFrames = 2, this.blankFramesToForget = 6});

  /// Nombre de lectures concordantes avant de parler.
  int stableFrames;

  /// Après autant d'images sans texte, on oublie ce qui a déjà été dit
  /// (un même sous-titre pourra donc être relu plus tard).
  final int blankFramesToForget;

  static const double _sameReading = 0.80;
  static const double _alreadySaid = 0.75;
  static const int _minOverlapWords = 3;
  static const int _historySize = 4;

  String? _candidate;
  String _candidateNorm = '';
  int _count = 0;
  bool _candidateDone = false;
  int _blank = 0;
  final List<String> _history = [];
  List<String> _lastWords = const [];

  void reset() {
    _candidate = null;
    _candidateNorm = '';
    _count = 0;
    _candidateDone = false;
    _blank = 0;
    _history.clear();
    _lastWords = const [];
  }

  /// Donne la lecture de l'image courante (texte nettoyé, éventuellement vide).
  /// Renvoie le texte à dire maintenant, ou `null` s'il n'y a rien à dire.
  String? push(String text) {
    final norm = normalizeForCompare(text);

    if (norm.replaceAll(' ', '').length < 2) {
      _blank++;
      if (_blank >= 2) {
        _candidate = null;
        _candidateNorm = '';
        _count = 0;
        _candidateDone = false;
      }
      if (_blank >= blankFramesToForget) {
        _history.clear();
        _lastWords = const [];
      }
      return null;
    }
    _blank = 0;

    if (_candidate != null && similarity(norm, _candidateNorm) >= _sameReading) {
      _count++;
      // On garde la lecture la plus complète de ce sous-titre.
      if (norm.length > _candidateNorm.length) {
        _candidate = text;
        _candidateNorm = norm;
      }
    } else {
      _candidate = text;
      _candidateNorm = norm;
      _count = 1;
      _candidateDone = false;
    }

    if (_candidateDone || _count < stableFrames) return null;
    _candidateDone = true;
    return _emit(_candidate!, _candidateNorm);
  }

  String? _emit(String text, String norm) {
    final normWordCount = norm.split(' ').length;
    for (final said in _history) {
      if (similarity(norm, said) >= _alreadySaid) return null;
      // Une partie d'un sous-titre déjà lu (ex. une ligne qui disparaît).
      if (normWordCount >= 3 && ' $said '.contains(' $norm ')) return null;
    }

    final tokens = _tokenize(text);
    final words = tokens.map((t) => t.normalized).toList();
    final overlap = _overlap(_lastWords, words);

    _lastWords = words;
    _history.add(norm);
    if (_history.length > _historySize) _history.removeAt(0);

    if (overlap > 0) {
      if (overlap >= tokens.length) return null;
      return tokens.sublist(overlap).map((t) => t.original).join(' ');
    }
    return text;
  }

  static List<_Token> _tokenize(String text) {
    final out = <_Token>[];
    for (final w in text.split(RegExp(r'\s+'))) {
      final n = normalizeForCompare(w);
      if (n.isNotEmpty) out.add(_Token(w, n));
    }
    return out;
  }

  /// Plus grand k tel que les k derniers mots de [prev] correspondent aux
  /// k premiers mots de [cur] (k >= 3), sinon 0.
  static int _overlap(List<String> prev, List<String> cur) {
    final maxK = prev.length < cur.length ? prev.length : cur.length;
    for (var k = maxK; k >= _minOverlapWords; k--) {
      var mismatches = 0;
      final allowed = k ~/ 4;
      for (var i = 0; i < k; i++) {
        final a = prev[prev.length - k + i];
        final b = cur[i];
        if (a != b && similarity(a, b) < 0.75) {
          mismatches++;
          if (mismatches > allowed) break;
        }
      }
      if (mismatches <= allowed) return k;
    }
    return 0;
  }
}
