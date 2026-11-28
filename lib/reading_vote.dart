import 'languages.dart' show isCjkRune;
import 'spell_fixer.dart' show WordList;
import 'text_tools.dart';

/// Séparateur de répliques dans le texte suivi d'une image à l'autre.
/// Les comparaisons ne gardent que lettres et chiffres : il n'y change rien.
/// En tête du texte, il signale un sous-titre qui commence par un tiret.
const String kPartSep = '¦';

/// Réunit les répliques d'un sous-titre en un seul texte, avec [kPartSep].
String joinParts(List<String> parts, {bool dialogueStart = false}) =>
    '${dialogueStart ? '$kPartSep ' : ''}${parts.join(' $kPartSep ')}';

/// Sépare les répliques réunies par [joinParts].
List<String> splitParts(String text) => [
      for (final p in text.split(kPartSep))
        if (p.trim().isNotEmpty) p.replaceAll(RegExp(r'\s+'), ' ').trim(),
    ];

/// Le texte réuni par [joinParts] commence-t-il par un tiret de réplique ?
bool startsWithDialogue(String text) => text.trimLeft().startsWith(kPartSep);

/// Une lecture de l'OCR : le texte nettoyé, et la confiance que ML Kit donne
/// à chaque mot (Android seulement ; vide sinon).
class OcrReading {
  const OcrReading(this.text, {this.confidence = const {}, this.frame = -1});
  final String text;

  /// Mot (version simplifiée, voir [normalizeForCompare]) -> confiance de 0 à 1.
  final Map<String, double> confidence;

  /// Numéro de l'image lue (-1 : inconnu). La lecture normale et la lecture
  /// renforcée d'une même image ont le même numéro : pour apprendre un mot,
  /// elles ne comptent pas comme deux images (voir `WordLearner`).
  final int frame;

  OcrReading withFrame(int f) => OcrReading(text, confidence: confidence, frame: f);
}

/// Suites de mots habituelles d'une langue, apprises sur les sous-titres lus
/// (voir `WordLearner`) : départagent deux lectures qui sont toutes deux de
/// vrais mots (« je ne sais pas » / « je ne sait pas »).
abstract class WordContext {
  /// De 0 à 1 : à quel point [word] suit habituellement [previous]
  /// (formes simplifiées, voir [normalizeForCompare]).
  double follows(String previous, String word);
}

/// Combine plusieurs lectures d'un même sous-titre (images successives,
/// lecture normale et lecture renforcée) en un seul texte, mot à mot.
///
/// Pour chaque mot, on garde la variante qui a le plus de voix, en donnant un
/// bonus aux vrais mots de la langue (dictionnaire) et à ceux que ML Kit lit
/// avec assurance. « raisori » / « raison » : « raison » gagne, même à 1 contre 1.
class ReadingVote {
  ReadingVote._();

  /// Coût d'un mot en trop ou manquant dans l'alignement (une substitution coûte de 0 à 1).
  static const double _gap = 0.7;

  /// Bonus d'un mot du dictionnaire, et poids de la confiance de ML Kit.
  static const double dictBonus = 0.75;
  static const double confidenceWeight = 0.5;

  /// Poids d'une lecture où le mot est absent (un mot vu dans une seule
  /// lecture n'est retiré que si les autres sont nettement d'accord).
  static const double _gapVote = 0.8;

  /// Poids des suites de mots apprises ([WordContext]), avec le mot d'avant
  /// et avec le mot d'après : 0,6 au plus en tout, moins qu'une lecture de
  /// plus et moins que le dictionnaire.
  static const double contextWeight = 0.3;

  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _letters = RegExp(r'\p{L}+', unicode: true);

  static String combine(List<OcrReading> readings, {WordList? dict, WordContext? context}) {
    final rs = [
      for (final r in readings)
        if (r.text.trim().isNotEmpty) r,
    ];
    if (rs.isEmpty) return '';
    if (rs.length == 1) return rs.first.text.trim();

    // Ponctuation seule (« Quoi ? » en français) rattachée à son mot : elle est
    // votée avec lui ([_punctuation]) au lieu d'être alignée comme un mot.
    final toks = [for (final r in rs) _attachPunctuation(tokens(r.text))];
    final norms = [
      for (final t in toks) [for (final w in t) _norm(w)],
    ];

    // Lecture de référence : la plus proche de toutes les autres (et, à égalité, la plus complète).
    final joined = [for (final n in norms) n.join(' ')];
    var pivot = 0;
    var best = double.negativeInfinity;
    for (var i = 0; i < rs.length; i++) {
      var score = 0.01 * toks[i].length;
      for (var j = 0; j < rs.length; j++) {
        if (i != j) score += similarity(joined[i], joined[j]);
      }
      if (score > best) {
        best = score;
        pivot = i;
      }
    }

    final pTok = toks[pivot];
    final pNorm = norms[pivot];
    // Variantes proposées pour chaque mot de la référence : (mot, n° de lecture).
    final cands = List.generate(pTok.length, (k) => <(String, int)>[(pTok[k], pivot)]);
    final gaps = List<int>.filled(pTok.length, 0);
    // Mots d'une autre lecture absents de la référence, rangés par place :
    // inserts[k + 1] = mots lus entre le mot k et le mot k + 1 de la référence
    // (inserts[0] : avant le premier). Une lecture par entrée : (mots, n° de lecture).
    final inserts = List.generate(pTok.length + 1, (_) => <(List<String>, int)>[]);
    for (var i = 0; i < rs.length; i++) {
      if (i == pivot) continue;
      final match = _align(pNorm, norms[i]);
      final slotOf = List<int>.filled(toks[i].length, -1);
      final matched = List<bool>.filled(toks[i].length, false);
      for (var k = 0; k < pTok.length; k++) {
        final j = match[k];
        if (j == null) {
          gaps[k]++;
        } else {
          cands[k].add((toks[i][j], i));
          matched[j] = true;
        }
      }
      // Place de chaque mot non apparié : après le dernier mot de la référence apparié avant lui.
      var lastK = -1;
      var next = 0;
      for (var j = 0; j < toks[i].length; j++) {
        while (next < pTok.length && (match[next] == null || match[next]! < j)) {
          if (match[next] != null) lastK = next;
          next++;
        }
        slotOf[j] = lastK + 1;
      }
      final bySlot = <int, List<String>>{};
      for (var j = 0; j < toks[i].length; j++) {
        if (!matched[j]) bySlot.putIfAbsent(slotOf[j], () => []).add(toks[i][j]);
      }
      bySlot.forEach((slot, words) => inserts[slot].add((words, i)));
    }

    final out = <String>[];
    void addInserted(int slot) {
      final words = _inserted(inserts[slot], rs, dict);
      if (words != null) out.addAll(words);
    }

    addInserted(0);
    for (var k = 0; k < pTok.length; k++) {
      // Variantes regroupées par forme simplifiée (« raison. » et « raison » votent ensemble).
      final groups = <String, List<(String, int)>>{};
      for (final c in cands[k]) {
        groups.putIfAbsent(_norm(c.$1), () => []).add(c);
      }
      String? bestWord;
      var bestScore = double.negativeInfinity;
      final pivotCore = _splitPunct(pTok[k]).core;
      groups.forEach((norm, members) {
        final spelling = _spelling(
            [for (final m in members) (_splitPunct(m.$1).core, m.$2)], dict, pivotCore);
        var score = members.length.toDouble();
        if (isKnownWord(spelling, dict)) score += dictBonus;
        final confs = [
          for (final m in members)
            if (rs[m.$2].confidence[norm] != null) rs[m.$2].confidence[norm]!,
        ];
        if (confs.isNotEmpty) {
          score += confidenceWeight * confs.reduce((a, b) => a + b) / confs.length;
        }
        if (context != null) {
          if (out.isNotEmpty) score += contextWeight * context.follows(_norm(out.last), norm);
          if (k + 1 < pNorm.length) score += contextWeight * context.follows(norm, pNorm[k + 1]);
        }
        if (norm == pNorm[k]) score += 0.01; // à égalité : la lecture de référence
        if (score > bestScore) {
          bestScore = score;
          bestWord = spelling;
        }
      });
      // Mot présent dans une seule lecture, absent des autres : sans doute du bruit.
      if (gaps[k] * _gapVote <= bestScore) out.add(_punctuation(bestWord!, cands[k], pivot));
      addInserted(k + 1);
    }
    return joinTokens(out);
  }

  /// Signes qui entourent un mot (pas l'apostrophe, ni [kPartSep], ni la
  /// ponctuation chinoise ou japonaise, qui reste un mot à part).
  static final RegExp _punctOnly = RegExp(r'^[.,;:!?…¿¡«»"“”„()\[\]\-–—]+$');
  static final RegExp _leadPunct = RegExp(r'^[¿¡«"“„(\[\-–—]+\s*');
  static final RegExp _trailPunct = RegExp(r'\s*[.,;:!?…»"”)\]\-–—]+$');
  static const String _openingMarks = '¿¡«“„([';

  /// « Quoi », « ? » → « Quoi ? » ; « « », « Bonjour » → « « Bonjour ».
  static List<String> _attachPunctuation(List<String> toks) {
    final out = <String>[];
    var lead = '';
    for (final t in toks) {
      if (t != kPartSep && _punctOnly.hasMatch(t)) {
        final opening = _openingMarks.contains(t[0]);
        if (!opening && out.isNotEmpty && out.last != kPartSep && lead.isEmpty) {
          out[out.length - 1] = '${out.last} $t';
        } else {
          lead = lead.isEmpty ? t : '$lead $t';
        }
        continue;
      }
      if (lead.isNotEmpty && t != kPartSep) {
        out.add('$lead $t');
      } else {
        if (lead.isNotEmpty) out.add(lead);
        out.add(t);
      }
      lead = '';
    }
    if (lead.isNotEmpty) out.add(lead);
    return out;
  }

  static ({String lead, String core, String trail}) _splitPunct(String token) {
    final l = _leadPunct.firstMatch(token);
    var rest = l == null ? token : token.substring(l.end);
    final tr = _trailPunct.firstMatch(rest);
    if (tr != null) rest = rest.substring(0, tr.start);
    if (rest.isEmpty) return (lead: '', core: token, trail: '');
    return (lead: l?[0] ?? '', core: rest, trail: tr?[0] ?? '');
  }

  /// Ponctuation d'un mot, votée à part (demande du 28/11/2026 : « intégrer au
  /// mieux la ponctuation ») : la reconnaissance de texte perd souvent ces
  /// petits signes, mais n'en invente presque jamais. Un signe vu dans au moins
  /// un tiers des lectures de ce mot est gardé (« Tu viens ? » lu une fois sur
  /// trois avec son « ? » : la question reste une question) ; entre deux signes,
  /// le plus vu, puis celui de la lecture de référence.
  static String _punctuation(String core, List<(String, int)> cands, int pivot) {
    final parts = [for (final c in cands) (p: _splitPunct(c.$1), i: c.$2)];
    String pick(String Function(({String lead, String core, String trail}) p) side) {
      final seen = [
        for (final c in parts)
          if (side(c.p).trim().isNotEmpty) (raw: side(c.p), i: c.i),
      ];
      if (seen.isEmpty || seen.length * 3 < parts.length) return '';
      String key(String raw) => raw.replaceAll(' ', '').replaceAll('...', '…');
      final groups = <String, List<({String raw, int i})>>{};
      for (final s in seen) {
        groups.putIfAbsent(key(s.raw), () => []).add(s);
      }
      List<({String raw, int i})>? best;
      var bestScore = -1.0;
      groups.forEach((_, members) {
        final score = members.length + (members.any((m) => m.i == pivot) ? 0.5 : 0.0);
        if (score > bestScore) {
          bestScore = score;
          best = members;
        }
      });
      // Écriture (espace française comprise) : la plus vue dans le groupe.
      final counts = <String, int>{};
      for (final m in best!) {
        counts[m.raw] = (counts[m.raw] ?? 0) + 1;
      }
      return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    }

    return '${pick((p) => p.lead)}$core${pick((p) => p.trail)}';
  }

  /// Mots absents de la lecture de référence mais lus par d'autres lectures au
  /// même endroit ([proposals] : (mots, n° de lecture)). Ils sont ajoutés avec
  /// la même règle que celle qui retire un mot : voix des lectures qui les
  /// ont (+ dictionnaire, + confiance) contre 0,8 par lecture qui ne les a pas.
  /// Ainsi, une référence qui a perdu un mot ne le fait pas perdre au texte.
  static List<String>? _inserted(
      List<(List<String>, int)> proposals, List<OcrReading> rs, WordList? dict) {
    if (proposals.isEmpty) return null;
    final groups = <String, List<(List<String>, int)>>{};
    for (final p in proposals) {
      groups.putIfAbsent(p.$1.map(_norm).join(' '), () => []).add(p);
    }
    String? bestNorm;
    var bestCount = 0;
    groups.forEach((norm, members) {
      if (members.length > bestCount) {
        bestCount = members.length;
        bestNorm = norm;
      }
    });
    // Lectures qui ont à peu près les mêmes mots à cet endroit.
    final support = [
      for (final e in groups.entries)
        if (similarity(e.key, bestNorm!) >= 0.75) ...e.value,
    ];
    final best = groups[bestNorm]!;
    // Orthographe : la suite de mots la plus vue dans le groupe.
    final spellings = <String, (List<String>, int)>{};
    for (final m in best) {
      final key = m.$1.join(' ');
      final prev = spellings[key];
      spellings[key] = (m.$1, (prev?.$2 ?? 0) + 1);
    }
    final words = spellings.values.reduce((a, b) => b.$2 > a.$2 ? b : a).$1;

    var score = support.length.toDouble();
    if (words.every((w) => isKnownWord(w, dict))) score += dictBonus;
    final confs = <double>[
      for (final m in support)
        for (final w in m.$1)
          if (rs[m.$2].confidence[_norm(w)] != null) rs[m.$2].confidence[_norm(w)]!,
    ];
    if (confs.isNotEmpty) {
      score += confidenceWeight * confs.reduce((a, b) => a + b) / confs.length;
    }
    final absent = rs.length - support.length;
    return absent * _gapVote > score ? null : words;
  }

  /// Réunit des mots : avec des espaces, sauf autour d'un caractère chinois
  /// ou japonais (ces écritures n'en mettent pas entre les mots).
  static String joinTokens(List<String> tokens) {
    final sb = StringBuffer();
    for (var i = 0; i < tokens.length; i++) {
      if (i > 0 &&
          !isCjkRune(tokens[i - 1].runes.last) &&
          !isCjkRune(tokens[i].runes.first)) {
        sb.write(' ');
      }
      sb.write(tokens[i]);
    }
    return sb.toString().trim();
  }

  /// Le mot existe-t-il dans la langue ? (« l'école » : « école » suffit.)
  static final RegExp _cleanWord = RegExp(r"[\p{L}'’]+", unicode: true);

  /// Lecture « nette » : au moins un mot, au moins 90 % des mots (2 lettres
  /// ou plus) dans le dictionnaire [dict], et confiance moyenne de ML Kit
  /// ≥ 0,7 quand elle est connue. Une telle lecture est dite dès la 1re image,
  /// sans attendre d'autres lectures (demande « temps réel » du 27/11/2026).
  static bool looksClean(String text, WordList? dict,
      {Iterable<double> confidences = const []}) {
    if (dict == null) return false;
    final words = [
      for (final m in _cleanWord.allMatches(text))
        if (m[0]!.replaceAll(RegExp(r"['’]"), '').length >= 2) m[0]!,
    ];
    if (words.isEmpty) return false;
    final known = words.where((w) => isKnownWord(w, dict)).length;
    if (known < words.length * 0.9) return false;
    final c = confidences.toList();
    if (c.isNotEmpty && c.reduce((a, b) => a + b) / c.length < 0.7) return false;
    return true;
  }

  static bool isKnownWord(String word, WordList? dict) {
    if (dict == null) return false;
    final parts = [for (final m in _letters.allMatches(word.toLowerCase())) m.group(0)!];
    if (parts.isEmpty) return false;
    final long = parts.where((p) => p.length >= 2).toList();
    if (long.isEmpty) return dict.contains(parts.join());
    return long.every(dict.contains);
  }

  /// Orthographe à garder dans un groupe : la plus fréquente, puis celle du
  /// dictionnaire (accents), puis celle de la lecture de référence.
  static String _spelling(List<(String, int)> members, WordList? dict, String pivotWord) {
    final counts = <String, int>{};
    for (final m in members) {
      counts[m.$1] = (counts[m.$1] ?? 0) + 1;
    }
    String? best;
    var bestKey = double.negativeInfinity;
    counts.forEach((w, n) {
      final key = n.toDouble() + (isKnownWord(w, dict) ? 0.5 : 0.0) + (w == pivotWord ? 0.1 : 0.0);
      if (key > bestKey) {
        bestKey = key;
        best = w;
      }
    });
    return best!;
  }

  /// Mots d'une lecture : séparés par les espaces ; en chinois et en japonais,
  /// chaque caractère compte comme un mot (pas d'espaces entre les mots).
  static List<String> tokens(String text) {
    final out = <String>[];
    final word = StringBuffer();
    void flush() {
      if (word.isNotEmpty) out.add(word.toString());
      word.clear();
    }

    for (final r in text.trim().runes) {
      final ch = String.fromCharCode(r);
      if (isCjkRune(r)) {
        flush();
        out.add(ch);
      } else if (_spaces.hasMatch(ch)) {
        flush();
      } else {
        word.write(ch);
      }
    }
    flush();
    return out;
  }

  static String _norm(String token) {
    final n = normalizeForCompare(token);
    return n.isEmpty ? token : n;
  }

  /// Alignement mot à mot (distance d'édition) : pour chaque mot de [a],
  /// la position du mot correspondant dans [b], ou null s'il y manque.
  static List<int?> _align(List<String> a, List<String> b) {
    final n = a.length, m = b.length;
    double sub(int i, int j) => a[i] == b[j] ? 0 : 1 - similarity(a[i], b[j]);
    final cost = List.generate(n + 1, (_) => List<double>.filled(m + 1, 0));
    for (var i = 1; i <= n; i++) {
      cost[i][0] = i * _gap;
    }
    for (var j = 1; j <= m; j++) {
      cost[0][j] = j * _gap;
    }
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final diag = cost[i - 1][j - 1] + sub(i - 1, j - 1);
        final up = cost[i - 1][j] + _gap;
        final left = cost[i][j - 1] + _gap;
        cost[i][j] = diag < up ? (diag < left ? diag : left) : (up < left ? up : left);
      }
    }
    final match = List<int?>.filled(n, null);
    var i = n, j = m;
    while (i > 0 && j > 0) {
      if ((cost[i][j] - (cost[i - 1][j - 1] + sub(i - 1, j - 1))).abs() < 1e-9) {
        match[i - 1] = j - 1;
        i--;
        j--;
      } else if ((cost[i][j] - (cost[i - 1][j] + _gap)).abs() < 1e-9) {
        i--;
      } else {
        j--;
      }
    }
    return match;
  }
}
