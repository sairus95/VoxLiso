import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'logo.dart';

/// Ligne de texte trouvée par l'OCR (en fractions 0..1 de l'image).
class DetectedBox {
  const DetectedBox(this.rect, this.inZone, {this.fixed = false});
  final Rect rect;
  final bool inZone;

  /// Texte fixe (logo, heure…) ignoré : encadré en gris.
  final bool fixed;
}

/// Zone réglable posée sur l'aperçu : seul le texte à l'intérieur est lu.
/// On la déplace en la faisant glisser ; les poignées jaunes changent sa
/// hauteur (haut, bas) et, si [onHorizontalChanged] est donné, sa largeur
/// (gauche, droite). Lignes lues encadrées en vert, ignorées en orange.
class RoiOverlay extends StatelessWidget {
  const RoiOverlay({
    super.key,
    required this.top,
    required this.bottom,
    this.left = 0,
    this.right = 1,
    required this.boxes,
    required this.onChanged,
    this.onHorizontalChanged,
    required this.onChangeEnd,
  });

  final double top;
  final double bottom;
  final double left;
  final double right;

  /// Lignes trouvées : vertes dans la zone (lues), orange en dehors (ignorées).
  final List<DetectedBox> boxes;
  final void Function(double top, double bottom) onChanged;

  /// Si absent, la zone occupe toute la largeur.
  final void Function(double left, double right)? onHorizontalChanged;
  final VoidCallback onChangeEnd;

  static const double _minHeight = 0.08;
  static const double _minWidth = 0.2;
  static const double _handle = 44;

  bool get _horizontal => onHorizontalChanged != null;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      final l = _horizontal ? left : 0.0;
      final r = _horizontal ? right : 1.0;
      final zone = Rect.fromLTRB(l * w, top * h, r * w, bottom * h);

      void move(Offset delta) {
        var t = top + delta.dy / h;
        var b = bottom + delta.dy / h;
        if (t < 0) {
          b -= t;
          t = 0;
        }
        if (b > 1) {
          t -= b - 1;
          b = 1;
        }
        onChanged(t, b);
        if (_horizontal) {
          var nl = left + delta.dx / w;
          var nr = right + delta.dx / w;
          if (nl < 0) {
            nr -= nl;
            nl = 0;
          }
          if (nr > 1) {
            nl -= nr - 1;
            nr = 1;
          }
          onHorizontalChanged!(nl, nr);
        }
      }

      return Stack(children: [
        Positioned.fill(
          child: CustomPaint(painter: _RoiPainter(Rect.fromLTRB(l, top, r, bottom), boxes)),
        ),
        // Déplacer toute la zone.
        Positioned(
          left: zone.left + (_horizontal ? _handle / 2 : 0),
          width: math.max(0, zone.width - (_horizontal ? _handle : 0)),
          top: zone.top + _handle / 2,
          height: math.max(0, zone.height - _handle),
          child: Semantics(
            label: 'Zone des sous-titres. Faites glisser pour la déplacer.',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) => move(d.delta),
              onPanEnd: (_) => onChangeEnd(),
            ),
          ),
        ),
        _edge(
          rect: Rect.fromLTWH(zone.left, zone.top - _handle / 2, zone.width, _handle),
          bounds: Size(w, h),
          vertical: false,
          label: 'Bord haut de la zone',
          onDrag: (d) => onChanged((top + d.dy / h).clamp(0.0, bottom - _minHeight).toDouble(), bottom),
        ),
        _edge(
          rect: Rect.fromLTWH(zone.left, zone.bottom - _handle / 2, zone.width, _handle),
          bounds: Size(w, h),
          vertical: false,
          label: 'Bord bas de la zone',
          onDrag: (d) => onChanged(top, (bottom + d.dy / h).clamp(top + _minHeight, 1.0).toDouble()),
        ),
        if (_horizontal) ...[
          _edge(
            rect: Rect.fromLTWH(zone.left - _handle / 2, zone.top, _handle, zone.height),
            bounds: Size(w, h),
            vertical: true,
            label: 'Bord gauche de la zone',
            onDrag: (d) => onHorizontalChanged!(
                (left + d.dx / w).clamp(0.0, right - _minWidth).toDouble(), right),
          ),
          _edge(
            rect: Rect.fromLTWH(zone.right - _handle / 2, zone.top, _handle, zone.height),
            bounds: Size(w, h),
            vertical: true,
            label: 'Bord droit de la zone',
            onDrag: (d) => onHorizontalChanged!(
                left, (right + d.dx / w).clamp(left + _minWidth, 1.0).toDouble()),
          ),
        ],
        Positioned(
          left: math.min(zone.left + 8, math.max(0, w - 150)),
          top: math.min(zone.top + 6, h - 24),
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Zone des sous-titres',
                style: TextStyle(color: kBrandYellow, fontSize: 12),
              ),
            ),
          ),
        ),
      ]);
    });
  }

  /// Poignée de bord : barre jaune au milieu du côté, zone tactile de 44 px.
  Widget _edge({
    required Rect rect,
    required Size bounds,
    required bool vertical,
    required String label,
    required void Function(Offset delta) onDrag,
  }) {
    final left = rect.left.clamp(0.0, math.max(0.0, bounds.width - rect.width)).toDouble();
    final top = rect.top.clamp(0.0, math.max(0.0, bounds.height - rect.height)).toDouble();
    return Positioned(
      left: left,
      top: top,
      width: rect.width,
      height: rect.height,
      child: Semantics(
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) => onDrag(d.delta),
          onPanEnd: (_) => onChangeEnd(),
          child: Center(
            child: Container(
              width: vertical ? 10 : 72,
              height: vertical ? 56 : 10,
              decoration: BoxDecoration(
                color: kBrandYellow,
                borderRadius: BorderRadius.circular(5),
                boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoiPainter extends CustomPainter {
  _RoiPainter(this.zone, this.boxes);

  /// Zone en fractions 0..1.
  final Rect zone;
  final List<DetectedBox> boxes;

  @override
  void paint(Canvas canvas, Size size) {
    final z = Rect.fromLTRB(zone.left * size.width, zone.top * size.height,
        zone.right * size.width, zone.bottom * size.height);
    // Assombrit tout sauf la zone.
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(z);
    canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.55));

    canvas.drawRect(
      z.deflate(1),
      Paint()
        ..color = kBrandYellow
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final inPaint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final outPaint = Paint()
      ..color = Colors.orangeAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final fixedPaint = Paint()
      ..color = Colors.grey
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final d in boxes) {
      final b = d.rect;
      canvas.drawRect(
        Rect.fromLTRB(
          b.left * size.width,
          b.top * size.height,
          b.right * size.width,
          b.bottom * size.height,
        ),
        d.fixed ? fixedPaint : (d.inZone ? inPaint : outPaint),
      );
    }
  }

  @override
  bool shouldRepaint(_RoiPainter old) => old.zone != zone || old.boxes != boxes;
}
