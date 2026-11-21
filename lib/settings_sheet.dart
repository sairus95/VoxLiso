import 'package:flutter/material.dart';

import 'languages.dart';
import 'settings.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.settings,
    required this.voiceMissing,
    required this.onVoiceChanged,
    required this.onTestVoice,
    required this.onResetZone,
  });

  final AppSettings settings;
  final bool voiceMissing;
  final Future<void> Function() onVoiceChanged;
  final VoidCallback onTestVoice;
  final VoidCallback onResetZone;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  AppSettings get s => widget.settings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lang = languageFor(s.lang);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Réglages', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),

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
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: widget.onTestVoice,
                icon: const Icon(Icons.volume_up),
                label: Text('Tester la voix (${lang.label})'),
              ),
            ),
            if (widget.voiceMissing)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Voix ${lang.label} absente. Android : Paramètres > Accessibilité > '
                  'Synthèse vocale > Installer les données vocales. '
                  'iPhone : Réglages > Accessibilité > Contenu énoncé > Voix.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            const Divider(height: 32),

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
            const Divider(height: 32),

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
          ],
        ),
      ),
    );
  }
}
