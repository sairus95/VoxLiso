import 'dart:math' as math;

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
