import 'package:flutter/material.dart';

/// Couleurs du logo VoxLiso (piste B « Bulle-onde »).
const Color kBrandYellow = Color(0xFFFFC93C);
const Color kBrandNavy = Color(0xFF12204A);

/// Le logo : bulle de parole bleu nuit sur fond jaune, une ligne de
/// sous-titre blanche et une onde sonore. Version simplifiée en petit.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Logo VoxLiso',
        image: true,
        child: CustomPaint(size: Size.square(size), painter: _LogoPainter(simple: size <= 48)),
      );
}

class _LogoPainter extends CustomPainter {
  _LogoPainter({required this.simple});
  final bool simple;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final yellow = Paint()..color = kBrandYellow;
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 100, 100), const Radius.circular(22)),
      yellow,
    );
    final bubble = Path()
      ..moveTo(28, 18)
      ..lineTo(72, 18)
      ..quadraticBezierTo(84, 18, 84, 30)
      ..lineTo(84, 58)
      ..quadraticBezierTo(84, 70, 72, 70)
      ..lineTo(44, 70)
      ..lineTo(30, 82)
      ..lineTo(30, 70)
      ..lineTo(28, 70)
      ..quadraticBezierTo(16, 70, 16, 58)
      ..lineTo(16, 30)
      ..quadraticBezierTo(16, 18, 28, 18)
      ..close();
    canvas.drawPath(bubble, Paint()..color = kBrandNavy);

    void bar(double x, double y, double w, double h, Paint p) => canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(w / 2)),
          p,
        );
    final white = Paint()..color = Colors.white;
    if (simple) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(27, 28, 46, 7), const Radius.circular(3.5)),
          white);
      bar(28, 44, 8, 16, yellow);
      bar(40, 40, 8, 24, yellow);
      bar(52, 45, 8, 14, yellow);
      bar(64, 42, 8, 20, yellow);
    } else {
      canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(27, 30, 46, 5), const Radius.circular(2.5)),
          white);
      const bars = [
        [27.0, 49.0, 8.0],
        [34.0, 45.0, 16.0],
        [41.0, 42.0, 22.0],
        [48.0, 47.0, 12.0],
        [55.0, 44.0, 18.0],
        [62.0, 48.0, 10.0],
        [69.0, 46.0, 14.0],
      ];
      for (final b in bars) {
        bar(b[0], b[1], 4, b[2], yellow);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.simple != simple;
}

/// « VoxLiso » : Vox en blanc, Liso en jaune, comme sur la planche du logo.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.fontSize = 22});
  final double fontSize;

  @override
  Widget build(BuildContext context) => Text.rich(
        TextSpan(children: [
          const TextSpan(text: 'Vox', style: TextStyle(color: Colors.white)),
          const TextSpan(text: 'Liso', style: TextStyle(color: kBrandYellow)),
        ]),
        semanticsLabel: 'VoxLiso',
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, letterSpacing: -0.5),
      );
}
