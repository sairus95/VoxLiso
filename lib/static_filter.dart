import 'text_tools.dart';

class _Seen {
  _Seen(this.norm, this.first) : last = first;
  String norm;
  final DateTime first;
  DateTime last;
}

/// Repère le texte fixe : logo de chaîne, heure, titre d'un menu…
///
/// Un sous-titre reste affiché quelques secondes puis change. Une ligne vue
/// sans interruption pendant plus de [threshold] (20 s par défaut) est donc
/// considérée comme fixe et ignorée. De courtes absences (lecture ratée sur
/// une image floue) sont tolérées jusqu'à [gap].
class StaticTextFilter {
  StaticTextFilter({
    this.threshold = const Duration(seconds: 20),
    this.gap = const Duration(seconds: 3),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration threshold;
  final Duration gap;
  final DateTime Function() _clock;
  final List<_Seen> _seen = [];

  static const double _sameText = 0.85;
  static const int _maxTracked = 60;

  /// Donne les lignes vues sur l'image courante ; renvoie les positions
  /// (indices dans [texts]) des lignes fixes, à ignorer.
  Set<int> update(List<String> texts) {
    final now = _clock();
    _seen.removeWhere((e) => now.difference(e.last) > gap);
    final fixed = <int>{};
    final used = <_Seen>{};
    for (var i = 0; i < texts.length; i++) {
      final norm = normalizeForCompare(texts[i]);
      if (norm.replaceAll(' ', '').length < 2) continue;
      _Seen? match;
      for (final e in _seen) {
        if (used.contains(e)) continue;
        if (e.norm == norm || similarity(e.norm, norm) >= _sameText) {
          match = e;
          break;
        }
      }
      if (match == null) {
        if (_seen.length < _maxTracked) _seen.add(_Seen(norm, now));
        continue;
      }
      used.add(match);
      match
        ..last = now
        ..norm = norm;
      if (now.difference(match.first) >= threshold) fixed.add(i);
    }
    return fixed;
  }

  void reset() => _seen.clear();
}
