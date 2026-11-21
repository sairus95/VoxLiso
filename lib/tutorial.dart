import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'logo.dart';
import 'settings.dart';

/// Tutoriel du premier lancement : placer le téléphone, la bande jaune,
/// la langue, la lecture. Revoir depuis les réglages.
class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key, required this.settings, required this.onDone});

  final AppSettings settings;
  final VoidCallback onDone;

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _Page {
  const _Page(this.title, this.text, this.picture);
  final String title;
  final String text;
  final _Picture picture;
}

enum _Picture { welcome, phone, band, language, read, screen }

class _TutorialScreenState extends State<TutorialScreen> {
  final PageController _controller = PageController();
  int _index = 0;

  late final List<_Page> _pages = [
    const _Page(
      'Bienvenue dans VoxLiso',
      'VoxLiso lit à voix haute les sous-titres affichés sur votre télé ou votre '
          "ordinateur, en français, allemand, espagnol ou italien. Tout se passe sur le "
          'téléphone, sans internet.',
      _Picture.welcome,
    ),
    const _Page(
      "1. Placez le téléphone face à l'écran",
      'Le mieux : téléphone couché (paysage) sur un petit support, caméra tournée vers la '
          "télé. Activez la rotation automatique de l'écran. Utilisez le zoom pour que la "
          "télé remplisse l'image.",
      _Picture.phone,
    ),
    const _Page(
      '2. Placez la bande jaune sur les sous-titres',
      "Faites glisser la bande jaune avec le doigt ; les poignées changent sa hauteur. "
          'Le texte lu est encadré en vert. En orange, il est en dehors de la bande et ne '
          'sera pas lu.',
      _Picture.band,
    ),
    const _Page(
      '3. La langue',
      'Laissez « Auto » : VoxLiso reconnaît la langue de chaque sous-titre. Dans les '
          'réglages (⚙) : choix des voix, une voix par personnage, et traduction.',
      _Picture.language,
    ),
    const _Page(
      '4. Lancez la lecture',
      'Appuyez sur « Lire les sous-titres ». Phrase manquée ? Le bouton « Répéter » la '
          "redit, et l'historique (🕘) garde toutes les phrases lues.",
      _Picture.read,
    ),
    if (Platform.isAndroid)
      const _Page(
        'Vidéos sur le téléphone',
        'Pour YouTube, le navigateur ou vos vidéos : choisissez « Écran du téléphone » au '
            'lieu de « Caméra ». Netflix, Disney+ et Prime Video bloquent cette fonction.',
        _Picture.screen,
      ),
  ];

  bool get _last => _index == _pages.length - 1;

  void _next() {
    if (_last) {
      widget.settings.tutorialSeen = true;
      widget.onDone();
    } else {
      _controller.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () {
                widget.settings.tutorialSeen = true;
                widget.onDone();
              },
              child: const Text('Passer'),
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final p = _pages[i];
                return LayoutBuilder(builder: (context, c) {
                  final wide = c.maxWidth > c.maxHeight;
                  final picture = p.picture == _Picture.welcome
                      ? Center(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            LogoMark(size: (c.maxWidth * 0.4).clamp(96.0, 200.0).toDouble()),
                            const SizedBox(height: 20),
                            const Wordmark(fontSize: 44),
                            const SizedBox(height: 6),
                            Text('Vos sous-titres, lus à voix haute.',
                                style: theme.textTheme.bodyLarge
                                    ?.copyWith(color: const Color(0xFFC9D2EA))),
                          ]),
                        )
                      : Semantics(
                          excludeSemantics: true,
                          child: CustomPaint(
                            size: Size.infinite,
                            painter: _TutorialPainter(p.picture, theme.colorScheme.primary),
                          ),
                        );
                  final texts = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.title, style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 12),
                      Text(p.text, style: theme.textTheme.bodyLarge),
                      if (i == _pages.length - 1) ...[
                        const SizedBox(height: 16),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Mode grands boutons'),
                          subtitle: const Text(
                              'Pour les personnes qui voient mal : textes et boutons '
                              'agrandis, annonces vocales.'),
                          value: widget.settings.largeMode,
                          onChanged: (v) => setState(() => widget.settings.largeMode = v),
                        ),
                      ],
                    ],
                  );
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: wide
                        ? Row(children: [
                            Expanded(child: picture),
                            const SizedBox(width: 24),
                            Expanded(child: SingleChildScrollView(child: texts)),
                          ])
                        : Column(children: [
                            Expanded(flex: 5, child: picture),
                            const SizedBox(height: 16),
                            Expanded(flex: 6, child: SingleChildScrollView(child: texts)),
                          ]),
                  );
                });
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Row(children: [
              Semantics(
                label: 'Page ${_index + 1} sur ${_pages.length}',
                child: Row(children: [
                  for (var i = 0; i < _pages.length; i++)
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      width: i == _index ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _index
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                ]),
              ),
              const Spacer(),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _next,
                  child: Text(_last ? 'Commencer' : 'Suivant',
                      style: const TextStyle(fontSize: 18)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Illustrations simples dessinées à la main (télé, sous-titres, bande, téléphone).
class _TutorialPainter extends CustomPainter {
  _TutorialPainter(this.picture, this.accent);
  final _Picture picture;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    final stroke = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.025
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = kBrandNavy;
    final white = Paint()..color = Colors.white;

    Rect tv(double w, double h, Offset center) =>
        Rect.fromCenter(center: center, width: w, height: h);

    void drawTv(Rect r, {bool subtitles = true}) {
      final rr = RRect.fromRectAndRadius(r, Radius.circular(r.height * 0.08));
      canvas.drawRRect(rr, fill);
      canvas.drawRRect(rr, stroke);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(r.center.dx, r.bottom + s * 0.05),
              width: r.width * 0.3,
              height: s * 0.03),
          Radius.circular(s * 0.015),
        ),
        Paint()..color = accent,
      );
      if (subtitles) {
        final h = r.height * 0.09;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(r.center.dx, r.bottom - r.height * 0.28),
                width: r.width * 0.7,
                height: h),
            Radius.circular(h / 2),
          ),
          white,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(r.center.dx, r.bottom - r.height * 0.14),
                width: r.width * 0.45,
                height: h),
            Radius.circular(h / 2),
          ),
          white,
        );
      }
    }

    void waves(Offset origin, double scale) {
      for (var i = 1; i <= 3; i++) {
        canvas.drawArc(
          Rect.fromCircle(center: origin, radius: s * 0.06 * i * scale),
          -0.7,
          1.4,
          false,
          stroke,
        );
      }
    }

    switch (picture) {
      case _Picture.welcome:
        final r = tv(s * 0.62, s * 0.44, c.translate(-s * 0.08, -s * 0.04));
        drawTv(r);
        waves(Offset(r.right + s * 0.03, r.center.dy), 1);
      case _Picture.phone:
        final r = tv(s * 0.7, s * 0.42, c.translate(0, -s * 0.18));
        drawTv(r);
        // Téléphone couché sur un support, vu de dos, face à la télé.
        final phone = Rect.fromCenter(
            center: c.translate(0, s * 0.27), width: s * 0.36, height: s * 0.18);
        canvas.drawRRect(
            RRect.fromRectAndRadius(phone, Radius.circular(s * 0.03)), Paint()..color = accent);
        canvas.drawCircle(phone.topLeft.translate(s * 0.06, s * 0.06), s * 0.025, fill);
        final stand = Path()
          ..moveTo(phone.center.dx - s * 0.1, phone.bottom + s * 0.08)
          ..lineTo(phone.center.dx, phone.bottom)
          ..lineTo(phone.center.dx + s * 0.1, phone.bottom + s * 0.08);
        canvas.drawPath(stand, stroke);
        // Regard de la caméra vers la télé.
        final dash = Paint()
          ..color = accent.withValues(alpha: 0.6)
          ..strokeWidth = s * 0.012;
        for (var y = phone.top - s * 0.02; y > r.bottom + s * 0.1; y -= s * 0.04) {
          canvas.drawLine(Offset(c.dx, y), Offset(c.dx, y - s * 0.02), dash);
        }
      case _Picture.band:
        final r = tv(s * 0.86, s * 0.56, c);
        drawTv(r);
        final band = Rect.fromLTRB(r.left + s * 0.02, r.bottom - r.height * 0.42,
            r.right - s * 0.02, r.bottom - r.height * 0.04);
        canvas.drawRect(
          band,
          Paint()
            ..color = kBrandYellow
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.012,
        );
        final green = Paint()
          ..color = Colors.greenAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.008;
        final h = r.height * 0.13;
        canvas.drawRect(
            Rect.fromCenter(
                center: Offset(r.center.dx, r.bottom - r.height * 0.28),
                width: r.width * 0.76,
                height: h),
            green);
        canvas.drawRect(
            Rect.fromCenter(
                center: Offset(r.center.dx, r.bottom - r.height * 0.14),
                width: r.width * 0.51,
                height: h),
            green);
        // Doigt qui fait glisser la poignée.
        final handle = Offset(r.center.dx, band.top);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: handle, width: s * 0.16, height: s * 0.03),
              Radius.circular(s * 0.015)),
          Paint()..color = kBrandYellow,
        );
        canvas.drawCircle(handle.translate(s * 0.12, -s * 0.1), s * 0.045,
            Paint()..color = Colors.white.withValues(alpha: 0.85));
        canvas.drawLine(handle.translate(s * 0.12, -s * 0.16), handle.translate(s * 0.12, -s * 0.04),
            Paint()
              ..color = Colors.white
              ..strokeWidth = s * 0.01);
      case _Picture.language:
        const labels = ['Auto', 'FR', 'DE', 'ES', 'IT'];
        final w = s * 0.17;
        for (var i = 0; i < labels.length; i++) {
          final rect = Rect.fromCenter(
              center: Offset(c.dx + (i - 2) * (w + s * 0.02), c.dy),
              width: w,
              height: s * 0.14);
          final rr = RRect.fromRectAndRadius(rect, Radius.circular(s * 0.04));
          canvas.drawRRect(rr, i == 0 ? (Paint()..color = accent) : fill);
          canvas.drawRRect(rr, stroke..strokeWidth = s * 0.01);
          final tp = TextPainter(
            text: TextSpan(
              text: labels[i],
              style: TextStyle(
                  color: i == 0 ? Colors.black : Colors.white,
                  fontSize: s * 0.05,
                  fontWeight: FontWeight.bold),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, rect.center - Offset(tp.width / 2, tp.height / 2));
        }
        stroke.strokeWidth = s * 0.025;
      case _Picture.read:
        final button = Rect.fromCenter(center: c, width: s * 0.8, height: s * 0.2);
        canvas.drawRRect(
            RRect.fromRectAndRadius(button, Radius.circular(s * 0.1)), Paint()..color = accent);
        final tp = TextPainter(
          text: TextSpan(
            text: 'Lire les sous-titres',
            style: TextStyle(
                color: Colors.black, fontSize: s * 0.06, fontWeight: FontWeight.bold),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: button.width * 0.9);
        tp.paint(canvas, button.center - Offset(tp.width / 2, tp.height / 2));
        waves(Offset(button.right + s * 0.02, button.center.dy), 0.7);
      case _Picture.screen:
        final phone = Rect.fromCenter(center: c, width: s * 0.42, height: s * 0.8);
        final rr = RRect.fromRectAndRadius(phone, Radius.circular(s * 0.06));
        canvas.drawRRect(rr, fill);
        canvas.drawRRect(rr, stroke);
        final video = Rect.fromLTWH(
            phone.left + s * 0.03, phone.top + s * 0.1, phone.width - s * 0.06, s * 0.22);
        canvas.drawRect(video, Paint()..color = const Color(0xFF2A3A6B));
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(video.center.dx, video.bottom - s * 0.04),
                width: video.width * 0.7,
                height: s * 0.025),
            Radius.circular(s * 0.0125),
          ),
          white,
        );
        waves(Offset(phone.right + s * 0.03, video.center.dy), 0.8);
    }
  }

  @override
  bool shouldRepaint(_TutorialPainter old) => old.picture != picture || old.accent != accent;
}
