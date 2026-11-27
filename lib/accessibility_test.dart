import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';

import 'languages.dart';

/// Un texte vu par le service d'accessibilité dans une autre application.
class A11yEntry {
  A11yEntry({
    required this.time,
    required this.pkg,
    required this.text,
    this.top,
    this.bottom,
    this.id = '',
    this.cls = '',
    this.source = 'texte',
  });

  factory A11yEntry.fromMap(Map<dynamic, dynamic> m) {
    double? d(String k) => (m[k] as num?)?.toDouble();
    return A11yEntry(
      time: DateTime.fromMillisecondsSinceEpoch((m['time'] as num?)?.toInt() ?? 0),
      pkg: m['pkg']?.toString() ?? '',
      text: m['text']?.toString() ?? '',
      top: d('t'),
      bottom: d('b'),
      id: m['id']?.toString() ?? '',
      cls: m['cls']?.toString() ?? '',
      source: m['source']?.toString() ?? 'texte',
    );
  }

  final DateTime time;
  final String pkg;
  final String text;

  /// Haut et bas de l'élément (0 = haut de l'écran, 1 = bas), si connus.
  final double? top;
  final double? bottom;
  final String id;
  final String cls;

  /// « texte », « description » ou « annonce ».
  final String source;

  String get appName => appLabel(pkg);

  /// Position verticale lisible : « bas 85 % ».
  String get position {
    if (top == null || bottom == null) return '';
    final c = ((top! + bottom!) / 2 * 100).round().clamp(0, 100);
    final where = c >= 60 ? 'bas' : (c <= 40 ? 'haut' : 'milieu');
    return '$where $c %';
  }

  /// Ligne du journal à copier.
  String get logLine {
    String two(int n) => n.toString().padLeft(2, '0');
    final t = '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    final extra = [
      if (position.isNotEmpty) position,
      if (source != 'texte') source,
      if (id.isNotEmpty) 'id=$id',
      if (cls.isNotEmpty) cls,
    ].join(', ');
    return '$t  $appName  [$extra]  ${text.replaceAll('\n', ' / ')}';
  }
}

/// Nom lisible des applications de vidéo les plus courantes.
String appLabel(String pkg) => const {
      'com.netflix.mediaclient': 'Netflix',
      'com.netflix.ninja': 'Netflix (TV)',
      'com.disney.disneyplus': 'Disney+',
      'com.amazon.avod.thirdpartyclient': 'Prime Video',
      'com.amazon.amazonvideo.livingroom': 'Prime Video (TV)',
      'com.canal.android.canal': 'Canal+',
      'com.apple.atve.androidtv.appletv': 'Apple TV',
      'com.apple.atve.android.appletv': 'Apple TV',
      'com.wbd.stream': 'Max',
      'com.hbo.hbonow': 'Max',
      'com.cbs.ca': 'Paramount+',
      'com.cbs.app': 'Paramount+',
      'com.google.android.youtube': 'YouTube',
      'com.google.android.videos': 'Google TV',
      'fr.francetv.pluzz': 'France.tv',
      'tv.arte.plus7': 'Arte',
      'fr.tf1.mytf1': 'TF1+',
      'fr.m6.m6replay': 'M6+',
      'org.videolan.vlc': 'VLC',
      'com.plexapp.android': 'Plex',
      'com.android.chrome': 'Chrome',
    }[pkg] ??
    pkg;

/// Décide si un texte nouveau doit être dit à voix haute : pas deux fois le
/// même texte en 30 s (les boutons du lecteur réapparaissent souvent).
class SpokenFilter {
  SpokenFilter({this.window = const Duration(seconds: 30)});
  final Duration window;
  final Map<String, DateTime> _said = {};

  bool accept(A11yEntry e, {DateTime? now}) {
    final t = now ?? DateTime.now();
    _said.removeWhere((_, at) => t.difference(at) > window);
    final key = '${e.pkg}|${e.text.trim().toLowerCase()}';
    if (e.text.trim().length < 2 || _said.containsKey(key)) return false;
    _said[key] = t;
    return true;
  }
}

/// Canal vers le service natif (`VoxAccessibilityService.kt`).
class A11yBridge {
  static const MethodChannel _method = MethodChannel('voxliso/a11y');
  static const EventChannel _events = EventChannel('voxliso/a11y/texts');

  static bool get isAvailable => Platform.isAndroid;

  static Stream<A11yEntry> get texts => _events
      .receiveBroadcastStream()
      .where((e) => e is Map)
      .map((e) => A11yEntry.fromMap(e as Map));

  static Future<Map<dynamic, dynamic>> status() async {
    try {
      return await _method.invokeMethod<Map<dynamic, dynamic>>('status') ?? const {};
    } catch (_) {
      return const {};
    }
  }

  static Future<List<A11yEntry>> log() async {
    try {
      final raw = await _method.invokeMethod<List<dynamic>>('log') ?? const [];
      return [for (final m in raw) if (m is Map) A11yEntry.fromMap(m)];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> clear() async {
    try {
      await _method.invokeMethod<bool>('clear');
    } catch (_) {}
  }

  static Future<bool> openSettings() async {
    try {
      return await _method.invokeMethod<bool>('openSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openAppInfo() async {
    try {
      return await _method.invokeMethod<bool>('openAppInfo') ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// Écran de test : les textes que les autres applications exposent à
/// l'accessibilité, pour savoir si les sous-titres de Netflix, Disney+…
/// peuvent être lus sans capturer la vidéo.
class AccessibilityTestScreen extends StatefulWidget {
  const AccessibilityTestScreen({super.key});

  @override
  State<AccessibilityTestScreen> createState() => _AccessibilityTestScreenState();
}

class _AccessibilityTestScreenState extends State<AccessibilityTestScreen>
    with WidgetsBindingObserver {
  final List<A11yEntry> _entries = [];
  final FlutterTts _tts = FlutterTts();
  final LanguageIdentifier _langId = LanguageIdentifier(confidenceThreshold: 0.3);
  final SpokenFilter _filter = SpokenFilter();
  StreamSubscription<A11yEntry>? _sub;
  Timer? _poll;
  bool _enabled = false;
  bool _connected = false;
  int _sdk = 0;
  bool _speak = true;
  bool _onlyVideoApps = true;

  static const _ignored = {
    'com.voxliso.voxliso',
    'com.android.systemui',
    'com.google.android.apps.nexuslauncher',
    'com.sec.android.app.launcher',
    'com.miui.home',
    'com.android.launcher3',
    'com.google.android.inputmethod.latin',
    'com.samsung.android.honeyboard',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _sub = A11yBridge.texts.listen(_onText, onError: (_) {});
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _poll?.cancel();
    _tts.stop();
    _langId.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final log = await A11yBridge.log();
    if (!mounted) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(log.reversed);
    });
    await _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final s = await A11yBridge.status();
    if (!mounted) return;
    setState(() {
      _enabled = s['enabled'] == true;
      _connected = s['connected'] == true;
      _sdk = (s['sdk'] as num?)?.toInt() ?? 0;
    });
  }

  bool _shown(A11yEntry e) => !_onlyVideoApps || !_ignored.contains(e.pkg);

  void _onText(A11yEntry e) {
    if (!mounted) return;
    setState(() {
      _entries.insert(0, e);
      if (_entries.length > 400) _entries.removeLast();
    });
    if (_speak && _shown(e) && _filter.accept(e)) _say(e.text);
  }

  Future<void> _say(String text) async {
    var locale = '';
    try {
      final code = await _langId.identifyLanguage(text);
      locale = supportedLanguage(code)?.ttsLocale ?? '';
    } catch (_) {}
    try {
      if (locale.isNotEmpty) await _tts.setLanguage(locale);
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> _copy() async {
    final shown = _entries.where(_shown).toList().reversed;
    final s = await A11yBridge.status();
    final head = 'VoxLiso, test accessibilité (Android SDK $_sdk, '
        'parcours : ${s['scans'] ?? 0}, dernière appli : ${appLabel(s['package']?.toString() ?? '')})';
    await Clipboard.setData(ClipboardData(text: [head, ...shown.map((e) => e.logLine)].join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Journal copié : collez-le dans votre message à Claude.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = _entries.where(_shown).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test : Netflix, Disney+…'),
        actions: [
          IconButton(
            tooltip: 'Copier le journal',
            icon: const Icon(Icons.copy),
            onPressed: shown.isEmpty ? null : _copy,
          ),
          IconButton(
            tooltip: 'Effacer',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await A11yBridge.clear();
              setState(_entries.clear);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(
                      _connected ? Icons.check_circle : Icons.error_outline,
                      color: _connected ? Colors.green : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _connected
                            ? 'Service d\'accessibilité actif'
                            : (_enabled
                                ? 'Service activé, en attente de démarrage…'
                                : 'Service d\'accessibilité désactivé'),
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  const Text(
                    '1. Activez « VoxLiso : sous-titres » dans les réglages d\'accessibilité '
                    '(souvent dans « Applications installées » ou « Services installés »).\n'
                    '2. Ouvrez Netflix, Disney+ ou une autre appli, lancez un film avec '
                    'les sous-titres activés et regardez 1 ou 2 minutes.\n'
                    '3. Revenez ici : les textes vus s\'affichent ci-dessous. Touchez '
                    '« Copier » en haut et collez le journal dans votre message.',
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    FilledButton.icon(
                      onPressed: A11yBridge.openSettings,
                      icon: const Icon(Icons.accessibility_new),
                      label: const Text('Réglages d\'accessibilité'),
                    ),
                    if (_sdk >= 33 && !_enabled)
                      OutlinedButton.icon(
                        onPressed: A11yBridge.openAppInfo,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('Option grisée ?'),
                      ),
                  ]),
                  if (_sdk >= 33 && !_enabled) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Si l\'option est grisée (« paramètre restreint ») : touchez « Option '
                      'grisée ? », puis le menu ⋮ en haut à droite et « Autoriser les '
                      'paramètres restreints ». Revenez ensuite aux réglages d\'accessibilité.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Dire les nouveaux textes à voix haute'),
            subtitle: const Text(
                'Pour entendre tout de suite, pendant le film, si les sous-titres sont lus. '
                'Les boutons du lecteur peuvent être lus aussi.'),
            value: _speak,
            onChanged: (v) {
              setState(() => _speak = v);
              if (!v) _tts.stop();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Cacher VoxLiso, le clavier et l\'écran d\'accueil'),
            value: _onlyVideoApps,
            onChanged: (v) => setState(() => _onlyVideoApps = v),
          ),
          const Divider(),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                _connected
                    ? 'Aucun texte pour l\'instant. Ouvrez une vidéo avec sous-titres.'
                    : 'Activez d\'abord le service.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          for (final e in shown)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(e.text),
              subtitle: Text([
                e.appName,
                if (e.position.isNotEmpty) e.position,
                if (e.source != 'texte') e.source,
                if (e.id.isNotEmpty) e.id,
              ].join(' · ')),
            ),
        ],
      ),
    );
  }
}
