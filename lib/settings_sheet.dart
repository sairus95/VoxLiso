import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'languages.dart';
import 'settings.dart';
import 'system_bridge.dart';
import 'translator.dart';
import 'updater.dart';
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
    required this.onCheckUpdate,
    required this.onUpdate,
    this.update,
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

  /// Nouvelle version déjà trouvée (vérification au démarrage), ou null.
  final UpdateInfo? update;

  /// Recherche une nouvelle version : message à afficher et version trouvée.
  final Future<UpdateCheck> Function() onCheckUpdate;

  /// Télécharge et installe la version trouvée.
  final void Function(UpdateInfo info) onUpdate;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  AppSettings get s => widget.settings;
  late final TextEditingController _deepl = TextEditingController(text: widget.settings.deeplKey);
  late final TextEditingController _azureKey = TextEditingController(text: widget.settings.azureKey);
  late final TextEditingController _azureRegion =
      TextEditingController(text: widget.settings.azureRegion);
  bool _testing = false;
  String? _testResult;
  bool _testingAzure = false;
  String? _azureResult;
  bool _checkingUpdate = false;
  String? _updateResult;
  late UpdateInfo? _update = widget.update;

  @override
  void dispose() {
    widget.translator.onChange = null;
    _deepl.dispose();
    _azureKey.dispose();
    _azureRegion.dispose();
    super.dispose();
  }

  Future<void> _testDeepl() async {
    s.deeplKey = _deepl.text;
    widget.translator.deeplKey = s.effectiveDeeplKey;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final r = await widget.translator
        .testOnline('DeepL', s.translateTo.isEmpty ? 'fr' : s.translateTo);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = r != null
          ? 'DeepL fonctionne : « $r »'
          : (widget.translator.deeplError ?? 'DeepL ne répond pas.');
    });
  }

  void _applyAzure() {
    s.azureKey = _azureKey.text;
    s.azureRegion = _azureRegion.text;
    widget.translator
      ..azureKey = s.effectiveAzureKey
      ..azureRegion = s.effectiveAzureRegion;
  }

  Future<void> _testAzure() async {
    _applyAzure();
    setState(() {
      _testingAzure = true;
      _azureResult = null;
    });
    final r = await widget.translator
        .testOnline('Azure', s.translateTo.isEmpty ? 'fr' : s.translateTo);
    if (!mounted) return;
    setState(() {
      _testingAzure = false;
      _azureResult = r != null
          ? 'Azure fonctionne : « $r »'
          : (widget.translator.azureError ?? 'Azure ne répond pas.');
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
    widget.translator.onChange = () {
      if (mounted) setState(() {});
    };
    widget.translator
        .refresh()
        .then((_) => widget.translator.refreshLanguages([for (final l in _heardLanguages) l.code]))
        .then((_) {
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
            ..._languagesSection(theme),
            const Divider(height: 32),
            ..._voiceSection(theme),
            const Divider(height: 32),
            // Traduction désactivée pour l'instant (kTranslationEnabled).
            if (kTranslationEnabled) ...[
              ..._translationSection(theme),
              const Divider(height: 32),
            ],
            ..._readingSection(theme),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- langues

  /// Langues qu'on entend : lues telles quelles, et langues de traduction.
  List<SubtitleLanguage> get _heardLanguages {
    final read = s.readLanguages;
    return [
      for (final l in kLanguages)
        if (read.contains(l.code) ||
            (kTranslationEnabled && (l.code == s.translateTo || l.code == s.autoTranslateTo)) ||
            l.code == widget.voice.code)
          l,
    ];
  }

  List<Widget> _languagesSection(ThemeData theme) {
    final read = s.readLanguages;
    final script = s.ocrScript;
    return [
      Text('Langues des sous-titres', style: theme.textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        'Sur l\'écran principal, « Auto » reconnaît la langue de chaque sous-titre et le lit '
        'dans sa langue ; l\'autre bouton lit tout dans la langue du téléphone (celle des '
        'réglages d\'Android ou de l\'iPhone).',
        style: theme.textTheme.bodySmall,
      ),
      // Langues lues telles quelles : utile seulement avec la traduction.
      if (kTranslationEnabled) ...[
        const SizedBox(height: 8),
        Text(
          'Cochez les langues à entendre telles quelles. En mode Auto, un sous-titre dans une '
          'autre langue est traduit (voir « Traduction »).',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final l in kLanguages)
            FilterChip(
              label: Text(l.label),
              selected: read.contains(l.code),
              onSelected: (on) => setState(() {
                final next = [
                  for (final x in kLanguages)
                    if (x.code == l.code ? on : read.contains(x.code)) x.code,
                ];
                if (next.isNotEmpty) s.readLanguages = next; // au moins une langue
              }),
            ),
        ]),
      ],
      const SizedBox(height: 12),
      DropdownButtonFormField<SubtitleScript>(
        key: ValueKey('script-${script.name}'),
        initialValue: script,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Écriture des sous-titres'),
        items: [
          for (final sc in SubtitleScript.values)
            DropdownMenuItem(
              value: sc,
              child: Text(switch (sc) {
                SubtitleScript.latin => 'Latine (français, anglais, polonais…)',
                SubtitleScript.chinese => 'Chinoise (中文)',
                SubtitleScript.japanese => 'Japonaise (日本語)',
                SubtitleScript.korean => 'Coréenne (한국어)',
              }),
            ),
        ],
        onChanged: (v) => setState(() => s.ocrScript = v ?? SubtitleScript.latin),
      ),
      const SizedBox(height: 4),
      Text(
        'Choisie toute seule si le téléphone est en chinois, japonais ou coréen. Ces '
        'écritures lisent aussi l\'alphabet latin : choisissez-en une ici pour des '
        'sous-titres en chinois, japonais ou coréen en mode Auto.',
        style: theme.textTheme.bodySmall,
      ),
    ];
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
        for (final l in _heardLanguages)
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
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Vitesse automatique'),
        subtitle: const Text(
            'La voix accélère un peu (+40 %, jusqu\'à +80 % si elle décroche) quand les sous-titres défilent vite, '
            'pour ne pas prendre de retard, puis revient à la vitesse choisie.'),
        value: s.autoRate,
        onChanged: (v) => setState(() => s.autoRate = v),
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
          labelText: 'Sous-titres dans une langue non cochée : traduire en',
        ),
        items: [
          for (final l in kLanguages) DropdownMenuItem(value: l.code, child: Text(l.label)),
        ],
        onChanged: (v) => setState(() => s.autoTranslateTo = v ?? 'fr'),
      ),
      const SizedBox(height: 4),
      Text(
        'En mode Auto, un sous-titre dans une langue non cochée dans « Langues des '
        'sous-titres » (ou en slovène, vietnamien, indonésien…) est traduit automatiquement. '
        '${_phoneHint(t)}',
        style: theme.textTheme.bodySmall,
      ),
      if (target.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          'Les sous-titres dans une autre langue sont traduits en ${languageFor(target).label} '
          'sur le téléphone. ${_phoneHint(t)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Text(
            t.phoneLabel != null
                ? 'Traducteur du téléphone : langues téléchargées'
                : 'Traduction hors ligne : langues téléchargées',
            style: theme.textTheme.titleSmall),
        for (final l in kLanguages)
          if (_heardLanguages.contains(l) ||
              t.isDownloading(l.code) ||
              (t.knownDownloaded(l.code) ?? false))
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l.label),
            subtitle: Text(
              l.code == 'en' && t.phoneLabel == 'Firefox'
                  ? 'Toujours disponible (langue de passage)'
                  : t.isDownloading(l.code)
                      ? 'Téléchargement en cours…'
                          '${t.downloadProgress(l.code) != null ? ' ${(t.downloadProgress(l.code)! * 100).round()} %' : ''}'
                      : (t.knownDownloaded(l.code) ?? false)
                          ? 'Téléchargée'
                          : 'Non téléchargée',
            ),
            trailing: t.isDownloading(l.code)
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, value: t.downloadProgress(l.code)))
                : (t.knownDownloaded(l.code) ?? false)
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.check_circle, color: Colors.green),
                        if (t.canDelete && l.code != 'en')
                          IconButton(
                            tooltip: 'Supprimer ${l.label}',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(l.code),
                          ),
                      ])
                    : TextButton(
                        onPressed: () => _download(l.code),
                        child: const Text('Télécharger'),
                      ),
          ),
        if (Platform.isIOS && t.phoneLabel != null)
          Text(
            'Pour supprimer une langue : Réglages de l\'iPhone > Apps > Traduire > Langues téléchargées.',
            style: theme.textTheme.bodySmall,
          ),
        const SizedBox(height: 8),
        // DeepL et Azure : passent en premier s'il y a une clé ; repliés (le
        // traducteur du téléphone prend le relais sans réseau ou quota épuisé).
        Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            initiallyExpanded: _deepl.text.isNotEmpty || _azureKey.text.isNotEmpty,
            title: const Text('Traduction en ligne (facultatif)'),
            subtitle: Text(
              t.phoneLabel != null
                  ? 'Avec une clé, DeepL (puis Azure) traduit en premier : traductions plus '
                      'naturelles. Sans réseau ou une fois le quota épuisé, le traducteur du '
                      'téléphone prend le relais, sans clé ni limite.'
                  : 'Clés DeepL ou Azure : traduction en ligne de meilleure qualité.',
              style: theme.textTheme.bodySmall,
            ),
            children: [
            Text('Traduction en ligne gratuite chaque mois : Microsoft Azure (facultatif)',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              "Avec une clé Microsoft Azure Translator (palier gratuit « F0 » : 2 millions de "
              "caractères par mois, une trentaine de films, renouvelés chaque mois), la "
              "traduction se fait en ligne. À créer sur "
              "portal.azure.com : ressource « Translator », palier F0, région « Global ». "
              "Azure passe après DeepL et avant le traducteur du téléphone. Les "
              "sous-titres sont alors envoyés à Microsoft.",
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _azureKey,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Clé Azure',
                border: const OutlineInputBorder(),
                helperText: AppSettings.builtInAzureKey.isNotEmpty && _azureKey.text.trim().isEmpty
                    ? 'Clé intégrée à l\'application utilisée. Collez une autre clé pour la remplacer.'
                    : null,
                helperMaxLines: 2,
              ),
              onChanged: (v) => setState(() {
                _applyAzure();
                _azureResult = null;
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _azureRegion,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Région Azure',
                hintText: 'global, westeurope, francecentral…',
                helperText: 'Laissez vide pour une ressource « Global ».',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() {
                _applyAzure();
                _azureResult = null;
              }),
            ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _testingAzure ||
                        (_azureKey.text.trim().isEmpty && AppSettings.builtInAzureKey.isEmpty)
                    ? null
                    : _testAzure,
                icon: _testingAzure
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: const Text('Tester Azure'),
              ),
              const SizedBox(width: 8),
              if (_azureKey.text.isNotEmpty || _azureRegion.text.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    _azureKey.clear();
                    _azureRegion.clear();
                    _applyAzure();
                    _azureResult = null;
                  }),
                  child: const Text('Effacer'),
                ),
            ]),
            if (_azureResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_azureResult!, style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: 16),
            Text('Meilleure qualité avec DeepL (facultatif)', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              "Avec une clé DeepL (formule gratuite « API Developer » sur deepl.com/pro-api : "
              "1 million de caractères au total, une quinzaine de films), la traduction se "
              "fait en ligne, en premier : ce sont les traductions les plus naturelles. Les "
              "sous-titres sont alors envoyés à DeepL. Une fois le quota épuisé, ou sans "
              "internet, VoxLiso passe tout seul au traducteur du téléphone (ses langues "
              "se téléchargent en Wi-Fi en attendant).",
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _deepl,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Clé DeepL',
                hintText: 'xxxxxxxx-xxxx-…:fx',
                border: const OutlineInputBorder(),
                helperText: AppSettings.builtInDeeplKey.isNotEmpty && _deepl.text.trim().isEmpty
                    ? 'Clé intégrée à l\'application utilisée. Collez une autre clé pour la remplacer.'
                    : null,
                helperMaxLines: 2,
              ),
              onChanged: (v) => setState(() {
                s.deeplKey = v;
                widget.translator.deeplKey = s.effectiveDeeplKey;
                _testResult = null;
              }),
            ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _testing ||
                        (_deepl.text.trim().isEmpty && AppSettings.builtInDeeplKey.isEmpty)
                    ? null
                    : _testDeepl,
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
                    widget.translator.deeplKey = s.effectiveDeeplKey;
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
            ],
          ),
        ),
      ],
    ];
  }

  /// Explication du téléchargement des langues, selon le traducteur.
  String _phoneHint(SubtitleTranslator t) => switch (t.phoneLabel) {
        'Firefox' => 'Traduction sur le téléphone avec le traducteur de Firefox : gratuite, '
            'sans limite et sans internet. Chaque langue se télécharge une fois (environ '
            '35 Mo par sens), toute seule en Wi-Fi au premier besoin ou avec le bouton '
            'ci-dessous. La traduction passe par l\'anglais (allemand → anglais → français).',
        'Apple' => 'Traduction sur l\'iPhone avec le traducteur d\'Apple : gratuite, sans '
            'limite et sans internet. Touchez « Télécharger » ci-dessous : iOS demande '
            'de confirmer le téléchargement de la langue.',
        _ => 'La langue nécessaire se télécharge toute seule en Wi-Fi au premier besoin '
            '(environ 30 Mo). Il faut la langue des sous-titres ET la langue de traduction.',
      };

  Future<void> _delete(String code) async {
    await widget.translator.delete(code);
    if (mounted) setState(() {});
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
          title: const Text('Sous-titres en haut de l\'image'),
          subtitle: const Text(
              'Quand rien n\'est lu dans la zone, VoxLiso lit aussi la même bande de l\'autre '
              'côté de l\'image (cadre en pointillés) : sous-titres placés en haut quand le bas '
              'est pris par un texte, un nom ou un générique. En mode écran : en plein écran.'),
          value: s.topSubtitles,
          onChanged: (v) => setState(() => s.topSubtitles = v),
        ),
        if (Platform.isAndroid)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Bips pour cadrer la télé'),
            subtitle: const Text(
                'Avant la lecture, un bip quand du texte est dans la zone jaune : plus il est '
                'aigu, mieux le texte est lisible. Pour viser la télé sans regarder l\'écran.'),
            value: s.aimBeeps,
            onChanged: (v) => setState(() => s.aimBeeps = v),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Lecture renforcée'),
          subtitle: const Text(
              'Pendant la lecture, chaque image est relue une 2e fois sur la zone recadrée, '
              'contrastée et agrandie (sous-titres jaunes ou à contour, télé lointaine, '
              'reflets), et les deux lectures sont comparées mot à mot pour garder la bonne. '
              'Consomme un peu plus de batterie.'),
          value: s.enhance,
          onChanged: (v) => setState(() => s.enhance = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Corriger les erreurs de lecture'),
          subtitle: const Text(
              'Les mots mal lus sont corrigés avec un dictionnaire de la langue avant d\'être '
              'dits. Listes de mots : FrequencyWords (Hermit Dave), corpus OpenSubtitles, '
              'licence CC BY-SA 4.0.'),
          value: s.spellFix,
          onChanged: (v) => setState(() => s.spellFix = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ignorer le texte fixe'),
          subtitle: const Text(
              'Un texte qui ne change pas pendant plus de 20 secondes (logo de la chaîne, '
              'heure, titre d\'un menu) n\'est pas lu. Il est encadré en gris.'),
          value: s.ignoreStatic,
          onChanged: (v) => setState(() => s.ignoreStatic = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Seulement les sous-titres'),
          subtitle: const Text(
              'Les menus, les panneaux et enseignes de l\'image, les bandeaux, l\'heure et '
              'les adresses web ne sont pas lus. VoxLiso apprend la taille et la place des '
              'sous-titres sur les premiers qu\'il lit. Ce qui est écarté est encadré en gris.'),
          value: s.subtitlesOnly,
          onChanged: (v) => setState(() => s.subtitlesOnly = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Écran noir pendant la lecture'),
          subtitle: const Text(
              'En option : pendant la lecture, après 8 secondes sans toucher l\'écran, il passe '
              'au noir pour ne pas gêner dans le noir et économiser la batterie. '
              'Touchez-le pour le rallumer.'),
          value: s.blackScreen,
          onChanged: (v) => setState(() => s.blackScreen = v),
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
        if (Platform.isAndroid)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Voix seulement dans les écouteurs'),
            subtitle: const Text(
                'Sans écouteurs (Bluetooth ou à fil) connectés, la voix reste coupée, pour ne '
                'pas gêner les autres. S\'ils se déconnectent pendant le film, la voix '
                's\'arrête aussitôt au lieu de passer sur le haut-parleur.'),
            value: s.headphonesOnly,
            onChanged: (v) => setState(() => s.headphonesOnly = v),
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
        if (Updater.supported) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _checkingUpdate
                  ? null
                  : () async {
                      setState(() {
                        _checkingUpdate = true;
                        _updateResult = null;
                      });
                      final r = await widget.onCheckUpdate();
                      if (mounted) {
                        setState(() {
                          _checkingUpdate = false;
                          _updateResult = r.message;
                          _update = r.update;
                        });
                      }
                    },
              icon: _checkingUpdate
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.system_update),
              label: const Text('Rechercher une mise à jour'),
            ),
          ),
          if (_updateResult != null)
            Text(_updateResult!, style: theme.textTheme.bodySmall)
          else if (_update != null)
            Text('Version ${_update!.version} disponible.', style: theme.textTheme.bodySmall),
          if (_update != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () => widget.onUpdate(_update!),
                icon: const Icon(Icons.download),
                label: Text('Mettre à jour vers la ${_update!.version}'),
              ),
            ),
          ],
        ],
      ];
}
