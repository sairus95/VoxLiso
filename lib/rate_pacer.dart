import 'dart:math' as math;

/// Vitesse automatique : la voix accélère un peu quand elle prend du retard
/// sur les sous-titres, puis revient doucement à la vitesse choisie.
///
/// Le retard se mesure au début de chaque phrase : c'est le texte des
/// sous-titres suivants déjà arrivés et pas encore dits ([waitingChars]).
/// Les répliques d'un même sous-titre ne comptent pas comme du retard.
class RatePacer {
  RatePacer({this.maxBoost = 0.4});

  /// Accélération maximale : 0.4 = jusqu'à +40 %.
  final double maxBoost;

  /// En dessous, pas d'accélération (une ou deux syllabes d'avance, c'est normal).
  static const int startChars = 15;

  /// Retard (en caractères) qui donne l'accélération maximale :
  /// environ un sous-titre de deux lignes en attente.
  static const int fullChars = 100;

  /// Montée et descente maximales d'une phrase à l'autre (pas d'à-coups).
  static const double maxRise = 0.25;
  static const double maxFall = 0.1;

  double _factor = 1.0;

  /// Multiplicateur actuel de la vitesse (1.0 = vitesse choisie).
  double get factor => _factor;

  /// Multiplicateur pour la phrase qui commence.
  double next(int waitingChars) {
    final lag = ((waitingChars - startChars) / (fullChars - startChars)).clamp(0.0, 1.0);
    final target = 1.0 + maxBoost * lag;
    final f = target >= _factor
        ? math.min(target, _factor + maxRise)
        : math.max(target, _factor - maxFall);
    // Par pas de 5 % : la vitesse ne change pas à chaque phrase pour rien.
    _factor = ((f * 20).round() / 20).clamp(1.0, 1.0 + maxBoost).toDouble();
    return _factor;
  }

  void reset() => _factor = 1.0;
}
