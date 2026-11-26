/// Bips pour cadrer la télé (demande du 26/11/2026) : avant la lecture, un
/// bip à chaque image analysée où du texte est dans la zone jaune, d'autant
/// plus aigu que le texte est lisible. Une personne qui voit mal peut ainsi
/// viser la télé sans regarder l'écran (comme un radar de recul).
library;

/// Lisibilité (0 à 1) d'après la confiance de ML Kit pour chaque mot lu dans
/// la zone : 0,4 ou moins (texte flou, lointain) -> 0 ; 0,95 ou plus -> 1.
/// Sans confiance (iPhone) : 0,5.
double readabilityFromConfidence(List<double> confidences) {
  if (confidences.isEmpty) return 0.5;
  final mean = confidences.reduce((a, b) => a + b) / confidences.length;
  return ((mean - 0.4) / 0.55).clamp(0.0, 1.0).toDouble();
}

/// Hauteur du bip en Hz : rien dans la zone -> pas de bip (null) ; sinon de
/// 440 Hz (texte peu lisible) à 1320 Hz (bien lisible), par paliers de
/// 110 Hz pour que la différence s'entende.
double? aimBeepHz(int linesInZone, double readability) {
  if (linesInZone <= 0) return null;
  final step = (readability.clamp(0.0, 1.0) * 8).round();
  return 440.0 + 110.0 * step;
}
