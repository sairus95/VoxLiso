import 'dart:math' as math;
import 'dart:ui' show Rect;

/// Zone miroir : la même bande de l'autre côté de l'image. Les sous-titres
/// passent souvent en haut quand le bas de l'image est pris par un texte
/// (lieu, date, nom d'une personne interviewée, générique). La zone miroir est
/// lue seulement quand rien n'est lu dans la zone principale.
///
/// [top] et [bottom] : bande principale (fractions 0..1 de la hauteur).
/// Renvoie la bande miroir, sans chevaucher la principale, ou null si elle
/// serait trop petite.
(double, double)? mirrorBand(double top, double bottom, {double minHeight = 0.08}) {
  var t = 1 - bottom;
  var b = 1 - top;
  const gap = 0.02;
  if ((top + bottom) / 2 >= 0.5) {
    b = math.min(b, top - gap); // zone en bas : miroir au-dessus
  } else {
    t = math.max(t, bottom + gap); // zone en haut : miroir en dessous
  }
  t = t.clamp(0.0, 1.0).toDouble();
  b = b.clamp(0.0, 1.0).toDouble();
  if (b - t < minHeight) return null;
  return (t, b);
}

/// Lignes retenues dans la [zone] (même repère que les rectangles) :
/// - le centre de la ligne est entre les bords gauche et droit de la zone, et
///   au moins la moitié de sa hauteur est entre ses bords haut et bas ;
/// - plus une ligne voisine, juste au-dessus ou juste au-dessous d'une ligne
///   retenue, de même taille et alignée avec elle : c'est l'autre ligne d'un
///   sous-titre sur deux lignes qui dépasse de la zone (sans elle, la phrase
///   serait coupée).
/// Renvoie les numéros des lignes retenues, dans l'ordre de [rects].
List<int> linesInZone(List<Rect> rects, Rect zone) {
  bool inside(Rect r) {
    if (r.height <= 0) return false;
    if (r.center.dx < zone.left || r.center.dx > zone.right) return false;
    final overlap = math.min(r.bottom, zone.bottom) - math.max(r.top, zone.top);
    return overlap >= r.height * 0.5;
  }

  final kept = <int>{
    for (var i = 0; i < rects.length; i++)
      if (inside(rects[i])) i,
  };
  final anchors = kept.toList();
  for (var i = 0; i < rects.length; i++) {
    if (kept.contains(i)) continue;
    final c = rects[i];
    if (c.height <= 0) continue;
    for (final k in anchors) {
      if (isNeighbourLine(rects[k], c)) {
        kept.add(i);
        break;
      }
    }
  }
  return [
    for (var i = 0; i < rects.length; i++)
      if (kept.contains(i)) i,
  ];
}

/// [other] est-elle la ligne juste au-dessus ou juste au-dessous de [line],
/// dans le même sous-titre ? (Même hauteur à 40 % près, écart vertical de
/// moins de 0,8 hauteur de ligne, l'une centrée sous l'autre.)
bool isNeighbourLine(Rect line, Rect other) {
  if (line.height <= 0 || other.height <= 0) return false;
  final ratio = other.height / line.height;
  if (ratio < 0.6 || ratio > 1.6) return false;
  final h = (line.height + other.height) / 2;
  final gap = other.center.dy < line.center.dy
      ? line.top - other.bottom // au-dessus
      : other.top - line.bottom; // au-dessous
  if (gap < -0.3 * h || gap > 0.8 * h) return false;
  final aligned = (other.center.dx >= line.left && other.center.dx <= line.right) ||
      (line.center.dx >= other.left && line.center.dx <= other.right);
  return aligned;
}

/// Une ligne lue sur une image recadrée [crop] touche-t-elle un bord du
/// recadrage ? Elle est alors sans doute coupée (lettres ou mots en moins) :
/// on ne la garde pas. Un bord qui est aussi celui de l'image ne compte pas.
bool touchesCropEdge(Rect line, Rect crop, {double margin = 0.004}) {
  bool cut(double lineEdge, double cropEdge, double imageEdge, {required bool low}) {
    if ((cropEdge - imageEdge).abs() < 1e-3) return false;
    return low ? lineEdge <= cropEdge + margin : lineEdge >= cropEdge - margin;
  }

  return cut(line.left, crop.left, 0, low: true) ||
      cut(line.right, crop.right, 1, low: false) ||
      cut(line.top, crop.top, 0, low: true) ||
      cut(line.bottom, crop.bottom, 1, low: false);
}

/// Recadrage de la lecture renforcée : la [zone], agrandie pour contenir les
/// lignes déjà vues sur l'image normale ([seen], même repère, fractions 0..1)
/// avec une marge, pour qu'une ligne qui dépasse de la zone ne soit jamais
/// coupée. Sans ligne vue : toute la largeur [visible], et un peu plus haut et
/// plus bas que la zone (une ligne à moitié dans la zone est lue aussi).
Rect enhancedCrop(Rect zone, List<Rect> seen, Rect visible) {
  Rect r;
  if (seen.isEmpty) {
    r = Rect.fromLTRB(visible.left, zone.top - 0.03, visible.right, zone.bottom + 0.03);
  } else {
    r = zone;
    for (final s in seen) {
      final my = s.height * 0.4;
      r = r.expandToInclude(Rect.fromLTRB(s.left - 0.03, s.top - my, s.right + 0.03, s.bottom + my));
    }
  }
  return Rect.fromLTRB(
    math.max(r.left, visible.left),
    math.max(r.top, visible.top),
    math.min(r.right, visible.right),
    math.min(r.bottom, visible.bottom),
  );
}
