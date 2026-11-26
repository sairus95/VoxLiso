import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

import 'text_tools.dart';

/// Liste des mots fréquents d'une langue, du plus fréquent au moins fréquent
/// (mots des sous-titres de films, voir assets/dict/LICENCE.md).
class WordList {
  WordList.fromWords(Iterable<String> words) {
    var i = 0;
    for (final w in words) {
      final word = w.trim().toLowerCase();
      if (word.isEmpty || rank.containsKey(word)) continue;
      rank[word] = i;
      // Version sans accents -> mot le plus fréquent (« ecole » -> « école »).
      byNorm.putIfAbsent(_strip(word), () => word);
      i++;
    }
  }

  /// Mot -> rang (0 = le plus fréquent).
  final Map<String, int> rank = {};
  final Map<String, String> byNorm = {};

  bool contains(String lowerWord) => rank.containsKey(lowerWord);
}

String _strip(String w) => normalizeForCompare(w).replaceAll(' ', '');

/// Confusions typiques de la reconnaissance de texte (dans les deux sens
/// quand c'est utile) : « rn » lu à la place de « m », « 1 » pour « l »…
const List<List<String>> _confusions = [
  ['rn', 'm'], ['m', 'rn'], ['cl', 'd'], ['d', 'cl'], ['vv', 'w'], ['w', 'vv'],
  ['ri', 'n'], ['li', 'h'], ['ii', 'u'], ['nn', 'm'], ['in', 'm'],
  ['1', 'l'], ['1', 'i'], ['|', 'l'], ['|', 'i'], ['0', 'o'], ['5', 's'], ['8', 'b'],
  ['l', 'i'], ['i', 'l'], ['l', 't'], ['t', 'l'], ['c', 'e'], ['e', 'c'],
  ['u', 'v'], ['v', 'u'], ['n', 'h'], ['h', 'n'], ['n', 'u'], ['u', 'n'],
  ['o', 'a'], ['a', 'o'], ['f', 't'], ['t', 'f'], ['i', 'j'], ['j', 'i'],
];

final RegExp _token = RegExp(r'[\p{L}0-9|]+', unicode: true);
final RegExp _hasLetter = RegExp(r'\p{L}', unicode: true);
final RegExp _sentenceEnd = RegExp(r'[.!?…:]\s*$');
final RegExp _noise = RegExp(r'[0-9|]');

/// « s'il te plaît » mal lu : « SHte », « Sh vous », « Sil te », « S1l te »…
/// (l'apostrophe et « il » lus comme un « H », ou l'apostrophe perdue).
final RegExp _silFr = RegExp(
  r"(?<![\p{L}'’])([Ss])(?:[Hh]|['’]?[IilL1|]{2})\s*(?=(?:te|vous)\s+pla)",
  unicode: true,
);
const String _alphabet = 'abcdefghijklmnopqrstuvwxyz';

/// Corrige les mots mal lus par la reconnaissance de texte, avant de les dire
/// ou de les traduire. Ne touche jamais un mot du dictionnaire.
class SpellFixer {
  final Map<String, WordList?> _lists = {};
  final Map<String, Future<WordList?>> _loading = {};

  /// Langues ayant un dictionnaire.
  static const Set<String> languages = {
    'fr', 'de', 'es', 'it', 'en', 'pt', //
    'nl', 'pl', 'ro', 'sv', 'da', 'no', 'fi', 'cs', 'sk', 'hu', 'tr', 'ca', 'hr',
  };

  /// Dictionnaire déjà chargé (sinon null : appeler [load]).
  WordList? loaded(String lang) => _lists[lang];

  /// Charge (une fois) le dictionnaire d'une langue depuis les fichiers de l'application.
  Future<WordList?> load(String lang) {
    if (!languages.contains(lang)) return Future.value(null);
    if (_lists.containsKey(lang)) return Future.value(_lists[lang]);
    return _loading.putIfAbsent(lang, () async {
      try {
        final data = await rootBundle.load('assets/dict/$lang.txt.gz');
        final text = utf8.decode(gzip.decode(data.buffer.asUint8List()));
        final list = WordList.fromWords(const LineSplitter().convert(text));
        _lists[lang] = list;
        return list;
      } catch (_) {
        _lists[lang] = null;
        return null;
      }
    });
  }

  /// Corrige [text] avec le dictionnaire [list] ([lang] : expressions
  /// propres à une langue, ex. « s'il te plaît » en français).
  static String fix(String text, WordList list, {int maxRank = 30000, String lang = ''}) {
    if (lang == 'fr') text = text.replaceAllMapped(_silFr, (m) => "${m[1]}'il ");
    final out = StringBuffer();
    var last = 0;
    for (final m in _token.allMatches(text)) {
      out.write(text.substring(last, m.start));
      out.write(_fixWord(m.group(0)!, list, maxRank, atSentenceStart: _startsSentence(text, m.start)));
      last = m.end;
    }
    out.write(text.substring(last));
    return out.toString();
  }

  static bool _startsSentence(String text, int index) {
    final before = text.substring(0, index).trimRight();
    return before.isEmpty || _sentenceEnd.hasMatch(before) || before.endsWith('-');
  }

  static String _fixWord(String word, WordList list, int maxRank, {required bool atSentenceStart}) {
    if (!_hasLetter.hasMatch(word)) return word; // nombre
    final lower = word.toLowerCase();
    if (lower.length < 3 || list.contains(lower)) return word;
    // Majuscule au milieu d'une phrase : sans doute un nom propre, on n'y touche pas.
    final first = word.substring(0, 1);
    final capitalized = first != first.toLowerCase();
    final allCaps = word == word.toUpperCase() && word.length > 1;
    // (Sauf s'il contient un chiffre ou un « | » : c'est alors une erreur de lecture.)
    final ocrNoise = _noise.hasMatch(word);
    if (capitalized && !allCaps && !atSentenceStart && !ocrNoise) return word;

    String? best;
    var bestRank = maxRank;
    void consider(String candidate) {
      var c = candidate;
      var r = list.rank[c];
      if (r == null) {
        final viaNorm = list.byNorm[_strip(c)];
        if (viaNorm == null) return;
        c = viaNorm;
        r = list.rank[c]!;
      }
      if (r < bestRank) {
        best = c;
        bestRank = r;
      }
    }

    // 1. Accents oubliés : « ecole » -> « école ».
    consider(lower);
    // 2. Une confusion typique, à n'importe quelle position.
    for (final rule in _confusions) {
      final from = rule[0], to = rule[1];
      var i = lower.indexOf(from);
      while (i >= 0) {
        consider(lower.substring(0, i) + to + lower.substring(i + from.length));
        i = lower.indexOf(from, i + 1);
      }
    }
    // 3. Une lettre perdue ou en trop (« plaí » -> « plaît ») : mots de 4 lettres
    //    ou plus, et seulement vers un mot courant (rang < 10 000).
    if (best == null && lower.length >= 4) {
      final s = _strip(lower);
      final saved = bestRank;
      bestRank = math.min(maxRank, 10000);
      for (var i = 0; i < s.length; i++) {
        consider(s.substring(0, i) + s.substring(i + 1));
      }
      for (var i = 0; i <= s.length; i++) {
        for (final ch in _alphabet.split('')) {
          consider(s.substring(0, i) + ch + s.substring(i));
        }
      }
      if (best == null) bestRank = saved;
    }
    // 4. Deux mots collés (« sigentimènt » -> « si gentiment ») : deux mots
    //    courants (rang < 20 000) de 2 lettres ou plus.
    if (best == null && lower.length >= 5) {
      final split = _split(lower, list, math.min(maxRank, 20000));
      if (split != null) best = split;
    }
    final found = best;
    if (found == null || found == lower) return word;
    if (allCaps) return found.toUpperCase();
    if (capitalized) return found[0].toUpperCase() + found.substring(1);
    return found;
  }

  /// Meilleure coupure de [lower] en deux mots du dictionnaire, ou null.
  static String? _split(String lower, WordList list, int maxRank) {
    String? resolve(String part) {
      if (list.rank.containsKey(part)) return part;
      return list.byNorm[_strip(part)];
    }

    String? best;
    var bestScore = maxRank;
    for (var i = 2; i <= lower.length - 2; i++) {
      final a = resolve(lower.substring(0, i));
      final b = resolve(lower.substring(i));
      if (a == null || b == null) continue;
      final score = math.max(list.rank[a]!, list.rank[b]!);
      if (score < bestScore) {
        bestScore = score;
        best = '$a $b';
      }
    }
    return best;
  }
}
