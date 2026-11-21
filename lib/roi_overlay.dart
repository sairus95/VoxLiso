import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Bande réglable posée sur l'aperçu caméra : seul le texte à l'intérieur
/// est lu. On la déplace en la faisant glisser, on change sa hauteur avec
/// les poignées jaunes. Les lignes reconnues sont encadrées en vert.
class RoiOverlay extends StatelessWidget {
  const RoiOverlay({
    super.key,
    required this.top,
    required this.bottom,
    required this.boxes,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double top;
  final double bottom;

  /// Rectangles des lignes lues, en fractions (0..1) de l'image.
  final List<Rect> boxes;
  final void Function(double top, double bottom) onChanged;
  final VoidCallback onChangeEnd;

  static const double _minBand = 0.08;
  static const double _handle = 44;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      final topPx = top * h;
      final bottomPx = bottom * h;

      return Stack(children: [
        Positioned.fill(
          child: CustomPaint(painter: _RoiPainter(top, bottom, boxes)),
        ),
        // Déplacer toute la bande.
        Positioned(
          left: 0,
          width: w,
          top: topPx + _handle / 2,
          height: math.max(0, bottomPx - topPx - _handle),
          child: Semantics(
            label: 'Zone des sous-titres. Faites glisser pour la déplacer.',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (d) {
                final dy = d.delta.dy / h;
                var t = top + dy;
                var b = bottom + dy;
                if (t < 0) {
                  b -= t;
                  t = 0;
                }
                if (b > 1) {
                  t -= b - 1;
                  b = 1;
                }
                onChanged(t, b);
              },
              onVerticalDragEnd: (_) => onChangeEnd(),
            ),
          ),
        ),
        _handleAt(
          y: topPx,
          h: h,
          w: w,
          label: 'Bord haut de la zone',
          onDrag: (dy) => onChanged(
            (top + dy / h).clamp(0.0, bottom - _minBand),
            bottom,
          ),
        ),
        _handleAt(
          y: bottomPx,
          h: h,
          w: w,
          label: 'Bord bas de la zone',
          onDrag: (dy) => onChanged(
            top,
            (bottom + dy / h).clamp(top + _minBand, 1.0),
          ),
        ),
        Positioned(
          left: 8,
          top: math.min(topPx + 6, h - 24),
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Zone des sous-titres',
                style: TextStyle(color: Colors.yellowAccent, fontSize: 12),
              ),
            ),
          ),
        ),
      ]);
    });
  }

  Widget _handleAt({
    required double y,
    required double h,
    required double w,
    required String label,
    required void Function(double dy) onDrag,
  }) {
    final topPos = (y - _handle / 2).clamp(0.0, math.max(0.0, h - _handle));
    return Positioned(
      left: 0,
      width: w,
      top: topPos,
      height: _handle,
      child: Semantics(
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
          onVerticalDragEnd: (_) => onChangeEnd(),
          child: Center(
            child: Container(
              width: 72,
              height: 10,
              decoration: BoxDecoration(
                color: Colors.yellowAccent,
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
  _RoiPainter(this.top, this.bottom, this.boxes);

  final double top;
  final double bottom;
  final List<Rect> boxes;

  @override
  void paint(Canvas canvas, Size size) {
    final band = Rect.fromLTRB(0, top * size.height, size.width, bottom * size.height);
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.55);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, band.top), shade);
    canvas.drawRect(Rect.fromLTRB(0, band.bottom, size.width, size.height), shade);

    canvas.drawRect(
      band.deflate(1),
      Paint()
        ..color = Colors.yellowAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final boxPaint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final b in boxes) {
      canvas.drawRect(
        Rect.fromLTRB(
          b.left * size.width,
          b.top * size.height,
          b.right * size.width,
          b.bottom * size.height,
        ),
        boxPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_RoiPainter old) =>
      old.top != top || old.bottom != bottom || old.boxes != boxes;
}
