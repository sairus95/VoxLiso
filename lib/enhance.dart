import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Image renforcée : la zone des sous-titres, recadrée, contrastée et agrandie.
class EnhancedFrame {
  EnhancedFrame(this.image, this.zone, this.uprightSize);
  final InputImage image;

  /// Zone recadrée, en fractions 0..1 de l'image complète « à l'endroit ».
  final Rect zone;

  /// Taille « à l'endroit » de l'image renforcée (repère des rectangles de ML Kit).
  final Size uprightSize;

  /// Rectangle de ML Kit (pixels de l'image renforcée) -> fractions de l'image complète.
  Rect toFull(Rect r) => Rect.fromLTRB(
        zone.left + r.left / uprightSize.width * zone.width,
        zone.top + r.top / uprightSize.height * zone.height,
        zone.left + r.right / uprightSize.width * zone.width,
        zone.top + r.bottom / uprightSize.height * zone.height,
      );
}

const Map<DeviceOrientation, int> _degrees = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

/// Taille visée pour le grand côté de l'image renforcée.
const int _targetSide = 1600;

/// Construit l'image renforcée de la [zone] (fractions de l'image « à l'endroit »).
EnhancedFrame? buildEnhancedInput(
  CameraImage image,
  CameraDescription camera,
  DeviceOrientation orientation,
  Rect zone,
) {
  final z = Rect.fromLTRB(
    (zone.left - 0.02).clamp(0.0, 1.0).toDouble(),
    (zone.top - 0.02).clamp(0.0, 1.0).toDouble(),
    (zone.right + 0.02).clamp(0.0, 1.0).toDouble(),
    (zone.bottom + 0.02).clamp(0.0, 1.0).toDouble(),
  );
  if (z.width <= 0.01 || z.height <= 0.01 || image.planes.isEmpty) return null;
  return Platform.isIOS ? _ios(image, z) : _android(image, camera, orientation, z);
}

/// Contraste automatique : étire les niveaux entre les 2 % les plus sombres
/// et les 2 % les plus clairs (sous-titres pâles, reflets, écran lointain).
Uint8List _contrastLut(List<int> histogram, int total) {
  var lo = 0, hi = 255, acc = 0;
  final cut = (total * 0.02).round();
  for (var i = 0; i < 256; i++) {
    acc += histogram[i];
    if (acc > cut) {
      lo = i;
      break;
    }
  }
  acc = 0;
  for (var i = 255; i >= 0; i--) {
    acc += histogram[i];
    if (acc > cut) {
      hi = i;
      break;
    }
  }
  final lut = Uint8List(256);
  if (hi - lo < 16) {
    for (var i = 0; i < 256; i++) {
      lut[i] = i;
    }
    return lut;
  }
  for (var i = 0; i < 256; i++) {
    lut[i] = (((i - lo) * 255) ~/ (hi - lo)).clamp(0, 255);
  }
  return lut;
}

/// Recadre [src] (luminance, [stride] octets par ligne) sur x0..x0+cw, y0..y0+ch,
/// agrandit par interpolation bilinéaire et applique le contraste.
Uint8List _cropScale(Uint8List src, int stride, int x0, int y0, int cw, int ch, int ow, int oh,
    int Function(Uint8List, int) lum, int bpp) {
  // Histogramme (un pixel sur deux) pour le contraste.
  final hist = List<int>.filled(256, 0);
  var n = 0;
  for (var y = y0; y < y0 + ch; y += 2) {
    final row = y * stride;
    for (var x = x0; x < x0 + cw; x += 2) {
      hist[lum(src, row + x * bpp)]++;
      n++;
    }
  }
  final lut = _contrastLut(hist, n);
  final out = Uint8List(ow * oh);
  final sx = cw / ow, sy = ch / oh;
  for (var oy = 0; oy < oh; oy++) {
    final fy = (oy + 0.5) * sy - 0.5;
    final yA = fy.floor().clamp(0, ch - 1), yB = (yA + 1).clamp(0, ch - 1);
    final wy = ((fy - yA) * 256).round().clamp(0, 256);
    final rowA = (y0 + yA) * stride, rowB = (y0 + yB) * stride;
    final o = oy * ow;
    for (var ox = 0; ox < ow; ox++) {
      final fx = (ox + 0.5) * sx - 0.5;
      final xA = fx.floor().clamp(0, cw - 1), xB = (xA + 1).clamp(0, cw - 1);
      final wx = ((fx - xA) * 256).round().clamp(0, 256);
      final pa = (x0 + xA) * bpp, pb = (x0 + xB) * bpp;
      final top = lum(src, rowA + pa) * (256 - wx) + lum(src, rowA + pb) * wx;
      final bottom = lum(src, rowB + pa) * (256 - wx) + lum(src, rowB + pb) * wx;
      out[o + ox] = lut[((top * (256 - wy) + bottom * wy) >> 16).clamp(0, 255)];
    }
  }
  return out;
}

(int, int) _outputSize(int cw, int ch) {
  final scale = (_targetSide / math.max(cw, ch)).clamp(1.0, 2.5);
  int even(double v) => math.max(2, (v.round() ~/ 2) * 2);
  return (even(cw * scale), even(ch * scale));
}

EnhancedFrame? _android(
    CameraImage image, CameraDescription camera, DeviceOrientation orientation, Rect z) {
  final w = image.width, h = image.height;
  final y = image.planes.first;
  final comp = _degrees[orientation] ?? 0;
  final r = camera.lensDirection == CameraLensDirection.front
      ? (camera.sensorOrientation + comp) % 360
      : (camera.sensorOrientation - comp + 360) % 360;

  // Rectangle « à l'endroit » -> rectangle dans l'image brute du capteur.
  (double, double) toRaw(double u, double v) => switch (r) {
        90 => (v, 1 - u),
        180 => (1 - u, 1 - v),
        270 => (1 - v, u),
        _ => (u, v),
      };
  final a = toRaw(z.left, z.top), b = toRaw(z.right, z.bottom);
  final x0 = (math.min(a.$1, b.$1) * w).floor().clamp(0, w - 2);
  final y0 = (math.min(a.$2, b.$2) * h).floor().clamp(0, h - 2);
  final x1 = (math.max(a.$1, b.$1) * w).ceil().clamp(x0 + 2, w);
  final y1 = (math.max(a.$2, b.$2) * h).ceil().clamp(y0 + 2, h);
  final cw = x1 - x0, ch = y1 - y0;
  final (ow, oh) = _outputSize(cw, ch);

  final luma = _cropScale(y.bytes, y.bytesPerRow, x0, y0, cw, ch, ow, oh, (s, i) => s[i], 1);
  // NV21 en niveaux de gris : luminance, puis chrominance neutre (128).
  final nv21 = Uint8List(ow * oh + ow * oh ~/ 2)..fillRange(ow * oh, ow * oh + ow * oh ~/ 2, 128);
  nv21.setRange(0, ow * oh, luma);

  final rotation = InputImageRotationValue.fromRawValue(r) ?? InputImageRotation.rotation90deg;
  final swap = r == 90 || r == 270;
  return EnhancedFrame(
    InputImage.fromBytes(
      bytes: nv21,
      metadata: InputImageMetadata(
        size: Size(ow.toDouble(), oh.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: ow,
      ),
    ),
    z,
    swap ? Size(oh.toDouble(), ow.toDouble()) : Size(ow.toDouble(), oh.toDouble()),
  );
}

EnhancedFrame? _ios(CameraImage image, Rect z) {
  if (image.format.group != ImageFormatGroup.bgra8888) return null;
  final w = image.width, h = image.height;
  final p = image.planes.first;
  final x0 = (z.left * w).floor().clamp(0, w - 2);
  final y0 = (z.top * h).floor().clamp(0, h - 2);
  final x1 = (z.right * w).ceil().clamp(x0 + 2, w);
  final y1 = (z.bottom * h).ceil().clamp(y0 + 2, h);
  final cw = x1 - x0, ch = y1 - y0;
  final (ow, oh) = _outputSize(cw, ch);
  // BGRA -> luminance (approximation entière de 0,299 R + 0,587 G + 0,114 B).
  final luma = _cropScale(p.bytes, p.bytesPerRow, x0, y0, cw, ch, ow, oh,
      (s, i) => (s[i] * 29 + s[i + 1] * 150 + s[i + 2] * 77) >> 8, 4);
  final bgra = Uint8List(ow * oh * 4);
  for (var i = 0, j = 0; i < luma.length; i++, j += 4) {
    final v = luma[i];
    bgra[j] = v;
    bgra[j + 1] = v;
    bgra[j + 2] = v;
    bgra[j + 3] = 255;
  }
  return EnhancedFrame(
    InputImage.fromBytes(
      bytes: bgra,
      metadata: InputImageMetadata(
        size: Size(ow.toDouble(), oh.toDouble()),
        rotation: InputImageRotation.rotation0deg,
        format: InputImageFormat.bgra8888,
        bytesPerRow: ow * 4,
      ),
    ),
    z,
    Size(ow.toDouble(), oh.toDouble()),
  );
}
