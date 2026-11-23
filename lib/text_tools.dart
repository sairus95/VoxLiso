import 'dart:math' as math;

import 'languages.dart' show isCjkRune;

final RegExp _soundTags = RegExp(r'\[[^\]]*\]|\([^)]*\)');
final RegExp _junkChars = RegExp(r'[♪♫#*|¦_~<>{}\\]');
final RegExp _dialogueDash = RegExp(r'^[-–—－]+\s*');
final RegExp _inlineDialogue = RegExp(r'(?<=[.!?…])\s+[-–—]\s+');
final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _endsWithPunct = RegExp(r'[.!?…:;,。！？、，：；]$');
final RegExp _spaces = RegExp(r'\s+');

/// Transforme les lignes lues par l'OCR en une phrase prête à être dite.
///
/// - retire les descriptions sonores [Musique] (rires) si demandé,
/// - retire les symboles parasites (♪, |, #…),
/// - écarte les lignes qui ne ressemblent pas à du texte (bruit de l'OCR),
/// - sépare les répliques de dialogue (« - Oui. » / « - Non. ») par une pause.
String cleanSubtitle(List<String> lines, {bool removeSoundTags = true}) =>
    subtitleParts(lines, removeSoundTags: removeSoundTags).join(' ');

/// Comme [cleanSubtitle], mais renvoie chaque réplique séparément :
/// « - Tu viens ? » / « - Non » donne ['Tu viens ?', 'Non.'].
List<String> subtitleParts(List<String> lines, {bool removeSoundTags = true}) {
  final parts = <String>[];
  var buffer = '';

  // « - Oui. - Non. » sur une seule ligne : on sépare les répliques.
  final expanded = <String>[];
  for (final raw in lines) {
    final pieces = raw.split(_inlineDialogue);
    for (var i = 0; i < pieces.length; i++) {
      expanded.add(i == 0 ? pieces[i] : '- ${pieces[i]}');
    }
  }

  for (final raw in expanded) {
    var line = raw.trim();
    if (removeSoundTags) line = line.replaceAll(_soundTags, ' ');
    line = line.replaceAll(_junkChars, ' ').replaceAll(_spaces, ' ').trim();
    if (line.isEmpty || !_looksLikeText(line)) continue;

    if (_dialogueDash.hasMatch(line)) {
      line = line.replaceFirst(_dialogueDash, '');
      if (buffer.isNotEmpty) {
        parts.add(buffer);
        buffer = '';
      }
    }
    if (line.isEmpty) continue;
    // Chinois, japonais : deux lignes se suivent sans espace.
    final glue = buffer.isNotEmpty &&
            isCjkRune(buffer.runes.last) &&
            isCjkRune(line.runes.first)
        ? ''
        : ' ';
    buffer = buffer.isEmpty ? line : '$buffer$glue$line';
  }
  if (buffer.isNotEmpty) parts.add(buffer);

  // Pause entre les répliques d'un dialogue ; la dernière garde sa ponctuation
  // d'origine, pour savoir si la phrase continue dans le sous-titre suivant.
  if (parts.length > 1) {
    for (var i = 0; i < parts.length - 1; i++) {
      if (_endsWithPunct.hasMatch(parts[i])) continue;
      // Chinois, japonais : point « 。 » ; ailleurs « . ».
      final last = parts[i].runes.isEmpty ? 0 : parts[i].runes.last;
      parts[i] = '${parts[i]}${isCjkRune(last) ? '。' : '.'}';
    }
  }
  return [
    for (final p in parts)
      if (p.trim().isNotEmpty) p.replaceAll(_spaces, ' ').trim(),
  ];
}

bool _looksLikeText(String line) {
  final compact = line.replaceAll(' ', '');
  if (compact.isEmpty) return false;
  final letters = _letter.allMatches(compact).length;
  return letters >= 2 && letters / compact.length >= 0.6;
}

const Map<String, String> _accents = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
  'ç': 'c',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ñ': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ý': 'y', 'ÿ': 'y',
  'ß': 'ss', 'œ': 'oe', 'æ': 'ae',
  // Langues d'Europe centrale et du Nord, roumain, turc
  'ą': 'a', 'ă': 'a', 'ā': 'a',
  'ć': 'c', 'č': 'c',
  'ď': 'd', 'đ': 'd',
  'ę': 'e', 'ě': 'e', 'ē': 'e',
  'ğ': 'g',
  'ı': 'i', 'ī': 'i',
  'ł': 'l', 'ľ': 'l', 'ĺ': 'l',
  'ń': 'n', 'ň': 'n',
  'ő': 'o', 'ø': 'o',
  'ř': 'r', 'ŕ': 'r',
  'ś': 's', 'š': 's', 'ş': 's', 'ș': 's',
  'ť': 't', 'ţ': 't', 'ț': 't',
  'ů': 'u', 'ű': 'u', 'ū': 'u',
  'ź': 'z', 'ż': 'z', 'ž': 'z',
};

/// Tout sauf les lettres et chiffres (de toutes les écritures : latin,
/// chinois, japonais, coréen…).
final RegExp _nonAlnum = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

final RegExp _edgeEllipsis = RegExp(r'^(\.{2,}|…)\s*|\s*(\.{2,}|…)$');

/// Prépare un sous-titre pour la traduction : retire les points de suspension
/// de début et de fin (« ...et puis » / « je pense que... »), qui marquent
/// une phrase coupée entre deux sous-titres et gênent la traduction.
String prepareForTranslation(String text) {
  final t = text.replaceAll(_edgeEllipsis, '').replaceAll(_spaces, ' ').trim();
  return t.isEmpty ? text.trim() : t;
}

/// Version « simplifiée » d'un texte pour comparer deux lectures de l'OCR :
/// minuscules, sans accents ni ponctuation.
String normalizeForCompare(String text) {
  final lower = text.toLowerCase();
  final sb = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    sb.write(_accents[ch] ?? ch);
  }
  return sb.toString().replaceAll(_nonAlnum, ' ').trim();
}

/// Ressemblance entre deux textes, de 0 (rien à voir) à 1 (identiques).
double similarity(String a, String b) {
  if (a == b) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  final d = _levenshtein(a, b);
  return 1 - d / math.max(a.length, b.length);
}

int _levenshtein(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var cur = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    cur[0] = i;
    final ca = a.codeUnitAt(i - 1);
    for (var j = 1; j <= b.length; j++) {
      final cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    final tmp = prev;
    prev = cur;
    cur = tmp;
  }
  return prev[b.length];
}
