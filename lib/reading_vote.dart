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
  const OcrReading(this.text, {this.confidence = const {}});
  final String text;

  /// Mot (version simplifiée, voir [normalizeForCompare]) -> confiance de 0 à 1.
  final Map<String, double> confidence;
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

  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _letters = RegExp(r'\p{L}+', unicode: true);

  static String combine(List<OcrReading> readings, {WordList? dict}) {
    final rs = [
      for (final r in readings)
        if (r.text.trim().isNotEmpty) r,
    ];
    if (rs.isEmpty) return '';
    if (rs.length == 1) return rs.first.text.trim();

    final toks = [for (final r in rs) _tokens(r.text)];
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
    for (var i = 0; i < rs.length; i++) {
      if (i == pivot) continue;
      final match = _align(pNorm, norms[i]);
      for (var k = 0; k < pTok.length; k++) {
        final j = match[k];
        if (j == null) {
          gaps[k]++;
        } else {
          cands[k].add((toks[i][j], i));
        }
      }
    }

    final out = <String>[];
    for (var k = 0; k < pTok.length; k++) {
      // Variantes regroupées par forme simplifiée (« raison. » et « raison » votent ensemble).
      final groups = <String, List<(String, int)>>{};
      for (final c in cands[k]) {
        groups.putIfAbsent(_norm(c.$1), () => []).add(c);
      }
      String? bestWord;
      var bestScore = double.negativeInfinity;
      groups.forEach((norm, members) {
        final spelling = _spelling(members, dict, pTok[k]);
        var score = members.length.toDouble();
        if (isKnownWord(spelling, dict)) score += dictBonus;
        final confs = [
          for (final m in members)
            if (rs[m.$2].confidence[norm] != null) rs[m.$2].confidence[norm]!,
        ];
        if (confs.isNotEmpty) {
          score += confidenceWeight * confs.reduce((a, b) => a + b) / confs.length;
        }
        if (norm == pNorm[k]) score += 0.01; // à égalité : la lecture de référence
        if (score > bestScore) {
          bestScore = score;
          bestWord = spelling;
        }
      });
      // Mot présent dans une seule lecture, absent des autres : sans doute du bruit.
      if (gaps[k] * _gapVote > bestScore) continue;
      out.add(bestWord!);
    }
    return out.join(' ').trim();
  }

  /// Le mot existe-t-il dans la langue ? (« l'école » : « école » suffit.)
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
      final key = n + (isKnownWord(w, dict) ? 0.5 : 0) + (w == pivotWord ? 0.1 : 0);
      if (key > bestKey) {
        bestKey = key;
        best = w;
      }
    });
    return best!;
  }

  static List<String> _tokens(String text) => [
        for (final w in text.trim().split(_spaces))
          if (w.isNotEmpty) w,
      ];

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
