import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'reading_vote.dart';
import 'spell_fixer.dart' show WordList;
import 'text_tools.dart';
import 'zones.dart';

/// Ligne lue sur une image, rectangle en fractions de l'image (0 à 1).
class SeenGeom {
  const SeenGeom(this.rect, this.text, {this.angle});
  final Rect rect;
  final String text;

  /// Inclinaison donnée par ML Kit, en degrés (Android ; null sur iPhone).
  final double? angle;
}

/// Résultat de [SubtitleStyle.filter] : positions des lignes gardées et des
/// lignes écartées ; [busy] = image pleine de texte (menu, page, générique).
class StyleVerdict {
  const StyleVerdict(this.kept, this.ignored, {this.busy = false, this.reasons = const {}});
  final Set<int> kept;
  final Set<int> ignored;
  final bool busy;

  /// Raisons des lignes écartées (diagnostic) : « menu ou page », « pas
  /// centré », « autre taille », « penché », « heure, sigle ou adresse »,
  /// « mots inconnus ».
  final Set<String> reasons;
}

class _Look {
  _Look(this.height, this.center, this.left, this.right, this.angle, this.at, [this.norm = '']);
  final double height;
  final double center;
  final double left;
  final double right;
  final double? angle;
  final DateTime at;
  final String norm;

  /// Centré sur [c] à [tol] près, ou assez large pour passer par [c] (une
  /// longue ligne de sous-titre passe toujours par le milieu de l'écran).
  bool centeredOn(double c, double tol) => (center - c).abs() <= tol || (left <= c && c <= right);
}

/// Morceaux d'une même ligne que ML Kit a coupée en deux (grand espace entre
/// deux mots) : même hauteur, à la même hauteur, proches.
bool isSameRow(Rect a, Rect b) {
  final h = math.min(a.height, b.height);
  final hMax = math.max(a.height, b.height);
  if (h <= 0 || hMax / h > 1.6) return false;
  final overlap = math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
  if (overlap < 0.5 * h) return false;
  final gap = math.max(a.left, b.left) - math.min(a.right, b.right);
  return gap <= 2.5 * hMax;
}

/// Lignes l'une sous l'autre, ou morceaux d'une même ligne, regroupés (un
/// sous-titre de 1 à 3 lignes, un panneau, un bloc de menu…), dans l'ordre de
/// leur première ligne.
List<List<int>> groupLines(List<Rect> rects) {
  final parent = List<int>.generate(rects.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      if (isNeighbourLine(rects[i], rects[j]) || isSameRow(rects[i], rects[j])) {
        parent[find(j)] = find(i);
      }
    }
  }
  final groups = <int, List<int>>{};
  for (var i = 0; i < rects.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(i);
  }
  return groups.values.toList();
}

final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _web = RegExp(r'(https?://|www\.|#\w|@\w)', caseSensitive: false);
// Adresse en minuscules (« tf1.fr », « france.tv ») : pas « Non.Tu » ni « No.It's ».
final RegExp _domain = RegExp(r'\b[a-z0-9-]{2,}\.(fr|com|net|org|tv)\b');
final RegExp _digit = RegExp(r'\d');

/// Ligne qui n'est sûrement pas un sous-titre : heure, score, numéro de chaîne
/// (presque pas de lettres), adresse web, mot-dièse, compte (@…), sigle court
/// hors dictionnaire (« TF1 », « HD », « 4K »).
bool isJunkLine(String text, WordList? dict) {
  final t = text.trim();
  final letters = _letter.allMatches(t).length;
  if (letters < 2 || _digit.allMatches(t).length > letters) return true;
  if (_web.hasMatch(t) || _domain.hasMatch(t)) return true;
  if (t.split(RegExp(r'\s+')).length == 1) {
    final w = t.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
    if (w.length <= 4) {
      if (_digit.hasMatch(w)) return true;
      final caps = w == w.toUpperCase() && w != w.toLowerCase();
      if (caps && dict != null && !ReadingVote.isKnownWord(w, dict)) return true;
    }
  }
  return false;
}

/// Ligne « réelle » pour compter le texte d'une image : 5 lettres ou plus,
/// pas une heure ni un sigle (les petits bouts lus dans le décor ne comptent pas).
bool isRealLine(String text, WordList? dict) =>
    _letter.allMatches(text).length >= 5 && !isJunkLine(text, dict);

/// Part des mots (2 lettres ou plus) qui sont dans le dictionnaire, et leur nombre.
({double known, int words}) _knownWords(String text, WordList dict) {
  final words = [
    for (final w in text.split(RegExp(r'\s+')))
      if (_letter.allMatches(w).length >= 2) w.replaceAll(RegExp(r"[^\p{L}'’-]", unicode: true), ''),
  ];
  if (words.isEmpty) return (known: 0, words: 0);
  final k = words.where((w) => ReadingVote.isKnownWord(w, dict)).length;
  return (known: k / words.length, words: words.length);
}

/// Aspect des sous-titres de ce qu'on regarde : hauteur des lignes, centre
/// horizontal et inclinaison, appris sur les sous-titres dits. Sert à écarter
/// le reste : menus, panneaux et enseignes du décor, bandeaux, génériques
/// (demande du 27/11/2026 : « elle lit le menu, les panneaux, etc. »).
///
/// v1.0.97 (retour du 28/11 : « la dernière version ne détecte pas bien les
/// textes », sous-titres encadrés en gris, en mode caméra) : beaucoup plus
/// tolérant.
/// - Avant d'avoir appris : un groupe de lignes est lu s'il passe par le
///   milieu de la zone ou en est à 35 % de sa largeur au plus, ou si c'est
///   une vraie phrase, sauf si l'image est pleine de texte (10 lignes réelles
///   ou plus sur l'image, ou plus de 5 dans la zone : menu, page, générique).
///   Pas de règle d'inclinaison avant d'avoir appris.
/// - Appris (3 sous-titres dits, 75 % de mots connus) : même hauteur (×0,6 à
///   ×1,7), même inclinaison (±10°), centré au même endroit (à 10 % de la
///   largeur près, ou ligne qui passe par ce centre) ; une vraie phrase
///   décalée reste lue (sous-titres pour sourds et malentendants).
/// - Téléphone déplacé : 3 textes différents du même aspect (70 % de mots
///   connus) sans sous-titre reconnu entre-temps deviennent le nouvel aspect.
/// - Bloqué : du texte écarté dans la zone pendant 10 s sans rien de lu →
///   l'aspect appris est oublié (retour aux règles du début).
class SubtitleStyle {
  SubtitleStyle({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const int minSamples = 3;
  static const int maxSamples = 12;
  static const double centerTolerance = 0.10;
  static const double minHeight = 0.6;
  static const double maxHeight = 1.7;
  static const double angleTolerance = 10;
  static const double priorCenter = 0.35;

  /// Lignes réelles visibles sur l'image à partir desquelles c'est un menu ou une page.
  static const int busyLines = 10;

  /// Plus de lignes réelles que ça dans la zone : une liste, pas un sous-titre.
  static const int maxSubtitleLines = 5;

  static const Duration _relearnWindow = Duration(seconds: 20);
  static const Duration stuckAfter = Duration(seconds: 10);

  final List<_Look> _samples = [];
  final List<_Look> _shadow = [];
  DateTime? _lastFit;
  DateTime? _stuckSince;

  bool get learned => _samples.length >= minSamples;
  int get samples => _samples.length;

  double? get height => learned ? _median([for (final s in _samples) s.height]) : null;
  double? get center => learned ? _median([for (final s in _samples) s.center]) : null;
  double? get angle {
    if (!learned) return null;
    final a = [for (final s in _samples) if (s.angle != null) s.angle!];
    return a.length >= minSamples ? _median(a) : null;
  }

  void reset() {
    _samples.clear();
    _shadow.clear();
    _lastFit = null;
    _stuckSince = null;
  }

  /// Lignes d'un sous-titre qui vient d'être dit : leur aspect est retenu
  /// (un seul groupe, 75 % de mots connus si un dictionnaire est connu).
  void learn(List<SeenGeom> lines, {WordList? dict}) {
    if (lines.isEmpty) return;
    if (groupLines([for (final l in lines) l.rect]).length != 1) return;
    final text = lines.map((l) => l.text).join(' ');
    if (lines.any((l) => isJunkLine(l.text, dict))) return;
    if (dict != null) {
      final k = _knownWords(text, dict);
      if (k.words == 0 || k.known < 0.75) return;
    } else if (_letter.allMatches(text).length < 4) {
      return;
    }
    final now = _clock();
    _samples.add(_measure(lines, now));
    if (_samples.length > maxSamples) _samples.removeAt(0);
    _fitAt(now);
  }

  void _fitAt(DateTime now) {
    _lastFit = now;
    _stuckSince = null;
  }

  /// Lignes de la zone qui ont l'air de sous-titres. [visibleLines] : lignes
  /// réelles ([isRealLine]) vues sur toute l'image. [needClean] : texte net
  /// exigé tant que l'aspect n'est pas appris (zone du haut, où le décor a
  /// souvent du texte).
  StyleVerdict filter(
    List<SeenGeom> lines, {
    required Rect zone,
    int visibleLines = 0,
    WordList? dict,
    bool needClean = false,
  }) {
    final now = _clock();
    // Rien de lu depuis 10 s alors que du texte est écarté : on oublie l'aspect.
    if (learned && _stuckSince != null && now.difference(_stuckSince!) >= stuckAfter) reset();
    final kept = <int>{};
    final ignored = <int>{};
    final reasons = <String>{};
    final rest = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (isJunkLine(lines[i].text, dict)) {
        ignored.add(i);
        reasons.add('heure, sigle ou adresse');
      } else {
        rest.add(i);
      }
    }
    var rejected = false;
    final realInZone = rest.where((i) => isRealLine(lines[i].text, dict)).length;
    final busy = visibleLines >= busyLines || realInZone > maxSubtitleLines;
    for (final g in groupLines([for (final i in rest) lines[i].rect])) {
      final idx = [for (final k in g) rest[k]];
      final group = [for (final i in idx) lines[i]];
      final text = group.map((l) => l.text).join(' ');
      final look = _measure(group, now, normalizeForCompare(text));
      var why = _reject(look, zone, busy, () => _sentenceLike(text, dict));
      if (why == null && needClean && !learned && dict != null && !ReadingVote.looksClean(text, dict)) {
        why = 'mots inconnus';
      }
      if (why != null && learned && !busy && _plausible(look, zone) && _mostlyWords(text, dict)) {
        if (_relearn(look, now)) why = null;
      }
      if (why == null) {
        kept.addAll(idx);
        _fitAt(now);
      } else {
        ignored.addAll(idx);
        reasons.add(why);
        rejected = true;
      }
    }
    if (kept.isEmpty && rejected) _stuckSince ??= now;
    return StyleVerdict(kept, ignored, busy: busy, reasons: reasons);
  }

  bool _plausible(_Look l, Rect zone) => l.centeredOn(zone.center.dx, priorCenter * zone.width);

  /// Raison d'écarter ce groupe, ou null s'il a l'air d'un sous-titre.
  String? _reject(_Look l, Rect zone, bool busy, bool Function() sentence) {
    if (!learned) {
      if (busy) return 'menu ou page';
      return _plausible(l, zone) || sentence() ? null : 'pas centré';
    }
    final r = l.height / height!;
    if (r < minHeight || r > maxHeight) return busy ? 'menu ou page' : 'autre taille';
    final a = angle;
    if (a != null && l.angle != null && _angleGap(l.angle!, a) > angleTolerance) return 'penché';
    if (!l.centeredOn(center!, centerTolerance)) {
      if (busy) return 'menu ou page';
      return sentence() ? null : 'pas centré';
    }
    return null;
  }

  /// Au moins 2 mots, 70 % dans le dictionnaire (lecture de caméra pas
  /// toujours parfaite).
  static bool _mostlyWords(String text, WordList? dict) {
    if (dict == null) return false;
    final k = _knownWords(text, dict);
    return k.words >= 2 && k.known >= 0.7;
  }

  /// Une vraie phrase : 3 mots ou plus, des minuscules (une enseigne ou un
  /// titre est souvent tout en majuscules), 70 % de mots connus si on a le
  /// dictionnaire.
  static bool _sentenceLike(String text, WordList? dict) {
    final words = [
      for (final w in text.split(RegExp(r'\s+')))
        if (_letter.allMatches(w).length >= 2) w,
    ];
    if (words.length < 3) return false;
    if (text == text.toUpperCase()) return false;
    return dict == null || _knownWords(text, dict).known >= 0.7;
  }

  /// Le téléphone a sans doute bougé : 3 textes différents, du même aspect
  /// entre eux, depuis le dernier sous-titre reconnu.
  bool _relearn(_Look look, DateTime now) {
    final since = _lastFit != null && now.difference(_lastFit!) < _relearnWindow
        ? _lastFit!
        : now.subtract(_relearnWindow);
    _shadow.removeWhere((s) => !s.at.isAfter(since));
    if (_shadow.any((s) => similarity(s.norm, look.norm) >= 0.8)) return false;
    _shadow.add(look);
    if (_shadow.length > 6) _shadow.removeAt(0);
    if (_shadow.length < 3) return false;
    final recent = _shadow.sublist(_shadow.length - 3);
    final h = _median([for (final s in recent) s.height]);
    final c = _median([for (final s in recent) s.center]);
    final same = recent.every((s) =>
        s.height / h >= 0.8 && s.height / h <= 1.25 && s.centeredOn(c, centerTolerance));
    if (!same) return false;
    _samples
      ..clear()
      ..addAll(recent);
    _shadow.clear();
    return true;
  }

  static _Look _measure(List<SeenGeom> lines, DateTime at, [String norm = '']) {
    var union = lines.first.rect;
    for (final l in lines.skip(1)) {
      union = union.expandToInclude(l.rect);
    }
    final angles = [for (final l in lines) if (l.angle != null) l.angle!];
    return _Look(
      _median([for (final l in lines) l.rect.height]),
      union.center.dx,
      union.left,
      union.right,
      angles.isEmpty ? null : angles.reduce((a, b) => a + b) / angles.length,
      at,
      norm,
    );
  }

  static double _angleGap(double a, double b) {
    var d = (a - b) % 360;
    if (d < 0) d += 360;
    return math.min(d, 360 - d);
  }

  static double _median(List<double> v) {
    final s = [...v]..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }
}
