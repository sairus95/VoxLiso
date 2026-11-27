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
  const StyleVerdict(this.kept, this.ignored, {this.busy = false});
  final Set<int> kept;
  final Set<int> ignored;
  final bool busy;
}

class _Look {
  _Look(this.height, this.center, this.angle, this.at, [this.norm = '']);
  final double height;
  final double center;
  final double? angle;
  final DateTime at;
  final String norm;
}

/// Lignes l'une sous l'autre regroupées (un sous-titre de 1 à 3 lignes, un
/// panneau, un bloc de menu…), dans l'ordre de leur première ligne.
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
      if (isNeighbourLine(rects[i], rects[j])) parent[find(j)] = find(i);
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

/// Aspect des sous-titres de ce qu'on regarde : hauteur des lignes, centre
/// horizontal et inclinaison, appris sur les sous-titres dits. Sert à écarter
/// le reste : menus, panneaux et enseignes du décor, bandeaux, génériques
/// (demande du 27/11/2026 : « elle lit le menu, les panneaux, etc. »).
///
/// - Avant d'avoir appris : un groupe de lignes est lu s'il est à peu près
///   centré dans la zone, pas trop penché, et si l'image n'est pas pleine de
///   texte (menu, page, générique de fin).
/// - Ensuite : seulement les groupes de la même hauteur (×0,65 à ×1,55) et
///   centrés au même endroit (à 8 % de la largeur près), même dans une image
///   pleine de texte.
/// - Pas centré, mais une vraie phrase (3 mots ou plus, pas tout en
///   majuscules, mots connus) : lu quand même (sous-titres pour sourds et
///   malentendants placés sous la personne qui parle). Pas dans un menu.
/// - Si le téléphone a bougé : 3 textes nets différents qui ont tous le même
///   aspect, sans aucun sous-titre reconnu entre-temps, deviennent le nouvel
///   aspect.
class SubtitleStyle {
  SubtitleStyle({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const int minSamples = 3;
  static const int maxSamples = 12;
  static const double centerTolerance = 0.08;
  static const double minHeight = 0.65;
  static const double maxHeight = 1.55;
  static const double angleTolerance = 6;
  static const double maxAngle = 15;
  static const double priorCenter = 0.25;

  /// Lignes visibles sur l'image à partir desquelles c'est un menu ou une page.
  static const int busyLines = 8;

  /// Plus de lignes que ça dans la zone : une liste, pas un sous-titre.
  static const int maxSubtitleLines = 4;

  static const Duration _relearnWindow = Duration(seconds: 15);

  final List<_Look> _samples = [];
  final List<_Look> _shadow = [];
  DateTime? _lastFit;

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
  }

  /// Lignes d'un sous-titre qui vient d'être dit : leur aspect est retenu
  /// (un seul groupe, texte net si un dictionnaire est connu).
  void learn(List<SeenGeom> lines, {WordList? dict}) {
    if (lines.isEmpty) return;
    if (groupLines([for (final l in lines) l.rect]).length != 1) return;
    final text = lines.map((l) => l.text).join(' ');
    if (lines.any((l) => isJunkLine(l.text, dict))) return;
    if (dict != null) {
      if (!ReadingVote.looksClean(text, dict)) return;
    } else if (_letter.allMatches(text).length < 4) {
      return;
    }
    final now = _clock();
    _samples.add(_measure(lines, now));
    if (_samples.length > maxSamples) _samples.removeAt(0);
    _lastFit = now;
  }

  /// Lignes de la zone qui ont l'air de sous-titres. [visibleLines] : lignes
  /// vues sur toute l'image. [needClean] : texte net exigé tant que l'aspect
  /// n'est pas appris (zone du haut, où le décor a souvent du texte).
  StyleVerdict filter(
    List<SeenGeom> lines, {
    required Rect zone,
    int visibleLines = 0,
    WordList? dict,
    bool needClean = false,
  }) {
    final now = _clock();
    final kept = <int>{};
    final ignored = <int>{};
    final rest = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (isJunkLine(lines[i].text, dict)) {
        ignored.add(i);
      } else {
        rest.add(i);
      }
    }
    final busy = visibleLines >= busyLines || rest.length > maxSubtitleLines;
    for (final g in groupLines([for (final i in rest) lines[i].rect])) {
      final idx = [for (final k in g) rest[k]];
      final group = [for (final i in idx) lines[i]];
      final look = _measure(group, now, normalizeForCompare(group.map((l) => l.text).join(' ')));
      final text = group.map((l) => l.text).join(' ');
      var ok = _fits(look, zone, busy, () => _sentenceLike(text, dict));
      if (ok && needClean && !learned && dict != null) ok = ReadingVote.looksClean(text, dict);
      if (!ok && learned && !busy && _plausible(look, zone) && _cleanPhrase(text, dict)) {
        ok = _relearn(look, now);
      }
      if (ok) {
        kept.addAll(idx);
        _lastFit = now;
      } else {
        ignored.addAll(idx);
      }
    }
    return StyleVerdict(kept, ignored, busy: busy);
  }

  bool _plausible(_Look l, Rect zone) =>
      (l.angle == null || _angleGap(l.angle!, 0) <= maxAngle) &&
      (l.center - zone.center.dx).abs() <= priorCenter * zone.width;

  bool _fits(_Look l, Rect zone, bool busy, bool Function() sentence) {
    if (l.angle != null && _angleGap(l.angle!, 0) > maxAngle) return false;
    if (!learned) return !busy && (_plausible(l, zone) || sentence());
    final r = l.height / height!;
    if (r < minHeight || r > maxHeight) return false;
    final a = angle;
    if (a != null && l.angle != null && _angleGap(l.angle!, a) > angleTolerance) return false;
    if ((l.center - center!).abs() > centerTolerance) return !busy && sentence();
    return true;
  }

  /// Une vraie phrase : 3 mots ou plus, des minuscules (une enseigne ou un
  /// titre est souvent tout en majuscules), mots connus si on a le dictionnaire.
  static bool _sentenceLike(String text, WordList? dict) {
    final words = [
      for (final w in text.split(RegExp(r'\s+')))
        if (_letter.allMatches(w).length >= 2) w,
    ];
    if (words.length < 3) return false;
    if (text == text.toUpperCase()) return false;
    return dict == null || ReadingVote.looksClean(text, dict);
  }

  static bool _cleanPhrase(String text, WordList? dict) =>
      dict != null && text.trim().split(RegExp(r'\s+')).length >= 2 && ReadingVote.looksClean(text, dict);

  /// Le téléphone a sans doute bougé : 3 textes nets différents, du même
  /// aspect entre eux, depuis le dernier sous-titre reconnu.
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
        s.height / h >= 0.8 && s.height / h <= 1.25 && (s.center - c).abs() <= centerTolerance);
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
