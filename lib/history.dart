import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'languages.dart';

/// Un sous-titre lu.
class HistoryEntry {
  HistoryEntry({
    required this.time,
    required this.text,
    required this.lang,
    this.original = '',
    this.originalLang = '',
  });

  final DateTime time;

  /// Texte dit (traduit le cas échéant).
  final String text;

  /// Langue du texte dit (fr, de, es, it).
  final String lang;

  /// Texte d'origine si [text] est une traduction.
  final String original;
  final String originalLang;

  Map<String, dynamic> toJson() => {
        't': time.millisecondsSinceEpoch,
        'x': text,
        'l': lang,
        if (original.isNotEmpty) 'o': original,
        if (originalLang.isNotEmpty) 'ol': originalLang,
      };

  static HistoryEntry? fromJson(Object? m) {
    if (m is! Map) return null;
    try {
      return HistoryEntry(
        time: DateTime.fromMillisecondsSinceEpoch(m['t'] as int),
        text: m['x'] as String,
        lang: m['l'] as String,
        original: (m['o'] ?? '') as String,
        originalLang: (m['ol'] ?? '') as String,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Les derniers sous-titres lus (les plus récents à la fin).
class SubtitleHistory {
  static const int maxEntries = 300;
  static const int savedEntries = 150;

  final List<HistoryEntry> entries = [];

  HistoryEntry? get last => entries.isEmpty ? null : entries.last;

  void add(HistoryEntry e) {
    entries.add(e);
    if (entries.length > maxEntries) entries.removeRange(0, entries.length - maxEntries);
  }

  void clear() => entries.clear();

  String encode() {
    final start = entries.length > savedEntries ? entries.length - savedEntries : 0;
    return jsonEncode([for (final e in entries.sublist(start)) e.toJson()]);
  }

  void decode(String? json) {
    entries.clear();
    if (json == null || json.isEmpty) return;
    try {
      final list = jsonDecode(json);
      if (list is List) {
        for (final m in list) {
          final e = HistoryEntry.fromJson(m);
          if (e != null) entries.add(e);
        }
      }
    } catch (_) {}
  }
}

/// Écran de l'historique : réécouter ou copier une phrase manquée.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.history,
    required this.onReplay,
    required this.onChanged,
    this.large = false,
  });

  final SubtitleHistory history;
  final void Function(HistoryEntry e) onReplay;

  /// Appelé après un effacement, pour sauvegarder.
  final VoidCallback onChanged;
  final bool large;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Effacer l'historique ?"),
        content: const Text('Tous les sous-titres enregistrés seront supprimés.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Effacer')),
        ],
      ),
    );
    if (ok == true) {
      setState(widget.history.clear);
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = widget.history.entries.reversed.toList();
    final textStyle = widget.large ? theme.textTheme.headlineSmall : theme.textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historique'),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              tooltip: "Effacer l'historique",
              icon: const Icon(Icons.delete_outline),
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Les sous-titres lus apparaîtront ici.\nTouchez-en un pour le réentendre.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = items[i];
                final lang = languageName(e.lang);
                return Semantics(
                  button: true,
                  label: 'À ${_time(e.time)}, en $lang : ${e.text}. Touchez pour réentendre.',
                  excludeSemantics: true,
                  child: ListTile(
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 16, vertical: widget.large ? 12 : 4),
                    title: Text(e.text, style: textStyle),
                    subtitle: Text(
                      [
                        '${_time(e.time)} · $lang',
                        if (e.original.isNotEmpty)
                          'Original (${languageName(e.originalLang)}) : ${e.original}',
                      ].join('\n'),
                    ),
                    trailing: IconButton(
                      tooltip: 'Copier',
                      icon: const Icon(Icons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: e.text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Texte copié')),
                        );
                      },
                    ),
                    onTap: () => widget.onReplay(e),
                  ),
                );
              },
            ),
    );
  }
}
