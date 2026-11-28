import 'dart:convert';

import 'reading_vote.dart';
import 'spell_fixer.dart';
import 'text_tools.dart';

/// Apprentissage des mots, sur le téléphone (demande du 28/11/2026 :
/// « intégrer une intelligence artificielle pour apprendre les mots pour mieux
/// les reconnaître » ; rendu plus robuste le même jour, voir plus bas).
///
/// À chaque sous-titre dit, VoxLiso apprend trois choses, langue par langue :
///
/// 1. **Les mots absents du dictionnaire** mais lus souvent et sans hésiter
///    (noms des personnages, des lieux, mots d'une série). Ils entrent dans le
///    dictionnaire ([WordList.addLearned]) : le vote les préfère et la
///    correction ne les « corrige » plus. Une fois **confirmés** (revus sans
///    désaccord), la correction y ramène aussi les lectures abîmées
///    (« Herrnione » -> « Hermione »).
/// 2. **Les erreurs de lecture** : quand le vote garde un mot connu alors
///    qu'une autre lecture donnait un mot inconnu qui lui ressemble
///    (« rnaison » / « maison »), l'erreur est retenue. Vue dans 2 sous-titres,
///    elle est corrigée directement ([applyFixes]).
/// 3. **Les suites de mots** des sous-titres nets : un petit modèle de langue
///    ([WordContext]) qui départage deux lectures qui sont toutes deux de vrais
///    mots (« ne sais pas » / « ne sait pas »).
///
/// **Robustesse** (2e version) :
/// - les preuves comptent par **image** : la lecture normale et la lecture
///   renforcée d'une même image ne font pas deux preuves ([OcrReading.frame]) ;
/// - il faut **plus de preuves** pour un mot qui n'a pas l'air d'un nom (3 pour
///   un mot écrit avec une majuscule au milieu d'une phrase, 4 sinon, 6 s'il
///   ressemble à un mot du dictionnaire : sans doute un mot mal lu) ;
/// - un mot appris est d'abord **à confirmer** : il compte comme un mot de la
///   langue, mais la correction n'y ramène rien avant [confirmUses] confirmations ;
/// - un mot appris que les lectures **contredisent** (une autre lecture donne un
///   mot du dictionnaire qui lui ressemble) est **oublié tout seul** et ne sera
///   plus appris ; un mot oublié à la main non plus ;
/// - une erreur de lecture apprise est retirée si le « mauvais » mot est
///   ensuite lu sans hésiter ; elle ne touche pas un nom propre (majuscule au
///   milieu d'une phrase) avant d'avoir été vue [fixCountName] fois ;
/// - au plus [maxNewPerWindow] mots appris en 10 minutes par langue
///   (générique de fin, page de texte filmée…) ;
/// - le lecteur n'apprend pas d'un sous-titre dont la langue vient de changer
///   (détection de langue hésitante) ;
/// - mémoire relue langue par langue : une langue abîmée n'efface pas les autres.
///
/// Rien n'est envoyé : tout reste dans les réglages du téléphone (JSON).
class WordLearner {
  WordLearner();

  /// Preuves à réunir pour apprendre un mot : vu comme un nom (majuscule au
  /// milieu d'une phrase), mot ordinaire, mot qui ressemble à un mot connu.
  static const double learnScoreName = 3;
  static const double learnScore = 4;
  static const double learnScoreNear = 6;

  /// Confirmations (sous-titres où toutes les lectures l'ont) avant que la
  /// correction ramène vers un mot appris.
  static const int confirmUses = 3;

  /// Contradictions qui font oublier un mot appris (et plus que la moitié de
  /// ses confirmations).
  static const int unlearnContra = 2;

  /// Une erreur de lecture vue dans autant de sous-titres est corrigée
  /// directement ; sur un mot qui a l'air d'un nom, il en faut [fixCountName].
  static const int fixCount = 2;
  static const int fixCountName = 4;

  /// Au plus autant de nouveaux mots en [newWindow] par langue.
  static const int maxNewPerWindow = 15;
  static const Duration newWindow = Duration(minutes: 10);

  /// Limites par langue (les plus anciens sont oubliés d'abord).
  static const int maxCandidates = 3000;
  static const int maxWords = 2000;
  static const int maxFixes = 600;
  static const int maxPairs = 8000;
  static const int maxBlocked = 1000;

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
      final l = _langs[lang];
      if (l == null) return;
      l.words.forEach((w, info) => v ? list.addLearned(w, rank: _rankOf(info)) : list.removeLearned(w));
    });
  }

  static int _rankOf(_Word w) =>
      w.uses >= confirmUses ? WordList.learnedRank : WordList.provisionalRank;

  /// Le dictionnaire d'une langue vient d'être chargé : on y ajoute les mots appris.
  void bind(String lang, WordList list) {
    _lists[lang] = list;
    if (!_enabled) return;
    _langs[lang]?.words.forEach((w, info) => list.addLearned(w, rank: _rankOf(info)));
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
    final time = now ?? DateTime.now();
    final day = _day(time);
    _learnPairs(l, text, dict, readings);
    _learnFixes(l, lang, text, readings, dict);
    final learned = _learnWords(l, lang, text, readings, dict, day, time);
    if (l.observed++ % 200 == 0) l.prune(day);
    return learned;
  }

  static final RegExp _word = RegExp(r"[\p{L}'’]+", unicode: true);
  static final RegExp _apostrophe = RegExp(r"['’]");
  static final RegExp _sentenceEnd = RegExp(r'[.!?…]$');
  static final RegExp _vowel = RegExp('[aeiouy]');
  static final RegExp _tripled = RegExp(r'(.)\1\1');

  /// Mots d'un texte (lettres et apostrophes) de 2 lettres ou plus, avec leur place.
  static List<RegExpMatch> _wordMatches(String text) => [
        for (final m in _word.allMatches(text))
          if (m[0]!.replaceAll(_apostrophe, '').length >= 2) m,
      ];

  static List<String> _words(String text) => [for (final m in _wordMatches(text)) m[0]!];

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

  /// Le mot en [index] commence-t-il une phrase (début du texte, ou après
  /// . ! ? … : en sautant espaces, tirets de dialogue, guillemets) ?
  static bool _atSentenceStart(String text, int index) {
    for (var i = index - 1; i >= 0; i--) {
      final c = text[i];
      if (' \t\n-–—«»"“”„¿¡(¦'.contains(c)) continue;
      return '.!?…:'.contains(c);
    }
    return true;
  }

  /// Écrit comme un nom : majuscule, pas tout en majuscules, pas en début de phrase.
  static bool _nameLike(String text, RegExpMatch m, String core) {
    final first = core.substring(0, 1);
    if (first == first.toLowerCase() || core == core.toUpperCase()) return false;
    return !_atSentenceStart(text, m.start);
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

  static List<Set<String>> _tokenSets(List<OcrReading> readings) => [
        for (final r in readings)
          {for (final t in ReadingVote.tokens(r.text)) normalizeForCompare(_core(t))},
      ];

  List<String> _learnWords(_Lang l, String lang, String text, List<OcrReading> readings,
      WordList dict, int day, DateTime time) {
    final matches = _wordMatches(text);
    if (matches.isEmpty) return const [];
    final known = matches.where((m) => ReadingVote.isKnownWord(m[0]!, dict)).length;
    // Un sous-titre surtout fait de mots inconnus : image floue, autre langue, décor.
    if (matches.length > 2 && known < matches.length * 0.5) return const [];
    final tokens = _tokenSets(readings);
    final learned = <String>[];
    final seen = <String>{};
    for (final m in matches) {
      final core = _core(m[0]!);
      final lower = core.toLowerCase();
      if (!seen.add(lower)) continue;
      final norm = normalizeForCompare(core);
      final weight = _agreement(norm, readings, tokens);

      final info = l.words[lower];
      if (info != null) {
        _review(l, lang, lower, info, weight, readings, tokens, dict, day);
        continue;
      }
      if (ReadingVote.isKnownWord(core, dict) || !_learnable(core)) continue;
      if (l.blocked.contains(lower)) continue; // oublié : plus jamais appris

      // Le « mauvais » mot d'une erreur apprise, lu cette fois sans hésiter :
      // c'était peut-être un vrai mot, l'erreur perd une voix.
      final fix = l.fixes[lower];
      if (fix != null) {
        if (weight < 0.75) continue;
        if (fix.$2 <= 1) {
          l.fixes.remove(lower);
        } else {
          l.fixes[lower] = (fix.$1, fix.$2 - 1);
          if (fix.$2 - 1 >= fixCount) continue; // toujours une erreur connue
        }
      }

      // Mot que la correction ramène à un mot courant : sans doute mal lu.
      final fixed = SpellFixer.fix(lower, dict);
      final near = fixed != lower;
      if (near && fixed.split(' ').every((p) => (dict.rank[p] ?? WordList.learnedRank) < 5000)) {
        continue;
      }
      if (weight <= 0) continue;

      final prev = l.candidates.remove(lower);
      final c = _Candidate(
        score: (prev?.score ?? 0) + weight,
        day: day,
        names: (prev?.names ?? 0) + (_nameLike(text, m, core) ? 1 : 0),
        near: near || (prev?.near ?? false),
      );
      final needed = c.near ? learnScoreNear : (c.names > 0 ? learnScoreName : learnScore);
      if (c.score >= needed && _mayLearnNow(l, time)) {
        l.words[lower] = _Word(uses: 0, day: day);
        l.fixes.remove(lower);
        l.newTimes.add(time);
        if (l.words.length > maxWords) _unlearn(l, lang, l.words.keys.first, block: false);
        dict.addLearned(lower, rank: WordList.provisionalRank);
        _lists[lang]?.addLearned(lower, rank: WordList.provisionalRank);
        learned.add(lower);
      } else {
        l.candidates[lower] = c;
        if (l.candidates.length > maxCandidates) l.candidates.remove(l.candidates.keys.first);
      }
    }
    return learned;
  }

  /// Pas plus de [maxNewPerWindow] nouveaux mots en [newWindow].
  static bool _mayLearnNow(_Lang l, DateTime time) {
    l.newTimes.removeWhere((t) => time.difference(t) > newWindow);
    return l.newTimes.length < maxNewPerWindow;
  }

  /// Mot appris revu : confirmé si toutes les lectures l'ont ; contredit si une
  /// lecture donne à sa place un mot du dictionnaire qui lui ressemble.
  void _review(_Lang l, String lang, String lower, _Word info, double weight,
      List<OcrReading> readings, List<Set<String>> tokens, WordList dict, int day) {
    final norm = normalizeForCompare(lower);
    var contra = 0;
    for (var i = 0; i < readings.length; i++) {
      if (tokens[i].contains(norm)) continue;
      if (_similarBaseWord(norm, tokens[i], dict)) contra = 1;
    }
    final updated = _Word(
      uses: info.uses + (weight >= 0.75 && contra == 0 ? 1 : 0),
      day: day,
      contra: info.contra + contra,
    );
    l.words.remove(lower);
    l.words[lower] = updated; // en fin de liste : oublié en dernier
    if (_contradicted(updated)) {
      _unlearn(l, lang, lower, block: true);
    } else if (info.uses < confirmUses && updated.uses >= confirmUses) {
      dict.addLearned(lower, rank: WordList.learnedRank); // confirmé
      _lists[lang]?.addLearned(lower, rank: WordList.learnedRank);
    }
  }

  static bool _contradicted(_Word w) => w.contra >= unlearnContra && w.contra * 2 > w.uses;

  /// Une des formes simplifiées de [tokens] est un mot du dictionnaire (pas
  /// un mot appris) qui ressemble à [norm].
  static bool _similarBaseWord(String norm, Set<String> tokens, WordList dict) {
    for (final t in tokens) {
      if (t.isEmpty || t == norm || (t.length - norm.length).abs() > 2) continue;
      final w = dict.byNorm[t] ?? t;
      if (!dict.contains(w) || dict.learned.contains(w)) continue;
      if (similarity(norm, t) >= 0.7) return true;
    }
    return false;
  }

  void _unlearn(_Lang l, String lang, String word, {required bool block}) {
    l.words.remove(word);
    l.candidates.remove(word);
    _lists[lang]?.removeLearned(word);
    if (block) _block(l, word);
  }

  static void _block(_Lang l, String word) {
    l.blocked.remove(word);
    l.blocked.add(word);
    if (l.blocked.length > maxBlocked) l.blocked.remove(l.blocked.first);
  }

  /// Poids d'un sous-titre pour un mot, en comptant les **images** :
  /// - lectures en désaccord : 0 (0,5 si 2/3 des lectures, 3 lectures ou plus) ;
  /// - toutes d'accord sur 2 images ou plus : 1 ;
  /// - une seule image : 1 si ML Kit est sûr (≥ 0,9), 0,75 si la lecture
  ///   renforcée dit pareil, 0,5 si ML Kit est assez sûr (≥ 0,8) ou ne dit rien
  ///   (iPhone, écran du téléphone), sinon 0.
  static double _agreement(String norm, List<OcrReading> readings, List<Set<String>> tokens) {
    if (readings.isEmpty) return 0.5;
    final have = tokens.where((t) => t.contains(norm)).length;
    if (have < readings.length) {
      return readings.length >= 3 && have >= readings.length * 2 / 3 ? 0.5 : 0;
    }
    final frames = <int>{};
    var unknownFrames = 0;
    for (final r in readings) {
      r.frame < 0 ? unknownFrames++ : frames.add(r.frame);
    }
    if (frames.length + unknownFrames >= 2) return 1;
    double? conf;
    for (final r in readings) {
      final c = r.confidence[norm];
      if (c != null && (conf == null || c > conf)) conf = c;
    }
    if (conf != null && conf >= 0.9) return 1;
    if (readings.length >= 2) return 0.75;
    if (conf == null || conf >= 0.8) return 0.5;
    return 0;
  }

  /// Mots inconnus d'une lecture que le vote a remplacés par un mot connu qui
  /// leur ressemble : erreurs de lecture. Un mot appris ainsi remplacé est contredit.
  void _learnFixes(_Lang l, String lang, String text, List<OcrReading> readings, WordList dict) {
    if (readings.length < 2) return;
    final finalWords = {for (final w in _words(text)) _core(w).toLowerCase()};
    final chosen = <String>{
      for (final w in finalWords)
        if (ReadingVote.isKnownWord(w, dict) && !dict.learned.contains(w)) w,
    };
    if (chosen.isEmpty) return;
    final done = <String>{};
    for (final r in readings) {
      for (final w in _words(r.text)) {
        final wrong = _core(w).toLowerCase();
        if (wrong.runes.length < 3 || finalWords.contains(wrong) || done.contains(wrong)) continue;
        final right = _closest(wrong, chosen);
        final learnedWord = l.words[wrong];
        if (learnedWord != null) {
          // Mot appris, écarté par le vote au profit d'un mot du dictionnaire.
          if (right == null) continue;
          done.add(wrong);
          final updated = _Word(uses: learnedWord.uses, day: learnedWord.day, contra: learnedWord.contra + 1);
          l.words[wrong] = updated;
          if (_contradicted(updated)) _unlearn(l, lang, wrong, block: true);
          continue;
        }
        if (ReadingVote.isKnownWord(wrong, dict) || right == null) continue;
        done.add(wrong);
        final prev = l.fixes.remove(wrong);
        l.fixes[wrong] = (right, prev != null && prev.$1 == right ? prev.$2 + 1 : 1);
        if (l.fixes.length > maxFixes) l.fixes.remove(l.fixes.keys.first);
        l.candidates.remove(wrong); // ce n'était pas un vrai mot
      }
    }
  }

  /// Mot de [chosen] le plus ressemblant à [wrong] (similarité ≥ 0,7, 2 lettres
  /// d'écart au plus, pas seulement les accents), ou null.
  static String? _closest(String wrong, Set<String> chosen) {
    final wn = normalizeForCompare(wrong);
    String? right;
    var best = 0.0;
    for (final c in chosen) {
      if ((c.length - wrong.length).abs() > 2) continue;
      final cn = normalizeForCompare(c);
      if (cn == wn) continue;
      final sim = similarity(wn, cn);
      if (sim >= 0.7 && sim > best) {
        best = sim;
        right = c;
      }
    }
    return right;
  }

  /// Suites de deux mots d'un sous-titre net, lu sans désaccord (sans
  /// traverser une fin de phrase).
  void _learnPairs(_Lang l, String text, WordList dict, List<OcrReading> readings) {
    if (!ReadingVote.looksClean(text, dict)) return;
    if (readings.length >= 2) {
      final n = normalizeForCompare(text);
      if (readings.any((r) => normalizeForCompare(r.text) != n)) return;
    }
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

  /// Remplace les erreurs de lecture apprises par le bon mot, en gardant les
  /// majuscules. Un mot du dictionnaire n'est jamais touché ; un mot écrit
  /// comme un nom seulement après [fixCountName] fois.
  String applyFixes(String lang, String text, {WordList? dict}) {
    final l = _langs[lang];
    if (!_enabled || l == null || l.fixes.isEmpty) return text;
    return text.replaceAllMapped(_letterRun, (m) {
      final word = m[0]!;
      final lower = word.toLowerCase();
      final fix = l.fixes[lower];
      if (fix == null || fix.$2 < fixCount) return word;
      if (dict != null && dict.contains(lower)) return word;
      final allCaps = word.length > 1 && word == word.toUpperCase();
      final capital = word[0] != word[0].toLowerCase();
      if (capital && !allCaps && fix.$2 < fixCountName && !_atSentenceStart(text, m.start)) {
        return word; // sans doute un nom propre
      }
      final right = fix.$1;
      if (allCaps) return right.toUpperCase();
      if (capital) return right[0].toUpperCase() + right.substring(1);
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
      ..sort((a, b) => b.value.uses.compareTo(a.value.uses));
    return [for (final x in e) x.key];
  }

  /// Mot appris et confirmé (la correction y ramène les lectures abîmées).
  bool isConfirmed(String lang, String word) =>
      (_langs[lang]?.words[word.toLowerCase()]?.uses ?? 0) >= confirmUses;

  /// Mot qui ne sera plus appris (oublié à la main ou contredit).
  bool isBlocked(String lang, String word) =>
      _langs[lang]?.blocked.contains(word.toLowerCase()) ?? false;

  /// Langues qui ont des mots appris.
  List<String> get languages => [
        for (final e in _langs.entries)
          if (e.value.words.isNotEmpty) e.key,
      ];

  int wordCount([String? lang]) => lang != null
      ? _langs[lang]?.words.length ?? 0
      : _langs.values.fold(0, (n, l) => n + l.words.length);

  /// Mots appris pas encore confirmés.
  int provisionalCount([String? lang]) {
    int count(_Lang l) => l.words.values.where((w) => w.uses < confirmUses).length;
    return lang != null
        ? (_langs[lang] == null ? 0 : count(_langs[lang]!))
        : _langs.values.fold(0, (n, l) => n + count(l));
  }

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

  /// Oublie un mot appris : il redevient inconnu et ne sera plus appris.
  void forget(String lang, String word) {
    final l = _langs[lang];
    if (l == null) return;
    _unlearn(l, lang, word.toLowerCase(), block: true);
  }

  /// Oublie tout ce qui a été appris (et les mots bloqués).
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

  static int _day(DateTime now) => now.toUtc().difference(DateTime.utc(2026)).inDays;

  String toJson() => jsonEncode({
        'v': 2,
        'langs': {for (final e in _langs.entries) e.key: e.value.toJson()},
      });

  /// Relit ce qui a été appris (versions 1 et 2). Une langue illisible est
  /// ignorée sans effacer les autres ; un texte illisible donne un apprentissage vide.
  static WordLearner fromJson(String? json) {
    final learner = WordLearner();
    if (json == null || json.isEmpty) return learner;
    Map<String, dynamic> langs;
    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      langs = data['langs'] as Map<String, dynamic>? ?? const {};
    } catch (_) {
      return learner;
    }
    langs.forEach((lang, v) {
      try {
        learner._langs[lang] = _Lang.fromJson(v as Map<String, dynamic>);
      } catch (_) {
        // langue abîmée : on repart de zéro pour elle seulement
      }
    });
    return learner;
  }
}

class _Word {
  const _Word({required this.uses, required this.day, this.contra = 0});

  /// Confirmations depuis qu'il est appris.
  final int uses;
  final int day;

  /// Contradictions : une autre lecture donnait un mot du dictionnaire à sa place.
  final int contra;
}

class _Candidate {
  const _Candidate({required this.score, required this.day, this.names = 0, this.near = false});

  /// Preuves réunies (voir `WordLearner._agreement`).
  final double score;
  final int day;

  /// Fois où il était écrit comme un nom (majuscule au milieu d'une phrase).
  final int names;

  /// Ressemble à un mot du dictionnaire (la correction le changerait).
  final bool near;
}

/// Ce qui est appris pour une langue. Dans chaque table, l'ordre est celui de
/// la dernière utilisation : les plus anciens, en tête, sont oubliés d'abord.
class _Lang {
  _Lang();

  final Map<String, _Word> words = {};
  final Map<String, _Candidate> candidates = {};

  /// Mot mal lu -> (bon mot, nombre de sous-titres).
  final Map<String, (String, int)> fixes = {};

  /// « mot|mot suivant » (formes simplifiées) -> nombre de fois.
  final Map<String, int> pairs = {};

  /// Mots qui ne seront plus appris (oubliés à la main ou contredits).
  final Set<String> blocked = {};

  /// Heures des derniers mots appris (pas mémorisé).
  final List<DateTime> newTimes = [];

  int observed = 0;

  void prune(int day) {
    candidates.removeWhere((_, c) => day - c.day > WordLearner.candidateDays);
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
        'words': {for (final e in words.entries) e.key: [e.value.uses, e.value.day, e.value.contra]},
        'cands': {
          for (final e in candidates.entries)
            e.key: [e.value.score, e.value.day, e.value.names, e.value.near ? 1 : 0],
        },
        'fixes': {for (final e in fixes.entries) e.key: [e.value.$1, e.value.$2]},
        'pairs': pairs,
        'blocked': blocked.toList(),
      };

  static int _int(List a, int i) => i < a.length ? (a[i] as num).toInt() : 0;

  static _Lang fromJson(Map<String, dynamic> j) {
    final l = _Lang();
    (j['words'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      final a = v as List;
      // Version 1 : [revu, jour] ; les mots déjà appris comptent comme confirmés.
      l.words[k] = a.length >= 3
          ? _Word(uses: _int(a, 0), day: _int(a, 1), contra: _int(a, 2))
          : _Word(uses: WordLearner.confirmUses, day: _int(a, 1));
    });
    (j['cands'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      final a = v as List;
      l.candidates[k] = _Candidate(
        score: (a[0] as num).toDouble(),
        day: _int(a, 1),
        names: _int(a, 2),
        near: _int(a, 3) == 1,
      );
    });
    (j['fixes'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      final a = v as List;
      l.fixes[k] = (a[0] as String, (a[1] as num).toInt());
    });
    (j['pairs'] as Map<String, dynamic>? ?? const {}).forEach((k, v) {
      l.pairs[k] = (v as num).toInt();
    });
    for (final w in j['blocked'] as List? ?? const []) {
      l.blocked.add(w as String);
    }
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
