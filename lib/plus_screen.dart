import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'logo.dart';
import 'premium.dart';
import 'screen_capture.dart';

/// Ouvre l'écran VoxLiso Plus. [reason] : la fonction que l'utilisateur
/// voulait utiliser (mise en avant en haut de la liste).
Future<void> openPlusScreen(BuildContext context, {PlusFeature? reason}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlusScreen(reason: reason),
    ));

/// Présentation de VoxLiso Plus, achat et restauration.
class PlusScreen extends StatelessWidget {
  const PlusScreen({super.key, this.reason});
  final PlusFeature? reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final features = [
      for (final f in PlusFeature.values)
        if (f != PlusFeature.screen || ScreenCapture.isAvailable) f,
    ];
    if (reason != null && features.remove(reason)) features.insert(0, reason!);
    final store = Platform.isIOS ? 'l\'App Store' : 'Google Play';

    return Scaffold(
      appBar: AppBar(title: const Text('VoxLiso Plus')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: Premium.instance,
          builder: (context, _) {
            final p = Premium.instance;
            final price = p.product?.price;
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Center(child: LogoMark(size: 72)),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    p.unlocked ? 'VoxLiso Plus est activé. Merci !' : 'Passez à VoxLiso Plus',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'La lecture des sous-titres de la télé et de l\'ordinateur reste gratuite. '
                  'VoxLiso Plus ajoute :',
                  style: theme.textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                for (final f in features)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        switch (f) {
                          PlusFeature.translation => Icons.translate,
                          PlusFeature.screen => Icons.smartphone,
                          PlusFeature.blackScreen => Icons.dark_mode,
                          PlusFeature.voices => Icons.record_voice_over,
                        },
                        color: kBrandYellow,
                        size: 32,
                      ),
                      title: Text(f.title, style: theme.textTheme.titleMedium),
                      subtitle: Text(f.description),
                      trailing: p.unlocked ? const Icon(Icons.check_circle, color: Colors.green) : null,
                    ),
                  ),
                const SizedBox(height: 20),
                if (!p.unlocked) ...[
                  SizedBox(
                    height: 64,
                    child: FilledButton.icon(
                      onPressed: p.busy || p.pending || p.product == null ? null : p.buy,
                      icon: p.busy
                          ? const SizedBox(
                              width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3))
                          : const Icon(Icons.lock_open, size: 28),
                      label: Text(
                        price == null ? 'Acheter VoxLiso Plus' : 'Acheter pour $price',
                        style: const TextStyle(fontSize: 20),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Achat unique, sans abonnement. Le paiement passe par $store.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: p.busy ? null : p.restore,
                      icon: const Icon(Icons.restore),
                      label: const Text('Restaurer mes achats'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Déjà acheté sur un autre téléphone ? Utilisez le même compte '
                    '${Platform.isIOS ? 'Apple' : 'Google'} puis touchez « Restaurer mes achats ».',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
                if (p.message != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      p.message!,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Encadré affiché à la place d'une fonction réservée à VoxLiso Plus.
class PlusLockedCard extends StatelessWidget {
  const PlusLockedCard({super.key, required this.feature});
  final PlusFeature feature;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.lock_outline, color: kBrandYellow),
              const SizedBox(width: 8),
              Expanded(child: Text('Avec VoxLiso Plus', style: theme.textTheme.titleSmall)),
            ]),
            const SizedBox(height: 4),
            Text(feature.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => openPlusScreen(context, reason: feature),
              child: const Text('Découvrir VoxLiso Plus'),
            ),
          ],
        ),
      ),
    );
  }
}
