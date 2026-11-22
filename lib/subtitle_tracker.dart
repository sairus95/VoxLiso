import 'reading_vote.dart';
import 'spell_fixer.dart' show WordList;
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
///   par ligne : on ne lit que la partie nouvelle ;
/// - chaque lecture peut contenir des lettres mal lues : toutes les lectures
///   du sous-titre (images successives, lecture renforcée) sont comparées
///   mot à mot ([ReadingVote]) et, si elles ne sont pas d'accord, on attend
///   une image de plus pour départager.
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
  static const int _maxReadings = 10;

  /// Dictionnaire de la langue en cours (ou null), pour départager les lectures.
  WordList? Function()? dictionary;

  /// Si les lectures ne sont pas d'accord, attendre une image de plus avant de parler.
  bool waitOnDoubt = true;

  /// Le dernier texte rendu par [push] est le sous-titre entier (et non la
  /// fin d'un sous-titre en direct qui défile).
  bool lastWasFull = true;

  /// Sous-titre entier (toutes lectures combinées) du dernier texte rendu.
  String lastFull = '';

  String? _candidate;
  String _candidateNorm = '';
  int _count = 0;
  bool _candidateDone = false;
  bool _waited = false;
  final List<OcrReading> _readings = [];
  int _blank = 0;
  final List<String> _history = [];
  List<String> _lastWords = const [];

  void reset() {
    _candidate = null;
    _candidateNorm = '';
    _count = 0;
    _candidateDone = false;
    _waited = false;
    _readings.clear();
    _blank = 0;
    _history.clear();
    _lastWords = const [];
  }

  /// Donne la lecture de l'image courante (texte nettoyé, éventuellement vide),
  /// avec la confiance de ses mots et d'éventuelles autres lectures de la même
  /// image ([alternatives] : lecture renforcée).
  /// Renvoie le texte à dire maintenant, ou `null` s'il n'y a rien à dire.
  String? push(
    String text, {
    Map<String, double> confidence = const {},
    List<OcrReading> alternatives = const [],
  }) {
    final norm = normalizeForCompare(text);

    if (norm.replaceAll(' ', '').length < 2) {
      // Le sous-titre a disparu pendant qu'on départageait : on le dit quand même.
      final pending = _takePending();
      _blank++;
      if (_blank >= 2) {
        _candidate = null;
        _candidateNorm = '';
        _count = 0;
        _candidateDone = false;
        _readings.clear();
      }
      if (_blank >= blankFramesToForget) {
        _history.clear();
        _lastWords = const [];
      }
      return pending;
    }
    _blank = 0;

    String? pending;
    if (_candidate != null && similarity(norm, _candidateNorm) >= _sameReading) {
      _count++;
      // On garde la lecture la plus complète de ce sous-titre.
      if (norm.length > _candidateNorm.length) {
        _candidate = text;
        _candidateNorm = norm;
      }
    } else {
      // Nouveau sous-titre : le précédent, s'il attendait d'être départagé, est dit d'abord.
      pending = _takePending();
      _candidate = text;
      _candidateNorm = norm;
      _count = 1;
      _candidateDone = false;
      _waited = false;
      _readings.clear();
    }
    if (!_candidateDone) {
      _addReading(OcrReading(text, confidence: confidence));
      for (final alt in alternatives) {
        final altNorm = normalizeForCompare(alt.text);
        if (altNorm.isNotEmpty && similarity(altNorm, _candidateNorm) >= _sameReading) {
          _addReading(alt);
        }
      }
    }
    if (pending != null) return pending;

    if (_candidateDone || _count < stableFrames) return null;
    // Lectures en désaccord : une image de plus pour départager (une seule fois).
    if (waitOnDoubt && !_waited && !_readingsAgree()) {
      _waited = true;
      return null;
    }
    return _emitCandidate();
  }

  void _addReading(OcrReading r) {
    _readings.add(r);
    if (_readings.length > _maxReadings) _readings.removeAt(0);
  }

  bool _readingsAgree() {
    if (_readings.length < 2) return true;
    final first = normalizeForCompare(_readings.first.text);
    return _readings.every((r) => normalizeForCompare(r.text) == first);
  }

  /// Sous-titre assez vu mais pas encore dit (il attendait d'être départagé).
  String? _takePending() {
    if (_candidate == null || _candidateDone || _count < stableFrames) return null;
    return _emitCandidate();
  }

  /// Dit le sous-titre en cours : texte obtenu en combinant toutes ses lectures.
  String? _emitCandidate() {
    _candidateDone = true;
    var text = ReadingVote.combine(_readings, dict: dictionary?.call());
    if (normalizeForCompare(text).isEmpty) text = _candidate!;
    lastFull = text;
    return _emit(text, normalizeForCompare(text));
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
      lastWasFull = false;
      return tokens.sublist(overlap).map((t) => t.original).join(' ');
    }
    lastWasFull = true;
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
