import 'reading_vote.dart' show ReadingVote;
import 'spell_fixer.dart' show WordList;

/// Ponctuation des sous-titres (demande du 28/11/2026 : « essaie d'intégrer
/// au mieux la ponctuation »).
///
/// La voix ne fait une pause, ne monte en fin de question ou ne s'exclame que
/// si la ponctuation arrive jusqu'à elle. Or la reconnaissance de texte lit
/// mal ces petits signes : « Viens! » devient « Viensl » ou « Viens1 »,
/// « Pourquoi? » devient « Pourquoi7 », l'espace après la virgule disparaît
/// (« Oui,mais »), le « ¿ » espagnol est lu « i » (« iQué haces? »)…
///
/// [fixPunctuation] répare ces erreurs avant la correction des mots, la voix et
/// l'historique. Le dictionnaire [dict] de la langue, s'il est chargé, sert à
/// décider si une lettre en fin de mot est un « ! » mal lu (« Viensl ») ou une
/// vraie lettre (« quel »).
String fixPunctuation(String text, {String lang = '', WordList? dict}) {
  var t = text;
  if (t.trim().isEmpty) return t;

  // 1. Apostrophes lues comme des accents ou des guillemets (« l`homme »).
  t = t.replaceAll(_oddApostrophe, "'");
  // 2. Élision séparée de son mot (« j' ai », « l' homme », « I' m »).
  if (_elisionLangs.contains(lang)) {
    t = t.replaceAllMapped(_elisionSpace, (m) => m[1]!);
  } else if (lang == 'en') {
    t = t.replaceAllMapped(_englishContraction, (m) => m[1]!);
  }

  // 3. Fin de mot mal lue, avec le dictionnaire : « Viensl » / « Viens1 » → « Viens! »,
  //    « Pourquoi7 » → « Pourquoi? » (et « Pourquoi 7 » en français).
  if (dict != null) {
    final src = t;
    t = t.replaceAllMapped(_misreadBang, (m) {
      final core = m[1]!, mark = m[2]!;
      // Nom propre au milieu d'une phrase (« Michel », « Raoul ») : on n'y touche pas.
      if (_isUpper(core[0]) && !_atSentenceStart(src, m.start)) return m[0]!;
      // « quel », « mal », « Hôtel » : vrais mots, on n'y touche pas.
      if (!ReadingVote.isKnownWord(core, dict)) return m[0]!;
      if (mark != '1' && ReadingVote.isKnownWord('$core${mark.toLowerCase()}', dict)) {
        return m[0]!;
      }
      return '$core!';
    });
    t = t.replaceAllMapped(_misreadQuestion, (m) {
      final core = m[1]!;
      return ReadingVote.isKnownWord(core, dict) ? '$core?' : m[0]!;
    });
    if (lang == 'fr' && !_digitElsewhere(t)) {
      // Les sous-titres écrivent les petits nombres en lettres : un « 7 » seul
      // en fin de phrase est un « ? » précédé de l'espace française.
      t = t.replaceAllMapped(_frenchLoneSeven, (m) {
        final core = m[1]!;
        return ReadingVote.isKnownWord(core, dict) ? '$core ?' : m[0]!;
      });
    }
  }

  // 4. Signes en double ou mélangés par l'OCR (« Oui,. », « Non ?. », « Bon. , »).
  t = t
      .replaceAllMapped(_commaThenStop, (m) => m[1]!)
      .replaceAllMapped(_stopThenComma, (m) => m[1]!)
      .replaceAllMapped(_markThenDot, (m) => m[1]!);
  // 5. Espaces : aucune avant la virgule et le point (« oui , mais »),
  //    une après la ponctuation collée au mot suivant (« Oui,mais », « non.Tu »).
  t = t
      .replaceAllMapped(_spaceBeforeComma, (m) => m[1]!)
      .replaceAllMapped(_gluedMark, (m) => '${m[1]} ')
      .replaceAllMapped(_gluedStop, (m) => '. ');
  // 6. Point suivi d'une minuscule : une virgule mal lue (« Bon. alors on y va »),
  //    sauf après une abréviation (« etc. », « env. »).
  if (!_noCaseLangs.contains(lang)) {
    t = t.replaceAllMapped(_dotBeforeLower, (m) {
      final word = m[1]!;
      return _abbreviations.contains(word.toLowerCase()) ? m[0]! : '$word, ';
    });
  }
  // 7. Espagnol : « ¿ » et « ¡ » mal lus, et le signe de fin qui va avec.
  if (lang == 'es') t = _spanishMarks(t);

  return t.replaceAll(_spaces, ' ').trim();
}

/// Espagnol : « iQué haces? » → « ¿Qué haces? » ; « ¿Vienes » → « ¿Vienes? »
/// (le signe de fin, petit, est souvent perdu, et c'est lui qui fait monter
/// la voix) ; « ¿Vienes. » → « ¿Vienes? ».
String _spanishMarks(String text) {
  var t = text.replaceAllMapped(_spanishOpening, (m) {
    final rest = text.substring(m.end);
    final close = _closingMark.firstMatch(rest);
    if (close == null) return m[1]!; // on ne sait pas : on retire juste le signe
    return '${m[1]}${close[0] == '?' ? '¿' : '¡'}';
  });

  final out = StringBuffer();
  var i = 0;
  while (i < t.length) {
    final ch = t[i];
    out.write(ch);
    i++;
    if (ch != '¿' && ch != '¡') continue;
    final want = ch == '¿' ? '?' : '!';
    // Fin de la question (ou de l'exclamation) : prochain signe de fin.
    final rest = t.substring(i);
    final end = _clauseEnd.firstMatch(rest);
    if (end == null) {
      // Plus rien jusqu'à la fin du texte : on ferme, sauf si la phrase
      // continue visiblement (virgule, points de suspension, tiret).
      final trimmed = rest.trimRight();
      if (trimmed.isNotEmpty && !_continues.hasMatch(trimmed) && _letterRe.hasMatch(trimmed)) {
        out.write(trimmed);
        out.write(want);
        out.write(rest.substring(trimmed.length));
        i = t.length;
      }
      continue;
    }
    final before = _lastWord.firstMatch(rest.substring(0, end.start))?[0] ?? '';
    if (end[0] == '.' && !_abbreviations.contains(before.toLowerCase())) {
      // « ¿Vienes. » : le « ? » lu comme un point (pas « ¿Sr. García? »).
      out.write(rest.substring(0, end.start));
      out.write(want);
      i += end.end;
    }
  }
  return out.toString();
}

bool _isUpper(String ch) => ch != ch.toLowerCase();

bool _atSentenceStart(String text, int index) {
  final before = text.substring(0, index).trimRight();
  return before.isEmpty || _sentenceEndRe.hasMatch(before);
}

final RegExp _sentenceEndRe = RegExp(r'[.!?…:¦\-–—]$');

bool _digitElsewhere(String t) => _digits.allMatches(t).length > 1;

final RegExp _spaces = RegExp(r'\s+');
final RegExp _digits = RegExp(r'\p{N}', unicode: true);
final RegExp _letterRe = RegExp(r'\p{L}', unicode: true);

/// Accent grave, accent aigu, guillemet simple ou prime entre deux lettres
/// (« l`homme », « l` homme »).
final RegExp _oddApostrophe = RegExp(r'(?<=\p{L})[`´‘ʼ′](?=\s?\p{L})', unicode: true);

/// Langues qui élident (« j'ai », « l'uomo », « l'home »).
const Set<String> _elisionLangs = {'fr', 'it', 'ca'};

/// « j' ai », « qu' il », « dell' anno » : l'espace après l'apostrophe.
final RegExp _elisionSpace = RegExp(
  r"(?<![\p{L}])((?:[cdjlmnstCDJLMNST]|[Qq]u|[Jj]usqu|[Ll]orsqu|[Pp]uisqu|[Qq]uoiqu|"
  r"[Dd]ell|[Dd]all|[Nn]ell|[Ss]ull|[Aa]ll|[Uu]n|[Qq]uest|[Qq]uell|[Cc]ent)['’])\s+(?=\p{L})",
  unicode: true,
);

/// « I' m », « don' t », « it' s ».
final RegExp _englishContraction = RegExp(
  r"(?<=\p{L})(['’])\s+(?=(?:m|s|re|ve|ll|d|t)(?![\p{L}]))",
  unicode: true,
);

/// Ce qui peut suivre un « ! » ou un « ? » : fin du texte, ou une espace puis
/// une majuscule, un tiret, un signe d'ouverture ou un séparateur de réplique.
const String _afterMark = r'(?=$|\s+[\p{Lu}\-–—¿¡«"“¦])';

/// « Viensl », « Viens1 », « ViensI », « Stopl » (3 lettres ou plus avant).
final RegExp _misreadBang = RegExp(
  r'(?<![\p{L}\p{N}])(\p{L}{2,}\p{Ll})([l1I])' + _afterMark,
  unicode: true,
);

/// « Pourquoi7 », « Really7 ».
final RegExp _misreadQuestion = RegExp(
  r'(?<![\p{L}\p{N}])(\p{L}{2,}\p{Ll})7' + _afterMark,
  unicode: true,
);

/// « Tu viens 7 » en fin de texte ou avant la réplique suivante.
final RegExp _frenchLoneSeven = RegExp(
  r'(?<![\p{L}\p{N}])(\p{L}{2,})\s+7' + _afterMark,
  unicode: true,
);

final RegExp _commaThenStop = RegExp(r'[,;:]\s*([.!?…])(?!\.)');
final RegExp _stopThenComma = RegExp(r'(?<!\.)([.!?…])\s*,');
final RegExp _markThenDot = RegExp(r'([!?])\.(?!\.)');

/// « oui , mais » / « demain . » (pas « ... »).
final RegExp _spaceBeforeComma = RegExp(r'(?<=\p{L})\s+([,.])(?![.\p{L}\p{N}])', unicode: true);

/// « Oui,mais », « Quoi?Non », « Non!Tu » : deux lettres de chaque côté (pas « 3,5 »).
final RegExp _gluedMark = RegExp(r'(?<=\p{L}\p{L})([,;!?])(?=\p{L})', unicode: true);

/// « non.Tu viens » : minuscules avant, majuscule puis minuscule après
/// (pas « U.S.A. », « M.Dupont », « e.g. »).
final RegExp _gluedStop = RegExp(r'(?<=\p{Ll}\p{Ll})\.(?=\p{Lu}\p{Ll})', unicode: true);

/// « Bon. alors » : un point entre deux mots en minuscules.
final RegExp _dotBeforeLower =
    RegExp(r'(?<![\p{L}.])(\p{L}*\p{Ll}\p{Ll})\.\s+(?=\p{Ll}\p{Ll})', unicode: true);

/// Langues sans majuscules (le point suivi d'une minuscule ne veut rien dire).
const Set<String> _noCaseLangs = {'zh', 'ja', 'ko'};

/// Abréviations suivies d'un point et d'une minuscule.
const Set<String> _abbreviations = {
  'etc', 'env', 'cf', 'ex', 'vs', 'av', 'apr', 'resp', 'bzw', 'usw', 'ca', 'vgl',
  'sr', 'sra', 'srta', 'st', 'dr', 'nr', 'no', 'tel', 'vol', 'ch', 'art', 'fig',
  'approx', 'min', 'max', 'sec', 'hr', 'hrs', 'mr', 'mrs', 'ms', 'jr', 'sig', 'pag',
  'pp', 'ed', 'dott', 'prof', 'ing', 'avv', 'ecc', 'z', 'evtl', 'ggf',
};

/// « iQué », « jQué », « lNo », « 1Ay », « ?Qué » en début de mot, en espagnol.
/// (Pas « iPhone », « iPad »…)
final RegExp _spanishOpening = RegExp(
  r'(^|[\s(«"“\-–—])[ij1l|?!](?=\p{Lu}\p{Ll})(?!Phone|Pad|Pod|Mac|Cloud|Tunes)',
  unicode: true,
);

final RegExp _closingMark = RegExp(r'[?!]');
final RegExp _clauseEnd = RegExp(r'\.{2,}|[.!?…¿¡]');
final RegExp _lastWord = RegExp(r'\p{L}+$', unicode: true);
final RegExp _continues = RegExp(r'[,;:\-–—]$');
