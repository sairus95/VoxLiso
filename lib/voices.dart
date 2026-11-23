import 'dart:convert';

import 'languages.dart';

/// Une voix de synthèse installée sur le téléphone.
class TtsVoice {
  TtsVoice({
    required this.name,
    required this.locale,
    this.quality = '',
    this.gender = '',
    this.identifier = '',
    this.networkRequired = false,
    this.notInstalled = false,
  });

  final String name;

  /// Code de langue de la voix, ex. « fr-FR ».
  final String locale;

  /// iPhone : default / enhanced / premium. Android : very low … very high.
  final String quality;

  /// iPhone : male / female / unspecified. Android : non fourni (vide).
  final String gender;

  /// iPhone seulement.
  final String identifier;
  final bool networkRequired;
  final bool notInstalled;

  /// Code de la langue (fr, de, es, it).
  String get lang {
    final code = locale.split(RegExp('[-_]')).first.toLowerCase();
    // Norvégien « nb » / « nn », mandarin « cmn » : codes de VoxLiso « no » et « zh ».
    return switch (code) {
      'nb' || 'nn' => 'no',
      'cmn' => 'zh',
      _ => code,
    };
  }

  String get key => '$name|$locale';

  /// Données attendues par flutter_tts.setVoice().
  Map<String, String> toTts() => {
        'name': name,
        'locale': locale,
        if (identifier.isNotEmpty) 'identifier': identifier,
      };

  String toJson() => jsonEncode({
        'name': name,
        'locale': locale,
        'quality': quality,
        'gender': gender,
        'identifier': identifier,
      });

  static TtsVoice? fromJson(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return TtsVoice(
        name: m['name'] as String,
        locale: m['locale'] as String,
        quality: (m['quality'] ?? '') as String,
        gender: (m['gender'] ?? '') as String,
        identifier: (m['identifier'] ?? '') as String,
      );
    } catch (_) {
      return null;
    }
  }

  /// Lit une entrée de flutter_tts.getVoices (Android ou iPhone).
  static TtsVoice? fromPlatform(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString() ?? '';
    final locale = raw['locale']?.toString() ?? '';
    if (name.isEmpty || locale.isEmpty) return null;
    final features = raw['features']?.toString() ?? '';
    var gender = raw['gender']?.toString() ?? '';
    if (gender.isEmpty) {
      // Certains moteurs Android l'indiquent dans le nom ou les « features ».
      final hint = '$name $features'.toLowerCase();
      if (hint.contains('female')) {
        gender = 'female';
      } else if (hint.contains('male')) {
        gender = 'male';
      }
    }
    return TtsVoice(
      name: name,
      locale: locale,
      quality: raw['quality']?.toString() ?? '',
      gender: gender,
      identifier: raw['identifier']?.toString() ?? '',
      networkRequired: raw['network_required']?.toString() == '1',
      notInstalled: features.contains('notInstalled'),
    );
  }

  /// Note de qualité, pour classer les voix (la plus naturelle d'abord).
  int get qualityRank => switch (quality) {
        'premium' => 6,
        'very high' => 5,
        'enhanced' => 4,
        'high' => 4,
        'normal' => 3,
        'default' => 3,
        'low' => 2,
        'very low' => 1,
        _ => 2,
      };

  /// Utilisable sans internet et déjà installée.
  bool get usableOffline => !networkRequired && !notInstalled;

  String get genderLabel => switch (gender) {
        'female' => 'Femme',
        'male' => 'Homme',
        _ => '',
      };

  String get qualityLabel => switch (quality) {
        'premium' => 'premium',
        'enhanced' => 'améliorée',
        'very high' => 'très naturelle',
        'high' => 'naturelle',
        _ => '',
      };
}

/// Toutes les voix du téléphone, classées par langue et par qualité.
class VoiceCatalog {
  List<TtsVoice> _all = const [];

  bool get isEmpty => _all.isEmpty;

  void load(Object? raw) {
    final list = <TtsVoice>[];
    if (raw is List) {
      for (final r in raw) {
        final v = TtsVoice.fromPlatform(r);
        if (v != null) list.add(v);
      }
    }
    _all = list;
  }

  /// Voix d'une langue : installées hors ligne d'abord, puis l'accent principal
  /// (fr-FR, de-DE, es-ES, it-IT) avant les autres régions, puis par qualité.
  List<TtsVoice> voicesFor(String lang) {
    final main = languageFor(lang).ttsLocale.toLowerCase();
    bool isMain(TtsVoice v) => v.locale.replaceAll('_', '-').toLowerCase() == main;
    final list = _all.where((v) => v.lang == lang).toList();
    list.sort((a, b) {
      if (a.usableOffline != b.usableOffline) return a.usableOffline ? -1 : 1;
      if (isMain(a) != isMain(b)) return isMain(a) ? -1 : 1;
      final q = b.qualityRank.compareTo(a.qualityRank);
      if (q != 0) return q;
      return a.name.compareTo(b.name);
    });
    return list;
  }

  /// Libellés lisibles : sur Android, les noms techniques
  /// (« fr-fr-x-frd-local ») sont remplacés par « Voix 1, Voix 2… ».
  Map<String, String> labelsFor(String lang) {
    final out = <String, String>{};
    var n = 0;
    for (final v in voicesFor(lang)) {
      n++;
      final lower = v.name.toLowerCase();
      final prefix = v.locale.split(RegExp('[-_]')).first.toLowerCase();
      final technical = lower.contains('-x-') ||
          lower.startsWith('$lang-') ||
          lower.startsWith('${lang}_') ||
          lower.startsWith('$prefix-') ||
          lower.startsWith('${prefix}_') ||
          lower.contains('#');
      final parts = <String>[
        technical ? 'Voix $n' : v.name,
        if (v.genderLabel.isNotEmpty) v.genderLabel,
        if (v.qualityLabel.isNotEmpty) v.qualityLabel,
        v.locale,
        if (v.networkRequired) 'internet',
        if (v.notInstalled) 'à télécharger',
      ];
      out[v.key] = parts.join(' · ');
    }
    return out;
  }

  /// Meilleure voix utilisable hors ligne pour une langue.
  TtsVoice? best(String lang) {
    for (final v in voicesFor(lang)) {
      if (v.usableOffline) return v;
    }
    return null;
  }

  /// Une autre voix que [other] pour la même langue (2e personnage) :
  /// de genre opposé si le téléphone l'indique, sinon la suivante.
  TtsVoice? secondVoice(String lang, TtsVoice? other) {
    final candidates = voicesFor(lang)
        .where((v) => v.usableOffline && v.key != other?.key)
        .toList();
    if (candidates.isEmpty) return null;
    if (other != null && other.gender.isNotEmpty) {
      for (final v in candidates) {
        if (v.gender.isNotEmpty && v.gender != other.gender) return v;
      }
    }
    // Même région de préférence (ex. fr-FR plutôt que fr-CA).
    for (final v in candidates) {
      if (other == null || v.locale == other.locale) return v;
    }
    return candidates.first;
  }
}
