import 'dart:convert';

import 'reading_vote.dart';
import 'spell_fixer.dart';
import 'text_tools.dart';

/// Apprentissage des mots, sur le téléphone (demande du 28/11/2026 :
/// « intégrer une intelligence artificielle pour apprendre les mots pour mieux
/// les reconnaître »).
///
/// À chaque sous-titre dit, VoxLiso apprend trois choses, langue par langue :
///
/// 1. **Les mots absents du dictionnaire** mais lus souvent et sans hésiter
///    (toutes les lectures d'accord, ou ML Kit sûr de lui) : noms des
///    personnages, des lieux, mots d'une série. Vus dans 3 sous-titres
///    différents, ils entrent dans le dictionnaire ([WordList.addLearned]) :
///    le vote les préfère, la correction ne les « corrige » plus et y ramène
///    les lectures abîmées (« Herrnione » -> « Hermione »).
/// 2. **Les erreurs de lecture** : quand le vote garde un mot connu alors
///    qu'une autre lecture donnait un mot inconnu qui lui ressemble
///    (« rnaison » / « maison »), l'erreur est retenue. Vue 2 fois, elle est
///    corrigée directement ([applyFixes]), même quand le sous-titre n'a été
///    lu qu'une fois (sous-titre bref).
/// 3. **Les suites de mots** (deux mots qui se suivent) des sous-titres nets :
///    un petit modèle de langue ([WordContext]) qui départage deux lectures
///    qui sont toutes deux de vrais mots (« ne sais pas » / « ne sait pas »).
///
/// Rien n'est envoyé : tout reste dans les réglages du téléphone (JSON).
class WordLearner {
  WordLearner();

  /// Score à atteindre pour qu'un mot soit appris (un sous-titre où toutes
  /// les lectures sont d'accord compte 1, une lecture unique sans confiance 0,5).
  static const double learnScore = 3;

  /// Une erreur de lecture vue autant de fois est corrigée directement.
  static const int fixCount = 2;

  /// Limites par langue (les plus anciens sont oubliés d'abord).
  static const int maxCandidates = 3000;
  static const int maxWords = 2000;
  static const int maxFixes = 600;
  static const int maxPairs = 8000;

  /// Un mot en cours d'apprentissage pas revu depuis autant de jours est oublié.
  static const int candidateDays = 60;

  final Map<String, _Lang> _langs = {};
  final Map<String, WordList> _lists = {};

  /// Derniers sous-titres appris : un même sous-titre redit ne compte pas deux fois.
  final List<String> _recent = [];

  bool _enabled = true;

  /// Apprentissage en service. Arrêté, les mots appris sont aussi retirés des
  /// dictionnaires (pour comparer avec et sans), mais rien n'est effacé.
  bool get enabled => _enabled;
  set enabled(bool v) {
    if (v == _enabled) return;
    _enabled = v;
    _lists.forEach((lang, list) {
      for (final w in _langs[lang]?.words.keys ?? const <String>[]) {
        v ? list.addLearned(w) : list.removeLearned(w);
      }
    });
  }

  /// Le dictionnaire d'une langue vient d'être chargé : on y ajoute les mots appris.
  void bind(String lang, WordList list) {
    _lists[lang] = list;
    if (!_enabled) return;
    for (final w in _langs[lang]?.words.keys ?? const <String>[]) {
      list.addLearned(w);
    }
  }

  // --------------------------------------------------------------- apprendre

  /// Apprend d'un sous-titre dit : [text] (toutes lectures combinées, avant
  /// correction), [readings] (ses lectures), [dict] (dictionnaire de [lang]).
  /// Renvoie les mots qui viennent d'être appris.
  List<String> observe(String lang, String text,
      {required WordList dict, List<OcrReading> readings = const [], DateTime? now}) {
    if (!_enabled) return const [];
    final norm = normalizeForCompare(text);
    if (norm.replaceAll(' ', '').length < 2) return const [];
    if (_recent.contains('$lang|$norm')) return const [];
    _recent.add('$lang|$norm');
    if (_recent.length > 8) _recent.removeAt(0);

    _lists[lang] ??= dict;
    final l = _langs.putIfAbsent(lang, _Lang.new);
    final day = _day(now);
    _learnPairs(l, text, dict);
    _learnFixes(l, text, readings, dict);
    final learned = _learnWords(l, lang, text, readings, dict, day);
    if (l.observed++ % 200 == 0) l.prune(day);
    return learned;
  }

  static final RegExp _word = RegExp(r"[\p{L}'’]+", unicode: true);
  static final RegExp _apostrophe = RegExp(r"['’]");
  static final RegExp _sentenceEnd = RegExp(r'[.!?…]$');
  static final RegExp _vowel = RegExp('[aeiouy]');
  static final RegExp _tripled = RegExp(r'(.)\1\1');

  /// Mots d'un texte (lettres et apostrophes), ceux de 2 lettres ou plus.
  static List<String> _words(String text) => [
        for (final m in _word.allMatches(text))
          if (m[0]!.replaceAll(_apostrophe, '').length >= 2) m[0]!,
      ];

  /// Partie à apprendre d'un mot : la plus longue entre les apostrophes
  /// (« d'Arya » -> « Arya », « Arya's » -> « Arya »).
  static String _core(String word) {
    final parts = word.split(_apostrophe);
    var best = parts.first;
    for (final p in parts) {
      if (p.length > best.length) best = p;
    }
    return best;
  }

  /// Un mot qui peut être appris : 3 à 24 lettres, une voyelle, pas trois fois
  /// la même lettre, pas un sigle (« HD », « TF »).
  static bool _learnable(String core) {
    final letters = core.runes.length;
    if (letters < 3 || letters > 24) return false;
    if (letters <= 4 && core == core.toUpperCase()) return false;
    final simple = normalizeForCompare(core);
    if (simple.contains(' ') || !_vowel.hasMatch(simple)) return false;
    return !_tripled.hasMatch(simple);
  }

  List<String> _learnWords(
      _Lang l, String lang, String text, List<OcrReading> readings, WordList dict, int day) {
    final words = _words(text);
    if (words.isEmpty) return const [];
    final known = words.where((w) => ReadingVote.isKnownWord(w, dict)).length;
    // Un sous-titre surtout fait de mots inconnus : image floue, autre langue, décor.
    if (words.length > 2 && known < words.length * 0.5) return const [];
    final readingTokens = <Set<String>>[
      for (final r in readings)
        {for (final t in ReadingVote.tokens(r.text)) normalizeForCompare(_core(t))},
    ];
    final learned = <String>[];
    final seen = <String>{};
    for (final w in words) {
      final core = _core(w);
      final lower = core.toLowerCase();
      if (!seen.add(lower)) continue;
      final used = l.words.remove(lower);
      if (used != null) {
        // Déjà appris : revu (il passe en fin de liste, oublié en dernier).
        l.words[lower] = (used.$1 + 1, day);
        continue;
      }
      if (ReadingVote.isKnownWord(core, dict) || !_learnable(core)) continue;
      if ((l.fixes[lower]?.$2 ?? 0) >= fixCount) continue; // erreur de lecture connue
      // Mot que la correction ramène à un mot courant : sans doute mal lu.
      final fixed = SpellFixer.fix(lower, dict);
      if (fixed != lower &&
          fixed.split(' ').every((p) => (dict.rank[p] ?? WordList.learnedRank) < 5000)) {
        continue;
      }
      final weight = _agreement(normalizeForCompare(core), readings, readingTokens);
      if (weight <= 0) continue;
      final prev = l.candidates.remove(lower);
      final score = (prev?.$1 ?? 0) + weight;
      if (score >= learnScore) {
        l.words[lower] = (1, day);
        l.fixes.remove(lower);
        if (l.words.length > maxWords) {
          final old = l.words.keys.first;
          l.words.remove(old);
          dict.removeLearned(old);
          _lists[lang]?.removeLearned(old);
        }
        dict.addLearned(lower);
        _lists[lang]?.addLearned(lower);
        learned.add(lower);
      } else {
        l.candidates[lower] = (score, day);
        if (l.candidates.length > maxCandidates) l.candidates.remove(l.candidates.keys.first);
      }
    }
    return learned;
  }

  /// Poids d'un sous-titre pour un mot : 1 si toutes ses lectures (2 ou plus)
  /// l'ont lu pareil, ou si ML Kit en est sûr (lecture unique) ; 0,5 pour une
  /// lecture unique sans confiance (iPhone) ; sinon 0 (lectures en désaccord).
  static double _agreement(String norm, List<OcrReading> readings, List<Set<String>> tokens) {
    if (readings.length >= 2) {
      final have = tokens.where((t) => t.contains(norm)).length;
      if (have == readings.length) return 1;
      if (readings.length >= 3 && have >= readings.length * 2 / 3) return 0.5;
      return 0;
    }
    if (readings.isEmpty) return 0.5;
    final c = readings.first.confidence[norm];
    if (c == null) return 0.5;
    return c >= 0.85 ? 1 : 0;
  }

  /// Mots inconnus d'une lecture que le vote a remplacés par un mot connu qui
  /// leur ressemble : erreurs de lecture.
  void _learnFixes(_Lang l, String text, List<OcrReading> readings, WordList dict) {
    if (readings.length < 2) return;
    final chosen = <String>{
      for (final w in _words(text))
        if (ReadingVote.isKnownWord(_core(w), dict)) _core(w).toLowerCase(),
    };
    if (chosen.isEmpty) return;
    final done = <String>{};
    for (final r in readings) {
      for (final w in _words(r.text)) {
        final wrong = _core(w).toLowerCase();
        if (wrong.runes.length < 3 || chosen.contains(wrong) || done.contains(wrong)) continue;
        if (ReadingVote.isKnownWord(wrong, dict)) continue;
        final wn = normalizeForCompare(wrong);
        String? right;
        var best = 0.0;
        for (final c in chosen) {
          if ((c.length - wrong.length).abs() > 2) continue;
          final cn = normalizeForCompare(c);
          if (cn == wn) continue; // même mot, accents seulement
          final sim = similarity(wn, cn);
          if (sim >= 0.7 && sim > best) {
            best = sim;
            right = c;
          }
        }
        if (right == null) continue;
        done.add(wrong);
        final prev = l.fixes.remove(wrong);
        l.fixes[wrong] = (right, prev != null && prev.$1 == right ? prev.$2 + 1 : 1);
        if (l.fixes.length > maxFixes) l.fixes.remove(l.fixes.keys.first);
        l.candidates.remove(wrong); // ce n'était pas un vrai mot
      }
    }
  }

  /// Suites de deux mots d'un sous-titre net (sans traverser une fin de phrase).
  void _learnPairs(_Lang l, String text, WordList dict) {
    if (!ReadingVote.looksClean(text, dict)) return;
    String? prev;
    for (final t in ReadingVote.tokens(text)) {
      final n = normalizeForCompare(t);
      if (n.isEmpty) {
        prev = null;
        continue;
      }
      if (prev != null) {
        final key = '$prev|$n';
        final c = l.pairs.remove(key) ?? 0;
        l.pairs[key] = c + 1;
      }
      prev = _sentenceEnd.hasMatch(t) ? null : n;
    }
    if (l.pairs.length > maxPairs) l.prunePairs(maxPairs);
  }

  // ---------------------------------------------------------------- utiliser

  /// Remplace les erreurs de lecture apprises (vues [fixCount] fois) par le
  /// bon mot, en gardant les majuscules. Un mot du dictionnaire n'est jamais touché.
  String applyFixes(String lang, String text, {WordList? dict}) {
    final l = _langs[lang];
    if (!_enabled || l == null || l.fixes.isEmpty) return text;
    return text.replaceAllMapped(_letterRun, (m) {
      final word = m[0]!;
      final lower = word.toLowerCase();
      final fix = l.fixes[lower];
      if (fix == null || fix.$2 < fixCount) return word;
      if (dict != null && dict.contains(lower)) return word;
      final right = fix.$1;
      if (word.length > 1 && word == word.toUpperCase()) return right.toUpperCase();
      if (word[0] != word[0].toLowerCase()) return right[0].toUpperCase() + right.substring(1);
      return right;
    });
  }

  static final RegExp _letterRun = RegExp(r'\p{L}+', unicode: true);

  /// Suites de mots apprises d'une langue (null s'il n'y en a pas encore).
  WordContext? contextFor(String lang) {
    final l = _langs[lang];
    if (!_enabled || l == null || l.pairs.isEmpty) return null;
    return _PairContext(l.pairs);
  }

  // ------------------------------------------------------- voir et oublier

  /// Mots appris d'une langue, les plus revus d'abord.
  List<String> wordsOf(String lang) {
    final e = (_langs[lang]?.words.entries.toList() ?? [])
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    return [for (final x in e) x.key];
  }

  /// Langues qui ont des mots appris.
  List<String> get languages => [
        for (final e in _langs.entries)
          if (e.value.words.isNotEmpty) e.key,
      ];

  int wordCount([String? lang]) => lang != null
      ? _langs[lang]?.words.length ?? 0
      : _langs.values.fold(0, (n, l) => n + l.words.length);

  /// Erreurs de lecture apprises (vues [fixCount] fois ou plus).
  int fixCountOf([String? lang]) {
    int count(_Lang l) => l.fixes.values.where((f) => f.$2 >= fixCount).length;
    return lang != null
        ? (_langs[lang] == null ? 0 : count(_langs[lang]!))
        : _langs.values.fold(0, (n, l) => n + count(l));
  }

  int pairCount([String? lang]) => lang != null
      ? _langs[lang]?.pairs.length ?? 0
      : _langs.values.fold(0, (n, l) => n + l.pairs.length);

  /// Oublie un mot appris (il redevient inconnu).
  void forget(String lang, String word) {
    final w = word.toLowerCase();
    _langs[lang]?.words.remove(w);
    _langs[lang]?.candidates.remove(w);
    _lists[lang]?.removeLearned(w);
  }

  /// Oublie tout ce qui a été appris.
  void clear() {
    _lists.forEach((lang, list) {
      for (final w in List.of(list.learned)) {
        list.removeLearned(w);
      }
    });
    _langs.clear();
    _recent.clear();
  }

  // ------------------------------------------------------------ mémoriser

  static int _day(DateTime? now) =>
      (now ?? DateTime.now()).toUtc().difference(DateTime.utc(2026)).inDays;

  String toJson() => jsonEncode({
        'v': 1,
        'langs': {for (final e in _langs.entries) e.key: e.value.toJson()},
      });

  /// Relit ce qui a été appris ; un texte illisible donne un apprentissage vide.
  static WordLearner fromJson(String? json) {
    final learner = WordLearner();
    if (json == null || json.isEmpty) return learner;
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      final langs = data['langs'] as Map<String, dynamic>? ?? const {};
      langs.forEach((lang, v) {
        learner._langs[lang] = _Lang.fromJson(v as Map<String, dynamic>);
      });
    } catch (_) {
      learner._langs.clear();
    }
    return learner;
  }
}

/// Ce qui est appris pour une langue. Dans chaque table, l'ordre est celui de
/// la dernière utilisation : les plus anciens, en tête, sont oubliés d'abord.
class _Lang {
  _Lang();

  /// Mot appris -> (nombre de fois revu, jour).
  final Map<String, (int, int)> words = {};

  /// Mot en cours d'apprentissage -> (score, jour de la dernière lecture).
  final Map<String, (double, int)> candidates = {};

  /// Mot mal lu -> (bon mot, nombre de fois).
  final Map<String, (String, int)> fixes = {};

  /// « mot|mot suivant » (formes simplifiées) -> nombre de fois.
  final Map<String, int> pairs = {};

  int observed = 0;

  void prune(int day) {
    candidates.removeWhere((_, c) => day - c.$2 > WordLearner.candidateDays);
  }

  /// Trop de suites : on oublie d'abord les plus anciennes vues une seule fois.
  void prunePairs(int max) {
    final target = (max * 0.8).round();
    final once = [
      for (final e in pairs.entries)
        if (e.value == 1) e.key,
    ];
    for (final k in once) {
      if (pairs.length <= target) break;
      pairs.remove(k);
    }
    while (pairs.length > target) {
      pairs.remove(pairs.keys.first);
    }
  }

  Map<String, dynamic> toJson() => {
        'words': {for (final e in words.entries) e.key: [e.value.$1, e.value.$2]},
        'cands': {for (final e in candidates.entries) e.key: [e.value.$1, e.value.$2]},
        'fixes': {for (final e in fixes.entries) e.key: [e.value.$1, e.value.$2]},
        'pairs': pairs,
      };

  static _Lang fromJson(Map<String, dynamic> j) {
    final l = _Lang();
    (j['words'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      final a = v as List;
      l.words[k] = ((a[0] as num).toInt(), (a[1] as num).toInt());
    });
    (j['cands'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      final a = v as List;
      l.candidates[k] = ((a[0] as num).toDouble(), (a[1] as num).toInt());
    });
    (j['fixes'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      final a = v as List;
      l.fixes[k] = (a[0] as String, (a[1] as num).toInt());
    });
    (j['pairs'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      l.pairs[k] = (v as num).toInt();
    });
    return l;
  }
}

class _PairContext implements WordContext {
  _PairContext(this._pairs);
  final Map<String, int> _pairs;

  /// Une suite vue 4 fois ou plus compte entièrement.
  @override
  double follows(String previous, String word) {
    final c = _pairs['$previous|$word'];
    if (c == null) return 0;
    return c >= 4 ? 1 : c / 4;
  }
}
