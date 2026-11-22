/// Phrases coupées entre deux sous-titres (« Je pense que… » / « …tu as raison »).
///
/// Pour la traduction, une phrase traduite en deux morceaux donne souvent un
/// résultat bancal : on repère un sous-titre qui appelle une suite, on attend
/// le suivant quelques secondes et on traduit la phrase entière.
class SentenceJoiner {
  /// Petits mots qui ne terminent presque jamais une phrase : si un sous-titre
  /// finit par l'un d'eux, la phrase continue dans le sous-titre suivant.
  static const Map<String, Set<String>> _openers = {
    'fr': {
      'de', 'du', 'des', 'le', 'la', 'les', 'un', 'une', 'que', 'qui', 'et', 'ou', 'mais',
      'à', 'au', 'aux', 'en', 'pour', 'par', 'avec', 'sans', 'dans', 'sur', 'sous', 'chez',
      'je', 'tu', 'il', 'on', 'ne', 'se', 'ce',
      'mon', 'ma', 'mes', 'ton', 'ta', 'tes', 'son', 'sa', 'ses', 'notre', 'votre', 'leur',
      'si', 'quand', 'comme', 'parce', 'puisque', 'lorsque', 'dont', 'très', },
    'en': {
      'the', 'a', 'an', 'and', 'or', 'but', 'to', 'of', 'with',
      'by', 'into', 'which', 'whose', 'if', 'when',
      'because', 'while', 'than', 'as', 'my', 'your', 'our', 'their', 'its',
      'very', 'such', },
    'de': {
      'der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine', 'einen', 'einem', 'einer',
      'und', 'oder', 'aber', 'von', 'für', 'in', 'bei',
      'unter', 'dass', 'wenn', 'weil', 'ob', 'als', 'wie', 'mein', 'dein',
      'unser', 'euer', 'sehr', },
    'es': {
      'el', 'la', 'los', 'las', 'un', 'una', 'unos', 'unas', 'y', 'o', 'pero', 'de', 'del',
      'a', 'al', 'en', 'con', 'por', 'para', 'sin', 'sobre', 'que', 'cuando',
      'porque', 'como', 'donde', 'tu', 'su', 'mis', 'tus', 'sus', 'nuestro', 'muy',
      'me', 'te', 'se', 'lo', 'le', 'les', 'nos',
    },
    'it': {
      'il', 'lo', 'la', 'i', 'gli', 'le', 'un', 'uno', 'una', 'e', 'o', 'ma', 'di', 'del',
      'della', 'dei', 'a', 'al', 'alla', 'in', 'nel', 'nella', 'con', 'per', 'su', 'da',
      'che', 'se', 'quando', 'perché', 'come', 'dove', 'mio', 'mia', 'tuo', 'tua', 'suo',
      'sua', 'non', 'mi', 'ti', 'si', 'ci', 'vi',
    },
    'pt': {
      'o', 'a', 'os', 'as', 'um', 'uma', 'e', 'ou', 'mas', 'de', 'do', 'da', 'dos', 'das',
      'em', 'no', 'na', 'nos', 'nas', 'com', 'por', 'para', 'sem', 'sobre', 'que', 'se',
      'quando', 'porque', 'como', 'onde', 'meu', 'minha', 'teu', 'tua', 'seu', 'sua',
      'me', 'te', 'lhe', },
  };

  static final RegExp _ellipsisEnd = RegExp(r'(\.\.+|…)\s*$');
  static final RegExp _ellipsisStart = RegExp(r'^\s*(\.\.+|…)\s*');
  static final RegExp _openPunctEnd = RegExp(r'[,;:–—-]\s*$');
  static final RegExp _lastWord = RegExp(r"([\p{L}']+)\s*$", unicode: true);

  /// Le sous-titre appelle-t-il une suite ?
  ///  - finit par « … » ou « ... » ;
  ///  - finit par une virgule, deux-points, point-virgule ou tiret ;
  ///  - finit sans ponctuation par un petit mot (« que », « the », « und »…).
  /// Une phrase finie par une lettre ordinaire est considérée comme complète
  /// (certains sous-titres n'ont jamais de point final).
  static bool isIncomplete(String text, String lang) {
    final t = text.trim().replaceAll('’', "'");
    if (t.isEmpty) return false;
    if (_ellipsisEnd.hasMatch(t)) return true;
    if (_openPunctEnd.hasMatch(t)) return true;
    final m = _lastWord.firstMatch(t);
    if (m == null) return false;
    var word = m.group(1)!.toLowerCase();
    // « qu' », « l' »… : élision, la phrase continue forcément.
    if (word.endsWith("'")) return true;
    // « Fais-le », « Dis-moi », « Va-t'en » : pronom accroché au verbe, fin de phrase.
    if (m.start > 0 && t[m.start - 1] == '-') return false;
    final apostrophe = word.lastIndexOf("'");
    if (apostrophe >= 0) word = word.substring(apostrophe + 1);
    return _openers[lang]?.contains(word) ?? false;
  }

  /// Réunit deux morceaux de phrase en retirant les points de suspension
  /// de liaison (« Je pense que… » + « …tu as raison »).
  static String join(String first, String second) {
    final a = first.trim().replaceFirst(_ellipsisEnd, '').trimRight();
    final b = second.trim().replaceFirst(_ellipsisStart, '');
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a $b';
  }
}
