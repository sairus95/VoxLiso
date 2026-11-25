/// Prépare une réplique pour la synthèse vocale, pour une lecture plus
/// naturelle (demande du 25/11/2026 : « voix de l'application plus naturelle »).
///
/// Le texte affiché dans l'historique n'est pas modifié : seul ce qui est dit
/// change.
///
/// - Sous-titre entièrement en MAJUSCULES (fréquent à la télé et dans les
///   sous-titres pour sourds et malentendants) : remis en minuscules avec une
///   majuscule en début de phrase. Sinon, les moteurs de voix épellent
///   certains mots (« NON » → « N, O, N ») et lisent d'un ton haché. Les sigles
///   courants (OK, TV, USA, FBI…) restent en majuscules.
/// - Nom du personnage en tête (« JEAN : Tu viens ? ») : retiré.
/// - Points de suspension : retirés en début de réplique (« ...et puis »),
///   transformés en courte pause entre deux mots (« Je...je » → « Je… je »).
/// - « !!! », « ?? » réduits à un seul signe ; guillemets retirés ; tiret
///   d'incise (« oui - enfin, non ») transformé en virgule.
String speakableText(String text, {String lang = ''}) {
  final original = text.replaceAll(_spaces, ' ').trim();
  if (original.isEmpty) return original;
  var t = original;

  t = _removeSpeakerLabel(t);
  if (isAllCaps(t)) t = sentenceCase(t, lang: lang);

  t = t
      .replaceAll(_quotes, '')
      .replaceAll(_leadingEllipsis, '')
      .replaceAll(_dots, '…')
      .replaceAllMapped(_glued, (m) => '${m[1]}… ')
      .replaceAllMapped(_repeatedMarks, (m) => m[1]!)
      .replaceAll(_incise, ', ')
      .replaceAll(_spaceBeforeComma, '')
      .replaceAll(_spaces, ' ')
      .trim();
  // Il ne reste que de la ponctuation : on garde le texte d'origine.
  return _letterOrDigit.hasMatch(t) ? t : original;
}

/// Vrai si le texte est écrit en majuscules (au moins 4 lettres, aucune minuscule).
bool isAllCaps(String text) {
  var upper = 0;
  for (final m in _cased.allMatches(text)) {
    if (_lower.hasMatch(m[0]!)) return false;
    upper++;
  }
  return upper >= 4;
}

/// « TU VIENS ? NON. » → « Tu viens ? Non. » ; sigles connus gardés.
/// Anglais : « I » et « I'm » gardent leur majuscule. Turc : « I » → « ı ».
String sentenceCase(String text, {String lang = ''}) {
  final lowered = text.replaceAllMapped(_word, (m) {
    final w = m[0]!;
    if (_acronyms.contains(w)) return w;
    if (lang == 'en' && w == 'I') return w;
    // Turc : I sans point → ı, İ → i (toLowerCase ne le fait pas).
    if (lang == 'tr') return w.replaceAll('I', 'ı').replaceAll('İ', 'i').toLowerCase();
    return w.toLowerCase();
  });
  // Majuscule au début et après une fin de phrase.
  return lowered.replaceAllMapped(
    _sentenceStart,
    (m) => '${m[1]}${m[2]!.toUpperCase()}',
  );
}

String _removeSpeakerLabel(String t) {
  final m = _speakerLabel.firstMatch(t);
  if (m == null) return t;
  final rest = t.substring(m.end).trim();
  // Il faut une vraie réplique après le nom, et un nom court (1 ou 2 mots).
  if (!_letter.hasMatch(rest)) return t;
  final name = m[1]!.trim();
  // Au moins 3 lettres, pas un sigle ni un mot d'avertissement (« ATTENTION : »).
  if (_letter.allMatches(name).length < 3) return t;
  if (_acronyms.contains(name) || _notNames.contains(name)) return t;
  // Sous-titre tout en majuscules : « ATTENTION : DANGER » n'est pas un nom.
  if (isAllCaps(rest)) return t;
  return rest;
}

/// Sigles laissés en majuscules quand un sous-titre en majuscules est remis
/// en minuscules (sinon « Fbi » serait lu comme un mot).
/// Pas de sigle qui est aussi un mot courant d'une des langues lues
/// (« UN » en français, « US » en anglais, « EU » en portugais, « VI » en italien…).
const Set<String> _acronyms = {
  'OK', 'TV', 'USA', 'UK', 'UE', 'FBI', 'CIA', 'NSA', 'KGB', 'ONU', 'SOS', 'ADN',
  'DNA', 'GPS', 'PC', 'SMS', 'BBC', 'CNN', 'NYPD', 'LAPD', 'SNCF', 'RER', 'PDG',
  'CEO', 'QG', 'HQ', 'VIP', 'SUV', 'NASA', 'BMW', 'DJ', 'RAF', 'URSS', 'USSR',
  'BND', 'DDR', 'BRD', 'RAI', 'MI6', 'NHS', 'NYC',
};

/// Mots en majuscules suivis de « : » qui ne sont pas des noms de personnage.
const Set<String> _notNames = {
  'ATTENTION', 'NOTE', 'ALERTE', 'AVERTISSEMENT', 'WARNING', 'ACHTUNG', 'HINWEIS',
  'ATENCIÓN', 'AVISO', 'ATTENZIONE', 'AVVISO', 'ATENÇÃO', 'NON', 'OUI', 'YES', 'NEIN',
  'JA', 'NO', 'SÍ', 'NÃO', 'SIM', 'PS', 'INFO', 'FLASH', 'BREAKING',
};

final RegExp _spaces = RegExp(r'\s+');
final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);
final RegExp _cased = RegExp(r'[\p{Lu}\p{Ll}]', unicode: true);
final RegExp _lower = RegExp(r'\p{Ll}', unicode: true);
final RegExp _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// « JEAN : », « MME DUPONT: », « JEAN-PIERRE : » en tête de réplique.
final RegExp _speakerLabel =
    RegExp(r"^(\p{Lu}[\p{Lu}'’\-]*(?: \p{Lu}[\p{Lu}'’\-.]*)?)\s?:\s+", unicode: true);

final RegExp _quotes = RegExp(r'["“”«»„‟‹›]');
final RegExp _leadingEllipsis = RegExp(r'^(?:\.{2,}|…)\s*');
final RegExp _dots = RegExp(r'\.{2,}|…+');
final RegExp _glued = RegExp(r'(\p{L})…(?=\p{L})', unicode: true);
final RegExp _repeatedMarks = RegExp(r'([!?])\1+');
final RegExp _incise = RegExp(r'(?<=\p{L})\s+[-–—]\s+(?=\p{L})', unicode: true);
/// « demain . » (après un guillemet retiré) → « demain. » ; « ? » et « ! » gardent leur espace.
final RegExp _spaceBeforeComma = RegExp(r'\s+(?=[.,…])');

/// Début de texte, ou fin de phrase suivie d'espaces, puis la 1re lettre.
final RegExp _sentenceStart = RegExp(r'(^[^\p{L}]*|[.!?…]\s+[^\p{L}]*)(\p{Ll})', unicode: true);
