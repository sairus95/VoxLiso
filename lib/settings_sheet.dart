import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'languages.dart';
import 'settings.dart';
import 'system_bridge.dart';
import 'translator.dart';
import 'version.dart';
import 'voices.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.settings,
    required this.voice,
    required this.voiceMissing,
    required this.catalog,
    required this.translator,
    required this.primaryVoice,
    required this.secondVoice,
    required this.onVoiceChanged,
    required this.onEngineChanged,
    required this.onInstallVoices,
    required this.onPreviewVoice,
    required this.onResetZone,
    required this.onTutorial,
  });

  final AppSettings settings;

  /// Langue de la voix utilisée en ce moment (choisie ou détectée).
  final SubtitleLanguage voice;
  final bool voiceMissing;
  final VoiceCatalog catalog;
  final SubtitleTranslator translator;

  /// Voix réellement utilisées pour une langue (choix ou automatique).
  final TtsVoice? Function(String lang) primaryVoice;
  final ({TtsVoice? voice, double pitch}) Function(String lang) secondVoice;

  final Future<void> Function() onVoiceChanged;

  /// Android : changement de moteur de voix (recharge la liste des voix).
  final Future<void> Function(String engine) onEngineChanged;

  /// Android : ouvre l'écran de téléchargement de voix du téléphone.
  final Future<bool> Function() onInstallVoices;

  /// Fait entendre une phrase d'exemple avec une voix et une hauteur.
  final void Function(String lang, TtsVoice? voice, double pitch) onPreviewVoice;
  final VoidCallback onResetZone;
  final VoidCallback onTutorial;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  AppSettings get s => widget.settings;
  late final TextEditingController _deepl = TextEditingController(text: widget.settings.deeplKey);
  bool _testing = false;
  String? _testResult;

  @override
  void dispose() {
    _deepl.dispose();
    super.dispose();
  }

  Future<void> _testDeepl() async {
    s.deeplKey = _deepl.text;
    widget.translator.deeplKey = s.deeplKey;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final r = await widget.translator.translateAll(
        ['Wo ist der Bahnhof, bitte?'], 'de', s.translateTo.isEmpty ? 'fr' : s.translateTo);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = r != null && r.engine == 'DeepL'
          ? 'DeepL fonctionne : « ${r.texts.first} »'
          : (widget.translator.deeplError ?? 'DeepL ne répond pas.');
    });
  }
  late String _voiceLang = widget.voice.code;
  List<TtsEngine> _engines = const [];
  bool _switchingEngine = false;

  @override
  void initState() {
    super.initState();
    SystemBridge.ttsEngines().then((e) {
      if (mounted) setState(() => _engines = e);
    });
    widget.translator.refresh().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Réglages', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            ..._accessibilitySection(theme),
            const Divider(height: 32),
            ..._voiceSection(theme),
            const Divider(height: 32),
            ..._translationSection(theme),
            const Divider(height: 32),
            ..._readingSection(theme),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------- accessibilité

  List<Widget> _accessibilitySection(ThemeData theme) => [
        Text('Accessibilité', style: theme.textTheme.titleMedium),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Mode grands boutons'),
          subtitle: const Text(
              'Pour les personnes qui voient mal : textes et boutons agrandis, bouton '
              '« Répéter », boutons pour déplacer la zone sans glisser, annonces vocales '
              'et vibration à chaque sous-titre. Ces boutons apparaissent aussi avec '
              'TalkBack ou VoiceOver.'),
          value: s.largeMode,
          onChanged: (v) => setState(() => s.largeMode = v),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.onTutorial,
            icon: const Icon(Icons.school_outlined),
            label: const Text('Revoir le tutoriel'),
          ),
        ),
      ];

  // ------------------------------------------------------------------ voix

  List<Widget> _voiceSection(ThemeData theme) {
    final lang = languageFor(_voiceLang);
    final voices = widget.catalog.voicesFor(_voiceLang);
    final labels = widget.catalog.labelsFor(_voiceLang);
    final chosen = s.voiceFor(_voiceLang);
    final chosen2 = s.voice2For(_voiceLang);
    TtsVoice? byKey(String k) => voices.where((v) => v.key == k).firstOrNull;

    List<DropdownMenuItem<String>> items(String autoLabel) => [
          DropdownMenuItem(value: 'auto', child: Text(autoLabel, overflow: TextOverflow.ellipsis)),
          for (final v in voices)
            DropdownMenuItem(
              value: v.key,
              child: Text(labels[v.key] ?? v.name, overflow: TextOverflow.ellipsis),
            ),
        ];

    String current(TtsVoice? v) =>
        v != null && voices.any((x) => x.key == v.key) ? v.key : 'auto';

    final pitch2 = s.pitch2For(_voiceLang);
    return [
      Text('Voix', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      if (Platform.isAndroid && _engines.length > 1) ...[
        DropdownButtonFormField<String>(
          initialValue: _engines.any((e) => e.name == s.ttsEngine) ? s.ttsEngine : '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Moteur de voix'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Celui du téléphone')),
            for (final e in _engines)
              DropdownMenuItem(value: e.name, child: Text(e.label, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: _switchingEngine
              ? null
              : (v) async {
                  setState(() => _switchingEngine = true);
                  await widget.onEngineChanged(v ?? '');
                  if (mounted) setState(() => _switchingEngine = false);
                },
        ),
        if (_switchingEngine)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(),
          ),
        const SizedBox(height: 4),
        Text(
          'Chaque moteur a ses propres voix (Google, Samsung…). Changez de moteur pour en '
          'découvrir d\'autres.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
      ],
      Wrap(spacing: 8, children: [
        for (final l in kLanguages)
          ChoiceChip(
            label: Text(l.label),
            selected: _voiceLang == l.code,
            onSelected: (_) => setState(() => _voiceLang = l.code),
          ),
      ]),
      const SizedBox(height: 12),
      if (voices.isEmpty)
        Text(
          'Aucune voix ${lang.label} trouvée sur ce téléphone. ${_installHint()}',
          style: TextStyle(color: theme.colorScheme.error),
        )
      else ...[
        Text(
          '${voices.length} voix ${lang.label} sur ce téléphone'
          '${voices.where((v) => v.networkRequired).isNotEmpty ? ' (dont ${voices.where((v) => v.networkRequired).length} en ligne, très naturelles)' : ''}.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('v1-$_voiceLang-${current(chosen)}'),
              initialValue: current(chosen),
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Voix principale'),
              items: items('Automatique (la plus naturelle)'),
              onChanged: (k) => setState(
                () => s.setVoiceFor(_voiceLang, k == null || k == 'auto' ? null : byKey(k)),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Écouter',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: () => widget.onPreviewVoice(
                _voiceLang, widget.primaryVoice(_voiceLang), s.pitchFor(_voiceLang)),
          ),
        ]),
        _pitchSlider(
          theme,
          label: 'Hauteur',
          value: s.pitchFor(_voiceLang),
          onChanged: (v) => setState(() => s.setPitchFor(_voiceLang, v)),
          onPreview: () => widget.onPreviewVoice(
              _voiceLang, widget.primaryVoice(_voiceLang), s.pitchFor(_voiceLang)),
        ),
        if (s.dialogueVoices) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('v2-$_voiceLang-${current(chosen2)}'),
                initialValue: current(chosen2),
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Voix du 2e personnage'),
                items: items('Automatique (une autre voix)'),
                onChanged: (k) => setState(
                  () => s.setVoice2For(_voiceLang, k == null || k == 'auto' ? null : byKey(k)),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Écouter',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () {
                final second = widget.secondVoice(_voiceLang);
                widget.onPreviewVoice(_voiceLang, second.voice, second.pitch);
              },
            ),
          ]),
          _pitchSlider(
            theme,
            label: pitch2 == null ? 'Hauteur (automatique)' : 'Hauteur',
            value: widget.secondVoice(_voiceLang).pitch,
            onChanged: (v) => setState(() => s.setPitch2For(_voiceLang, v)),
            onPreview: () {
              final second = widget.secondVoice(_voiceLang);
              widget.onPreviewVoice(_voiceLang, second.voice, second.pitch);
            },
            onReset: pitch2 == null ? null : () => setState(() => s.setPitch2For(_voiceLang, null)),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          Platform.isIOS
              ? 'Pour des voix plus naturelles : Réglages > Accessibilité > Contenu énoncé > '
                  'Voix, puis téléchargez une voix « améliorée » ou « premium ».'
              : "Android n'indique pas si une voix est d'homme ou de femme : écoutez-les "
                  'avec ▶. ${_installHint()}',
          style: theme.textTheme.bodySmall,
        ),
      ],
      if (Platform.isAndroid) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () async {
              final ok = await widget.onInstallVoices();
              if (!ok && mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                  content: Text(_installHint()),
                ));
              }
            },
            icon: const Icon(Icons.download),
            label: const Text('Installer d\'autres voix'),
          ),
        ),
        Text(
          'Ouvre l\'écran du téléphone pour télécharger des voix (plusieurs voix par langue '
          'chez Google). Revenez ensuite dans les réglages de VoxLiso : la liste se met à jour.',
          style: theme.textTheme.bodySmall,
        ),
      ],
      const SizedBox(height: 12),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Une voix par personnage'),
        subtitle: const Text(
            'Dans les dialogues à tirets (« - Oui. » / « - Non. »), la 2e réplique est '
            "lue avec une autre voix, ou plus grave si le téléphone n'a qu'une voix."),
        value: s.dialogueVoices,
        onChanged: (v) => setState(() => s.dialogueVoices = v),
      ),
      const SizedBox(height: 8),
      Text('Vitesse de la voix : x${s.rate.toStringAsFixed(2)}',
          style: theme.textTheme.titleSmall),
      Slider(
        value: s.rate,
        min: 0.5,
        max: 2.0,
        divisions: 15,
        label: 'x${s.rate.toStringAsFixed(2)}',
        onChanged: (v) => setState(() => s.rate = v),
        onChangeEnd: (_) => widget.onVoiceChanged(),
      ),
      if (widget.voiceMissing)
        Text(
          'Voix ${widget.voice.label} absente. ${_installHint()}',
          style: TextStyle(color: theme.colorScheme.error),
        ),
    ];
  }

  Widget _pitchSlider(
    ThemeData theme, {
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    required VoidCallback onPreview,
    VoidCallback? onReset,
  }) {
    final v = value.clamp(0.6, 1.5).toDouble();
    final word = v < 0.9 ? 'grave' : (v > 1.1 ? 'aiguë' : 'normale');
    return Row(children: [
      SizedBox(
        width: 110,
        child: Text('$label : $word', style: theme.textTheme.bodySmall),
      ),
      Expanded(
        child: Slider(
          value: v,
          min: 0.6,
          max: 1.5,
          divisions: 18,
          label: v.toStringAsFixed(2),
          onChanged: onChanged,
          onChangeEnd: (_) => onPreview(),
        ),
      ),
      if (onReset != null)
        IconButton(
          tooltip: 'Hauteur automatique',
          icon: const Icon(Icons.restart_alt),
          onPressed: onReset,
        ),
    ]);
  }

  String _installHint() => Platform.isIOS
      ? 'Ajoutez des voix : Réglages > Accessibilité > Contenu énoncé > Voix.'
      : 'Ajoutez des voix : Paramètres > Accessibilité > Synthèse vocale > ⚙ du moteur '
          'Google > Installer les données vocales.';

  // ------------------------------------------------------------ traduction

  List<Widget> _translationSection(ThemeData theme) {
    final t = widget.translator;
    final target = s.translateTo;
    return [
      Text('Traduction', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: target,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Lire les sous-titres en'),
        items: [
          const DropdownMenuItem(value: '', child: Text('Langue d\'origine (pas de traduction)')),
          for (final l in kLanguages) DropdownMenuItem(value: l.code, child: Text(l.label)),
        ],
        onChanged: (v) => setState(() => s.translateTo = v ?? ''),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: s.autoTranslateTo,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Sous-titres en anglais, portugais… : traduire en',
        ),
        items: [
          for (final l in kLanguages) DropdownMenuItem(value: l.code, child: Text(l.label)),
        ],
        onChanged: (v) => setState(() => s.autoTranslateTo = v ?? 'fr'),
      ),
      const SizedBox(height: 4),
      Text(
        'En mode Auto, VoxLiso reconnaît aussi l\'anglais, le portugais, le néerlandais, '
        'le polonais… et les traduit automatiquement. La langue nécessaire se télécharge '
        'toute seule en Wi-Fi au premier besoin (environ 30 Mo). Avec une clé DeepL, la '
        'traduction est immédiate et de meilleure qualité.',
        style: theme.textTheme.bodySmall,
      ),
      if (target.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          'Les sous-titres dans une autre langue sont traduits en ${languageFor(target).label} '
          'sur le téléphone. Chaque langue se télécharge une seule fois (environ 30 Mo, '
          'Wi-Fi conseillé) : il faut la langue des sous-titres ET la langue de traduction. '
          'Ensuite, tout fonctionne sans internet.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Text('Meilleure qualité avec DeepL (facultatif)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          "La traduction hors ligne est parfois approximative. Avec une clé DeepL "
          "gratuite (« DeepL API Free », 500 000 caractères par mois, à créer sur "
          "deepl.com/pro-api), la traduction se fait en ligne, avec une bien meilleure "
          "qualité. Les sous-titres sont alors envoyés à DeepL. Sans internet, VoxLiso "
          "revient tout seul à la traduction hors ligne.",
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _deepl,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Clé DeepL',
            hintText: 'xxxxxxxx-xxxx-…:fx',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() {
            s.deeplKey = v;
            widget.translator.deeplKey = s.deeplKey;
            _testResult = null;
          }),
        ),
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton.icon(
            onPressed: _testing || _deepl.text.trim().isEmpty ? null : _testDeepl,
            icon: _testing
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check),
            label: const Text('Tester la clé'),
          ),
          const SizedBox(width: 8),
          if (_deepl.text.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                _deepl.clear();
                s.deeplKey = '';
                widget.translator.deeplKey = '';
                _testResult = null;
              }),
              child: const Text('Effacer'),
            ),
        ]),
        if (_testResult != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_testResult!, style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
        Text('Traduction hors ligne : langues téléchargées', style: theme.textTheme.titleSmall),
        for (final l in kLanguages)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l.label),
            subtitle: Text(
              t.isDownloading(l.code)
                  ? 'Téléchargement en cours…'
                  : (t.knownDownloaded(l.code) ?? false)
                      ? 'Téléchargée'
                      : 'Non téléchargée',
            ),
            trailing: t.isDownloading(l.code)
                ? const SizedBox(
                    width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : (t.knownDownloaded(l.code) ?? false)
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : TextButton(
                        onPressed: () => _download(l.code),
                        child: const Text('Télécharger'),
                      ),
          ),
      ],
    ];
  }

  Future<void> _download(String code) async {
    final future = widget.translator.download(code);
    setState(() {});
    final ok = await future;
    if (!mounted) return;
    setState(() {});
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('Téléchargement impossible. Vérifiez la connexion internet et réessayez.'),
      ));
    }
  }

  // --------------------------------------------------------------- lecture

  List<Widget> _readingSection(ThemeData theme) => [
        Text('Lecture', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text('Réactivité', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Rapide')),
              ButtonSegment(value: 1, label: Text('Normale')),
              ButtonSegment(value: 2, label: Text('Stable')),
            ],
            selected: {s.reactivity},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => s.reactivity = v.first),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '« Stable » attend un peu plus avant de lire : moins d\'erreurs si '
          'le téléphone bouge ou si l\'image est floue.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Vue 16:9 (format télé)'),
          subtitle: const Text(
              "Téléphone debout, l'aperçu montre la bande centrale de l'image, au format de "
              "la télé. Désactivé : toute la hauteur de l'image (9:16)."),
          value: s.frame169,
          onChanged: (v) => setState(() => s.frame169 = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Mode photo'),
          subtitle: const Text(
              'Analyse de vraies photos au lieu de la vidéo : plus lent (≈1 s), '
              'mais plus fiable sur certains téléphones. Sur iPhone, un bruit '
              "d'appareil photo peut se faire entendre."),
          value: s.photoMode,
          onChanged: (v) => setState(() => s.photoMode = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Couper la phrase en cours'),
          subtitle: const Text(
              'Quand un nouveau sous-titre apparaît, on passe directement à lui.'),
          value: s.interrupt,
          onChanged: (v) => setState(() => s.interrupt = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ignorer les descriptions sonores'),
          subtitle: const Text('Ne pas lire [Musique], (rires), ♪…'),
          value: s.removeSoundTags,
          onChanged: (v) => setState(() => s.removeSoundTags = v),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () {
            widget.onResetZone();
            setState(() {});
          },
          icon: const Icon(Icons.crop_free),
          label: const Text('Remettre la zone des sous-titres par défaut'),
        ),
        const SizedBox(height: 8),
        Text('VoxLiso version $kAppVersion', style: theme.textTheme.bodySmall),
      ];
}
