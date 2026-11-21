import 'package:flutter_test/flutter_test.dart';
import 'package:voxliso/language_detector.dart';
import 'package:voxliso/subtitle_tracker.dart';
import 'package:voxliso/text_tools.dart';
import 'package:voxliso/voices.dart';

void main() {
  group('cleanSubtitle', () {
    test('retire les descriptions sonores et les symboles', () {
      expect(cleanSubtitle(['♪ [Musique] ♪', 'Bonjour à tous']), 'Bonjour à tous');
      expect(cleanSubtitle(['(rires) Très drôle !']), 'Très drôle !');
    });

    test('sépare les répliques de dialogue', () {
      expect(cleanSubtitle(['- Tu viens ?', '- Non']), 'Tu viens ? Non.');
      expect(subtitleParts(['- Tu viens ?', '- Non']), ['Tu viens ?', 'Non.']);
    });

    test('répliques sur une seule ligne', () {
      expect(subtitleParts(['- ¿Vienes? - No, gracias.']), ['¿Vienes?', 'No, gracias.']);
    });

    test('une phrase sur deux lignes reste une seule réplique', () {
      expect(subtitleParts(['Ich habe keine Zeit,', 'weil ich arbeiten muss.']),
          ['Ich habe keine Zeit, weil ich arbeiten muss.']);
    });

    test('un tiret dans une phrase ne coupe pas la réplique', () {
      expect(subtitleParts(['Il est peut-être là - ou pas.']), ['Il est peut-être là - ou pas.']);
    });

    test('joint les lignes d\'une même phrase', () {
      expect(cleanSubtitle(['Ich habe keine Zeit,', 'weil ich arbeiten muss.']),
          'Ich habe keine Zeit, weil ich arbeiten muss.');
    });

    test('écarte le bruit de l\'OCR', () {
      expect(cleanSubtitle(['= : ~ 1 2', '¿Dónde está?']), '¿Dónde está?');
    });
  });

  group('SubtitleTracker', () {
    test('lit une seule fois un sous-titre qui reste affiché', () {
      final t = SubtitleTracker(stableFrames: 2);
      final said = <String>[];
      for (final r in ['Ciao, come stai?', 'Ciao, come stai?', 'Ciao, come stai ?', 'Ciao, corne stai?']) {
        final s = t.push(r);
        if (s != null) said.add(s);
      }
      expect(said, ['Ciao, come stai?']);
    });

    test('attend une lecture stable', () {
      final t = SubtitleTracker(stableFrames: 2);
      expect(t.push('Bonjour'), isNull);
      expect(t.push('Bonjour'), 'Bonjour');
    });

    test('lit le sous-titre suivant', () {
      final t = SubtitleTracker(stableFrames: 2);
      final said = <String>[];
      for (final r in ['Où vas-tu ?', 'Où vas-tu ?', '', 'Je rentre chez moi.', 'Je rentre chez moi.']) {
        final s = t.push(r);
        if (s != null) said.add(s);
      }
      expect(said, ['Où vas-tu ?', 'Je rentre chez moi.']);
    });

    test('sous-titres en direct : ne lit que la partie nouvelle', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Le gouvernement a annoncé'), 'Le gouvernement a annoncé');
      expect(t.push('Le gouvernement a annoncé ce matin une réforme'), 'ce matin une réforme');
      expect(t.push('ce matin une réforme des retraites'), 'des retraites');
    });
  });

  group('LanguageDecision', () {
    test('change tout de suite sur un texte long et sûr', () {
      final d = LanguageDecision('fr');
      expect(d.update('Ich habe heute keine Zeit für dich.', {'de': 0.95}), 'de');
    });

    test('ignore les sous-titres trop courts', () {
      final d = LanguageDecision('fr');
      expect(d.update('Ja.', {'de': 0.99}), 'fr');
    });

    test('ignore les langues non prises en charge', () {
      final d = LanguageDecision('it');
      expect(d.update('This is an English sentence here.', {'en': 0.98}), 'it');
    });

    test('identification moyenne : il faut deux sous-titres de suite', () {
      final d = LanguageDecision('fr');
      expect(d.update('Vamos a la playa', {'es': 0.55}), 'fr');
      expect(d.update('Dónde está mi casa', {'es': 0.6}), 'es');
    });

    test('accepte les codes régionaux', () {
      final d = LanguageDecision('fr');
      expect(d.update('Questa è una frase italiana lunga.', {'it-IT': 0.9}), 'it');
    });
  });

  group('VoiceCatalog', () {
    VoiceCatalog catalog() => VoiceCatalog()
      ..load([
        {'name': 'fr-ca-x-cab-local', 'locale': 'fr-CA', 'quality': 'very high', 'network_required': '0', 'features': ''},
        {'name': 'fr-fr-x-frc-local', 'locale': 'fr-FR', 'quality': 'high', 'network_required': '0', 'features': ''},
        {'name': 'fr-fr-x-frd-local', 'locale': 'fr-FR', 'quality': 'very high', 'network_required': '0', 'features': ''},
        {'name': 'fr-fr-x-fre-network', 'locale': 'fr-FR', 'quality': 'very high', 'network_required': '1', 'features': ''},
        {'name': 'de-de-x-deb-local', 'locale': 'de-DE', 'quality': 'normal', 'network_required': '0', 'features': 'notInstalled'},
        {'name': 'Amélie', 'locale': 'fr-FR', 'quality': 'enhanced', 'gender': 'female', 'identifier': 'a'},
        {'name': 'Thomas', 'locale': 'fr-FR', 'quality': 'default', 'gender': 'male', 'identifier': 't'},
      ]);

    test('meilleure voix : hors ligne, accent de France, puis qualité', () {
      expect(catalog().best('fr')!.name, 'fr-fr-x-frd-local');
    });

    test('voix non installée ou en ligne écartée du choix automatique', () {
      expect(catalog().best('de'), isNull);
    });

    test('2e personnage : genre opposé quand il est connu', () {
      final c = catalog();
      final amelie = c.voicesFor('fr').firstWhere((v) => v.name == 'Amélie');
      expect(c.secondVoice('fr', amelie)!.name, 'Thomas');
    });

    test('2e personnage : une autre voix de la même région sinon', () {
      final c = catalog();
      final second = c.secondVoice('fr', c.best('fr'));
      expect(second!.key, isNot(c.best('fr')!.key));
      expect(second.locale, 'fr-FR');
    });

    test('libellés lisibles', () {
      final labels = catalog().labelsFor('fr');
      expect(labels['fr-fr-x-frd-local|fr-FR'], startsWith('Voix 1'));
      expect(labels['Amélie|fr-FR'], contains('Femme'));
      expect(labels['fr-fr-x-fre-network|fr-FR'], contains('internet'));
    });
  });
}
