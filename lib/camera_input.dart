import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Image prête pour ML Kit, avec la taille « à l'endroit » (portrait)
/// dans laquelle ML Kit exprime les rectangles de texte trouvés.
class FrameInput {
  FrameInput(this.image, this.uprightSize);
  final InputImage image;
  final Size uprightSize;
}

/// Convertit une image du flux caméra pour ML Kit.
/// L'application est bloquée en portrait et utilise la caméra arrière.
FrameInput? buildInputImage(CameraImage image, CameraDescription camera) {
  final w = image.width.toDouble();
  final h = image.height.toDouble();
  if (image.planes.isEmpty) return null;

  if (Platform.isIOS) {
    // Sur iOS, le flux est déjà orienté comme l'écran.
    if (image.format.group != ImageFormatGroup.bgra8888) return null;
    final plane = image.planes.first;
    return FrameInput(
      InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(w, h),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.bgra8888,
          bytesPerRow: plane.bytesPerRow,
        ),
      ),
      Size(w, h),
    );
  }

  // Android : téléphone en portrait + caméra arrière => rotation = orientation du capteur.
  final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
      InputImageRotation.rotation90deg;

  final Uint8List bytes;
  if (image.planes.length == 1) {
    bytes = _packedNv21(image); // déjà en NV21 (lignes éventuellement « rembourrées »)
  } else if (image.planes.length >= 3) {
    bytes = _yuv420ToNv21(image); // certains téléphones livrent du YUV_420_888
  } else {
    return null;
  }

  final swap = rotation == InputImageRotation.rotation90deg ||
      rotation == InputImageRotation.rotation270deg;

  return FrameInput(
    InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(w, h),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      ),
    ),
    swap ? Size(h, w) : Size(w, h),
  );
}

/// NV21 en un seul plan : si chaque ligne contient des octets de remplissage
/// (bytesPerRow > largeur), on les retire, sinon ML Kit lit une image brouillée.
Uint8List _packedNv21(CameraImage image) {
  final plane = image.planes.first;
  final w = image.width;
  final h = image.height;
  final stride = plane.bytesPerRow;
  if (stride <= w) return plane.bytes;
  final out = Uint8List(w * h + w * (h ~/ 2));
  var o = 0;
  final rows = h + h ~/ 2; // lignes Y puis lignes VU
  for (var row = 0; row < rows; row++) {
    final start = row * stride;
    if (start + w > plane.bytes.length) break;
    out.setRange(o, o + w, plane.bytes, start);
    o += w;
  }
  return out;
}

/// Résumé technique d'une image caméra, pour l'écran de diagnostic.
String describeCameraImage(CameraImage image) {
  final p = image.planes;
  final stride = p.isEmpty ? 0 : p.first.bytesPerRow;
  return '${image.width}×${image.height} · ${image.format.group.name}'
      ' · ${p.length} plan${p.length > 1 ? 's' : ''} · ligne $stride o';
}

/// YUV_420_888 (3 plans) -> NV21 (Y puis V/U entrelacés).
Uint8List _yuv420ToNv21(CameraImage image) {
  final width = image.width;
  final height = image.height;
  final cw = width ~/ 2;
  final ch = height ~/ 2;
  final out = Uint8List(width * height + 2 * cw * ch);

  final y = image.planes[0];
  var o = 0;
  for (var row = 0; row < height; row++) {
    out.setRange(o, o + width, y.bytes, row * y.bytesPerRow);
    o += width;
  }

  final u = image.planes[1];
  final v = image.planes[2];
  final uPix = u.bytesPerPixel ?? 1;
  final vPix = v.bytesPerPixel ?? 1;
  for (var row = 0; row < ch; row++) {
    final uRow = row * u.bytesPerRow;
    final vRow = row * v.bytesPerRow;
    for (var col = 0; col < cw; col++) {
      out[o++] = v.bytes[vRow + col * vPix];
      out[o++] = u.bytes[uRow + col * uPix];
    }
  }
  return out;
}

/// Lit la largeur et la hauteur d'un fichier JPEG (en-tête SOF), sans le décoder.
Size? jpegSize(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    if (marker == 0xFF) {
      i++;
      continue;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
      i += 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    final isSof = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return Size(w.toDouble(), h.toDouble());
    }
    i += 2 + len;
  }
  return null;
}
