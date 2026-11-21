import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'languages.dart';
import 'settings.dart';
import 'translator.dart';
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
    required this.onPreviewVoice,
    required this.onResetZone,
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

  /// Fait entendre une phrase d'exemple avec une voix et une hauteur.
  final void Function(String lang, TtsVoice? voice, double pitch) onPreviewVoice;
  final VoidCallback onResetZone;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  AppSettings get s => widget.settings;
  late String _voiceLang = widget.voice.code;

  @override
  void initState() {
    super.initState();
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

    return [
      Text('Voix', style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
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
                _voiceLang, widget.primaryVoice(_voiceLang), 1.0),
          ),
        ]),
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
      if (target.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          'Les sous-titres dans une autre langue sont traduits en ${languageFor(target).label} '
          'sur le téléphone. Chaque langue se télécharge une seule fois (environ 30 Mo, '
          'Wi-Fi conseillé) : il faut la langue des sous-titres ET la langue de traduction. '
          'Ensuite, tout fonctionne sans internet.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
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
      ];
}
