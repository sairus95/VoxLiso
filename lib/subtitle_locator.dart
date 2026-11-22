import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'text_tools.dart';

/// Une ligne vue pendant le repérage (rectangle en fractions 0..1 de l'aperçu).
class SeenLine {
  SeenLine(this.text, this.rect);
  final String text;
  final Rect rect;
}

/// Zone proposée pour les sous-titres (fractions 0..1).
class LocatedZone {
  LocatedZone(this.top, this.bottom, this.left, this.right, this.subtitles);
  final double top, bottom, left, right;

  /// Nombre de sous-titres différents qui ont servi à placer la zone.
  final int subtitles;
}

class _Group {
  _Group(this.norm);
  final String norm;
  final Set<int> frames = {};
  final List<Rect> rects = [];
}

/// Repère où apparaissent les sous-titres : on observe l'écran quelques
/// secondes ; le texte qui reste identique (logo, heure) est écarté, et la
/// zone est placée autour du texte qui change, de préférence centré.
class SubtitleLocator {
  final List<_Group> _groups = [];
  int frames = 0;

  void add(List<SeenLine> lines) {
    final frame = frames++;
    for (final l in lines) {
      final norm = normalizeForCompare(l.text);
      if (norm.replaceAll(' ', '').length < 3) continue;
      _Group? g;
      for (final e in _groups) {
        if (e.norm == norm || similarity(e.norm, norm) >= 0.8) {
          g = e;
          break;
        }
      }
      g ??= (_groups..add(_Group(norm))).last;
      g.frames.add(frame);
      g.rects.add(l.rect);
    }
  }

  List<_Group> get _changing {
    if (frames == 0) return const [];
    return [
      for (final g in _groups)
        // Fixe : présent sur presque toutes les images.
        if (!(frames >= 6 && g.frames.length >= frames * 0.7))
          // Bruit : vu une seule fois.
          if (g.frames.length >= 2) g,
    ];
  }

  /// Nombre de textes différents qui changent (sous-titres probables).
  int get distinctChanging => _changing.length;

  LocatedZone? result() {
    final groups = _changing;
    final rects = <Rect>[
      for (final g in groups)
        for (final r in g.rects)
          if (r.center.dx > 0.1 && r.center.dx < 0.9) r,
    ];
    if (rects.isEmpty) return null;

    // Bande verticale (30 % de la hauteur) qui contient le plus de lignes.
    final centers = rects.map((r) => r.center.dy).toList()..sort();
    var bestStart = 0, bestCount = 0;
    for (var i = 0, j = 0; i < centers.length; i++) {
      while (j < centers.length && centers[j] - centers[i] <= 0.3) {
        j++;
      }
      if (j - i > bestCount) {
        bestCount = j - i;
        bestStart = i;
      }
    }
    final lo = centers[bestStart], hi = lo + 0.3;
    final kept = rects.where((r) => r.center.dy >= lo && r.center.dy <= hi).toList();

    var top = kept.map((r) => r.top).reduce(math.min);
    var bottom = kept.map((r) => r.bottom).reduce(math.max);
    var left = kept.map((r) => r.left).reduce(math.min);
    var right = kept.map((r) => r.right).reduce(math.max);

    // Place pour un sous-titre sur deux lignes et marges.
    final heights = kept.map((r) => r.height).toList()..sort();
    final lineH = heights[heights.length ~/ 2];
    final minH = math.max(0.15, lineH * 3);
    final cy = (top + bottom) / 2;
    if (bottom - top + 0.08 < minH) {
      top = cy - minH / 2;
      bottom = cy + minH / 2;
    } else {
      top -= 0.04;
      bottom += 0.04;
    }
    final cx = kept.map((r) => r.center.dx).reduce((a, b) => a + b) / kept.length;
    left = math.min(left - 0.05, cx - 0.25);
    right = math.max(right + 0.05, cx + 0.25);

    double clamp(double v) => v.clamp(0.0, 1.0).toDouble();
    return LocatedZone(clamp(top), clamp(bottom), clamp(left), clamp(right), groups.length);
  }
}
