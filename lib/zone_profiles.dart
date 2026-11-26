import 'dart:convert';

/// Profil de zone (demande du 26/11/2026) : « télé du salon », « ordinateur »…
/// La zone jaune, le zoom et la luminosité sont retrouvés en un geste.
/// La bande (haut / bas) s'applique à l'orientation en cours.
class ZoneProfile {
  const ZoneProfile({
    required this.name,
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    required this.zoom,
    required this.exposure,
  });

  final String name;
  final double top, bottom, left, right, zoom, exposure;

  /// 8 profils au plus.
  static const int max = 8;

  Map<String, Object> toJson() => {
        'name': name,
        'top': top,
        'bottom': bottom,
        'left': left,
        'right': right,
        'zoom': zoom,
        'exposure': exposure,
      };

  static ZoneProfile? fromJson(Object? j) {
    if (j is! Map) return null;
    double d(String k, double fallback) => (j[k] is num) ? (j[k] as num).toDouble() : fallback;
    final name = j['name'];
    if (name is! String || name.trim().isEmpty) return null;
    return ZoneProfile(
      name: name.trim(),
      top: d('top', 0.62),
      bottom: d('bottom', 0.95),
      left: d('left', 0.15),
      right: d('right', 0.85),
      zoom: d('zoom', 1),
      exposure: d('exposure', 0),
    );
  }

  /// Les réglages en cours correspondent-ils à ce profil ?
  bool matches({
    required double top,
    required double bottom,
    required double left,
    required double right,
    required double zoom,
    required double exposure,
  }) =>
      (this.top - top).abs() < 0.01 &&
      (this.bottom - bottom).abs() < 0.01 &&
      (this.left - left).abs() < 0.01 &&
      (this.right - right).abs() < 0.01 &&
      (this.zoom - zoom).abs() < 0.05 &&
      (this.exposure - exposure).abs() < 0.05;
}

List<ZoneProfile> decodeProfiles(String json) {
  try {
    final list = jsonDecode(json);
    if (list is! List) return [];
    return [
      for (final j in list)
        if (ZoneProfile.fromJson(j) case final p?) p,
    ];
  } catch (_) {
    return [];
  }
}

String encodeProfiles(List<ZoneProfile> profiles) =>
    jsonEncode([for (final p in profiles) p.toJson()]);

/// Ajoute [p], ou remplace le profil du même nom (sans tenir compte des
/// majuscules) ; au-delà de [ZoneProfile.max], le plus ancien est retiré.
List<ZoneProfile> upsertProfile(List<ZoneProfile> profiles, ZoneProfile p) {
  final key = p.name.toLowerCase();
  final i = profiles.indexWhere((x) => x.name.toLowerCase() == key);
  final out = [...profiles];
  if (i >= 0) {
    out[i] = p;
  } else {
    out.add(p);
    while (out.length > ZoneProfile.max) {
      out.removeAt(0);
    }
  }
  return out;
}

List<ZoneProfile> removeProfile(List<ZoneProfile> profiles, String name) =>
    [for (final p in profiles) if (p.name.toLowerCase() != name.toLowerCase()) p];
