import 'package:flutter_test/flutter_test.dart';
import 'package:voxliso/history.dart';
import 'package:voxliso/language_detector.dart';
import 'package:voxliso/aim_beep.dart';
import 'package:voxliso/zone_profiles.dart';
import 'package:voxliso/languages.dart';
import 'dart:ui' show Rect;

import 'package:voxliso/punctuation.dart';
import 'package:voxliso/rate_pacer.dart';
import 'package:voxliso/reading_vote.dart';
import 'package:voxliso/sentence_joiner.dart';
import 'package:voxliso/speech_service.dart';
import 'package:voxliso/speech_text.dart';
import 'package:voxliso/spell_fixer.dart';
import 'package:voxliso/static_filter.dart';
import 'package:voxliso/subtitle_locator.dart';
import 'package:voxliso/subtitle_style.dart';
import 'package:voxliso/subtitle_tracker.dart';
import 'package:voxliso/updater.dart';
import 'package:voxliso/text_tools.dart';
import 'package:voxliso/translator.dart';
import 'package:voxliso/version.dart';
import 'package:voxliso/voices.dart';
import 'package:voxliso/word_learner.dart';
import 'package:voxliso/zones.dart';

void main() {
  group('cleanSubtitle', () {
    test('retire les descriptions sonores et les symboles', () {
      expect(cleanSubtitle(['♪ [Musique] ♪', 'Bonjour à tous']), 'Bonjour à tous');
      expect(cleanSubtitle(['(rires) Très drôle !']), 'Très drôle !');
    });

    test('sépare les répliques de dialogue', () {
      expect(cleanSubtitle(['- Tu viens ?', '- Non']), 'Tu viens ? Non');
      expect(subtitleParts(['- Tu viens ?', '- Non']), ['Tu viens ?', 'Non']);
      expect(subtitleParts(['- Oui', '- Non']), ['Oui.', 'Non']);
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

    test('prépare le texte pour la traduction', () {
      expect(prepareForTranslation('...et puis il est parti'), 'et puis il est parti');
      expect(prepareForTranslation('Je pense que…'), 'Je pense que');
      expect(prepareForTranslation('Pourquoi ?'), 'Pourquoi ?');
      expect(prepareForTranslation('...'), '...');
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
      expect(d.update('Đây là một câu tiếng Việt khá dài.', {'vi': 0.98}), 'it');
    });

    test('lit le néerlandais directement', () {
      final d = LanguageDecision('fr');
      expect(d.update('Dit is een Nederlandse zin hier.', {'nl': 0.98}), 'nl');
    });

    test('reconnaît un court sous-titre chinois', () {
      final d = LanguageDecision('fr');
      expect(d.update('你在做什么？', {'zh': 0.95}), 'zh');
    });

    test('lit l\'anglais directement', () {
      final d = LanguageDecision('fr');
      expect(d.update('This is an English sentence here.', {'en': 0.98}), 'en');
    });

    test('lit le portugais directement', () {
      final d = LanguageDecision('fr');
      expect(d.update('Esta é uma frase em português.', {'pt': 0.98}), 'pt');
    });

    test('reconnaît une autre langue à traduire (vietnamien)', () {
      final d = LanguageDecision('fr', accept: (c) => kOtherLanguages.containsKey(c));
      expect(d.update('Đây là một câu tiếng Việt khá dài.', {'vi': 0.98}), 'vi');
      expect(d.update('Où est la gare, s\'il vous plaît ?', {'fr': 0.97}), 'fr');
    });

    test('ignore « und » (langue indéterminée)', () {
      final d = LanguageDecision('de', accept: (c) => true);
      expect(d.update('xxxx yyyy zzzz wwww', {'und': 1.0}), 'de');
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

    test('japonais ou chinois « en lettres latines » : jamais pour un texte latin', () {
      final d = LanguageDecision('fr');
      expect(d.update('Allez, viens vite !', {'ja-Latn': 0.9}), 'fr');
      expect(d.update('Allez, viens vite !', {'ja-Latn': 0.9}), 'fr');
      expect(d.update('Ah, mais oui, oui !', {'ja': 0.95, 'zh-Latn': 0.9}), 'fr');
      expect(d.update('Ah, mais oui, oui !', {'ja': 0.95}), 'fr');
      expect(d.update('Ah, mais oui, oui !', {'ja': 0.95}), 'fr');
    });

    test('discussion rapide : deux répliques courtes ne suffisent plus à changer', () {
      final d = LanguageDecision('fr');
      expect(d.update('Allez viens', {'es': 0.6}), 'fr');
      expect(d.update('Allez viens', {'es': 0.6}), 'fr');
      expect(d.update('Allez viens', {'es': 0.6}), 'es');
    });
  });

  group('Lectures en miettes', () {
    test('lettres seules à la suite ou éparpillées', () {
      expect(looksFragmented('J e n e s a i s'), isTrue);
      expect(looksFragmented('Je s ais p as'), isTrue);
      expect(looksFragmented('Il y a un problème.'), isFalse);
      expect(looksFragmented('J. R. R. Tolkien'), isFalse);
      expect(looksFragmented("L' homme est là."), isFalse);
      expect(looksFragmented('你 好 吗'), isFalse);
      expect(looksFragmented('Oui.'), isFalse);
    });
    test('image en miettes ignorée, le vrai sous-titre est dit', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('J e n e'), isNull);
      expect(t.push('Je ne sais pas.'), 'Je ne sais pas.');
    });
    test('toujours pareille 3 images de suite : lue quand même', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('N o n m e r c i'), isNull);
      expect(t.push('N o n m e r c i'), isNull);
      expect(t.push('N o n m e r c i'), isNotNull);
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

  group('SubtitleHistory', () {
    test('sauvegarde et relit les entrées, traduction comprise', () {
      final h = SubtitleHistory()
        ..add(HistoryEntry(time: DateTime(2026, 11, 21, 20, 30), text: 'Bonjour', lang: 'fr'))
        ..add(HistoryEntry(
            time: DateTime(2026, 11, 21, 20, 31),
            text: 'Où est la gare ?',
            lang: 'fr',
            original: 'Wo ist der Bahnhof?',
            originalLang: 'de'));
      final copy = SubtitleHistory()..decode(h.encode());
      expect(copy.entries.length, 2);
      expect(copy.last!.original, 'Wo ist der Bahnhof?');
      expect(copy.last!.originalLang, 'de');
      expect(copy.entries.first.time, DateTime(2026, 11, 21, 20, 30));
    });

    test('garde un nombre limité de phrases', () {
      final h = SubtitleHistory();
      for (var i = 0; i < SubtitleHistory.maxEntries + 20; i++) {
        h.add(HistoryEntry(time: DateTime(2026), text: 'Phrase $i', lang: 'fr'));
      }
      expect(h.entries.length, SubtitleHistory.maxEntries);
      expect(h.last!.text, 'Phrase ${SubtitleHistory.maxEntries + 19}');
      final saved = SubtitleHistory()..decode(h.encode());
      expect(saved.entries.length, SubtitleHistory.savedEntries);
    });

    test('données abîmées : historique vide, sans plantage', () {
      final h = SubtitleHistory()..decode('pas du json');
      expect(h.entries, isEmpty);
    });
  });

  group('StaticTextFilter', () {
    test('ignore un texte resté identique plus de 20 s', () {
      var now = DateTime(2026, 11, 22, 20, 0, 0);
      final f = StaticTextFilter(clock: () => now);
      for (var i = 0; i < 25; i++) {
        final fixed = f.update(['FRANCE 2', 'Bonjour à tous']);
        if (i < 20) expect(fixed, isEmpty, reason: 'seconde $i');
        now = now.add(const Duration(seconds: 1));
      }
      // Les sous-titres changent : seule la ligne fixe est ignorée.
      expect(f.update(['FRANCE 2', 'Une nouvelle phrase']), {0});
    });

    test('un sous-titre affiché quelques secondes n\'est jamais fixe', () {
      var now = DateTime(2026, 11, 22, 20, 0, 0);
      final f = StaticTextFilter(clock: () => now);
      for (var i = 0; i < 8; i++) {
        expect(f.update(['Je reviens dans cinq minutes.']), isEmpty);
        now = now.add(const Duration(seconds: 1));
      }
    });

    test('tolère une lecture ratée, pas une longue absence', () {
      var now = DateTime(2026, 11, 22, 20, 0, 0);
      final f = StaticTextFilter(clock: () => now);
      for (var i = 0; i < 15; i++) {
        f.update(['LIVE']);
        now = now.add(const Duration(seconds: 1));
      }
      now = now.add(const Duration(seconds: 2)); // image floue : 2 s sans le texte
      for (var i = 0; i < 5; i++) {
        f.update(['LIVE']);
        now = now.add(const Duration(seconds: 1));
      }
      expect(f.update(['LIVE']), {0});
      now = now.add(const Duration(seconds: 10)); // disparu longtemps : on oublie
      expect(f.update(['LIVE']), isEmpty);
    });

    test('petites erreurs de lecture : même texte fixe', () {
      var now = DateTime(2026, 11, 22, 20, 0, 0);
      final f = StaticTextFilter(clock: () => now);
      for (var i = 0; i < 22; i++) {
        f.update([i.isEven ? 'Le Journal de 20h' : 'Le Journa1 de 20h']);
        now = now.add(const Duration(seconds: 1));
      }
      expect(f.update(['Le Journal de 20h']), {0});
    });
  });

  group('Updater', () {
    test('textes de progression du téléchargement', () {
      expect(Updater.progressText(null), 'Téléchargement…');
      expect(Updater.progressText(0.426), 'Téléchargement : 43 %');
      expect(Updater.pausedText(2), 'En attente du réseau…');
      expect(Updater.pausedText(3), 'En attente du Wi-Fi…');
      expect(Updater.pausedText(99), 'En pause…');
    });
    test('compare les numéros de version', () {
      expect(Updater.isNewer('v1.0.27', '1.0.26'), isTrue);
      expect(Updater.isNewer('v1.0.26', '1.0.26'), isFalse);
      expect(Updater.isNewer('v1.0.9', '1.0.10'), isFalse);
      expect(Updater.isNewer('v1.1.0', '1.0.99'), isTrue);
      expect(Updater.isNewer('v1.0.27', 'dev'), isFalse);
      expect(Updater.parseVersion('v2.3.4'), [2, 3, 4]);
    });
  });

  group('SpellFixer', () {
    final en = WordList.fromWords(['you', 'the', 'come', 'here', 'home', 'modern', 'corn', 'will']);
    final fr = WordList.fromWords(['je', 'la', 'école', 'maison', 'journal', 'demain', 'de', 'à']);

    test('confusions typiques de la lecture', () {
      expect(SpellFixer.fix('Please corne here.', en), 'Please come here.');
      expect(SpellFixer.fix('a rnodern home', en), 'a modern home');
      expect(SpellFixer.fix('Le Journa1 de demain', fr), 'Le Journal de demain');
      expect(SpellFixer.fix('la rnaison', fr), 'la maison');
    });

    test('accents oubliés', () {
      expect(SpellFixer.fix('Je vais à l\'ecole demain.', fr), 'Je vais à l\'école demain.');
    });

    test('ne touche ni aux mots connus, ni aux noms propres, ni aux nombres', () {
      expect(SpellFixer.fix('You will come home.', en), 'You will come home.');
      expect(SpellFixer.fix('Ask Jarvis to come.', en), 'Ask Jarvis to come.');
      expect(SpellFixer.fix('Rendez-vous à 20h30.', fr), 'Rendez-vous à 20h30.');
    });

    test('garde les majuscules', () {
      expect(SpellFixer.fix('CORNE HERE', en), 'COME HERE');
      expect(SpellFixer.fix('Corne here.', en), 'Come here.');
    });

    final fr2 = WordList.fromWords(
        ['je', 'te', 'il', 'vous', 'plaît', 'si', 'gentiment', 'merci', 'plaie', 'pli', 'est']);

    test('« SHte plaí » -> « S\'il te plaît » (retour du 26/11/2026)', () {
      expect(SpellFixer.fix('SHte plaí', fr2, lang: 'fr'), "S'il te plaît");
      expect(SpellFixer.fix('Sh vous plaît.', fr2, lang: 'fr'), "S'il vous plaît.");
      expect(SpellFixer.fix('Merci, sil te plaît.', fr2, lang: 'fr'), "Merci, s'il te plaît.");
      expect(SpellFixer.fix("S'il te plaît", fr2, lang: 'fr'), "S'il te plaît");
      // Seulement devant « te / vous plaît », et seulement en français.
      expect(SpellFixer.fix('Sh, il est là.', fr2, lang: 'fr'), 'Sh, il est là.');
      expect(SpellFixer.fix('SHte plaí', fr2, lang: 'de'), 'SHte plaît'); // « SH » laissé
    });

    test('deux mots collés, accent faux : « sigentimènt » -> « si gentiment »', () {
      expect(SpellFixer.fix('Merci sigentimènt !', fr2), 'Merci si gentiment !');
      expect(SpellFixer.fix('Merci gentimènt.', fr2), 'Merci gentiment.');
    });

    test('lettre perdue : « plaí » -> « plaît » (le mot le plus courant)', () {
      expect(SpellFixer.fix('ça te plaí ?', fr2), 'ça te plaît ?');
    });
  });

  group('SubtitleLocator', () {
    test('place la zone sur le texte qui change, pas sur le logo', () {
      final loc = SubtitleLocator();
      const subs = ['Je pense que tu as raison.', 'Allons-y tout de suite.', 'Où est-il passé ?'];
      for (var i = 0; i < 15; i++) {
        loc.add([
          SeenLine('TF1', const Rect.fromLTRB(0.85, 0.05, 0.95, 0.12)),
          SeenLine(subs[i ~/ 5], const Rect.fromLTRB(0.3, 0.80, 0.7, 0.86)),
        ]);
      }
      final z = loc.result()!;
      expect(z.subtitles, 3);
      expect(z.top, lessThan(0.80));
      expect(z.bottom, greaterThan(0.86));
      expect(z.top, greaterThan(0.6));
      expect(z.left, lessThanOrEqualTo(0.3));
      expect(z.right, greaterThanOrEqualTo(0.7));
    });

    test('rien qui change : pas de zone', () {
      final loc = SubtitleLocator();
      for (var i = 0; i < 10; i++) {
        loc.add([SeenLine('Menu principal', const Rect.fromLTRB(0.3, 0.1, 0.7, 0.15))]);
      }
      expect(loc.result(), isNull);
    });
  });

  group('SentenceJoiner', () {
    test('repère une phrase coupée', () {
      expect(SentenceJoiner.isIncomplete('Je pense que…', 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete('Je pense que...', 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete('Je pense que', 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete('Si tu viens,', 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete("Il faut qu'", 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete('I want to', 'en'), isTrue);
      expect(SentenceJoiner.isIncomplete('Ich glaube, dass', 'de'), isTrue);
      expect(SentenceJoiner.isIncomplete('Creo que', 'es'), isTrue);
      expect(SentenceJoiner.isIncomplete('Penso che', 'it'), isTrue);
      expect(SentenceJoiner.isIncomplete('Acho que', 'pt'), isTrue);
    });
    test('laisse les phrases complètes', () {
      expect(SentenceJoiner.isIncomplete('Il fait beau', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('Il fait beau.', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('Tu viens ?', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('Fais-le', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete("Va-t'en", 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('Je n’en peux plus', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('I think so', 'en'), isFalse);
      expect(SentenceJoiner.isIncomplete('Come on', 'en'), isFalse);
      expect(SentenceJoiner.isIncomplete('Ich rufe dich an', 'de'), isFalse);
      expect(SentenceJoiner.isIncomplete('Acho que não', 'pt'), isFalse);
      expect(SentenceJoiner.isIncomplete('', 'fr'), isFalse);
    });
    test('réunit les deux morceaux', () {
      expect(SentenceJoiner.join('Je pense que…', '…tu as raison.'), 'Je pense que tu as raison.');
      expect(SentenceJoiner.join('Je pense que ...', '... tu as raison.'), 'Je pense que tu as raison.');
      expect(SentenceJoiner.join('Si tu viens,', 'on part.'), 'Si tu viens, on part.');
    });
  });

  group('RatePacer', () {
    test('vitesse normale sans retard', () {
      final p = RatePacer();
      expect(p.next(0), 1.0);
      expect(p.next(5), 1.0);
    });
    test('accélère avec le retard : +40 % pour un sous-titre en attente, +80 % au plus', () {
      final p = RatePacer();
      final a = p.next(50);
      expect(a, greaterThan(1.0));
      expect(a, lessThanOrEqualTo(1.3));
      p.next(80);
      expect(p.next(80), 1.4);
      p.next(300);
      expect(p.next(300), 1.8);
      expect(p.next(1000), 1.8);
    });
    test('monte par paliers et redescend doucement', () {
      final p = RatePacer();
      expect(p.next(300), 1.3); // +30 % au plus d'un coup
      expect(p.next(300), 1.6);
      expect(p.next(0), closeTo(1.5, 1e-9));
      expect(p.next(0), closeTo(1.4, 1e-9));
      p.reset();
      expect(p.factor, 1.0);
    });
  });

  group('ReadingVote', () {
    final dict = WordList.fromWords([
      'je', 'pense', 'que', 'tu', 'as', 'raison', 'il', 'fait', 'beau', 'la', 'maison',
      'à', 'rentre', 'école', 'vu', 'ai', 'le', 'chat', 'est', 'sur', 'table', 'viens', 'non',
    ]);
    test('garde le vrai mot quand deux lectures diffèrent', () {
      expect(
        ReadingVote.combine([
          const OcrReading('Je pense que tu as raisori.'),
          const OcrReading('Je pense gue tu as raison.'),
        ], dict: dict),
        'Je pense que tu as raison.',
      );
    });
    test('la majorité l\'emporte', () {
      expect(
        ReadingVote.combine([
          const OcrReading('Le chat est sur la table'),
          const OcrReading('Le chat est sur la tabie'),
          const OcrReading('Le chat est sur la table'),
        ], dict: dict),
        'Le chat est sur la table',
      );
    });
    test('retire un mot vu dans une seule lecture sur trois', () {
      expect(
        ReadingVote.combine([
          const OcrReading('Il fait beau'),
          const OcrReading('Il fait beau x'),
          const OcrReading('Il fait beau'),
        ], dict: dict),
        'Il fait beau',
      );
    });
    test('accents : la forme du dictionnaire', () {
      expect(
        ReadingVote.combine([
          const OcrReading("Je l'ai vu à l'ecole"),
          const OcrReading("Je l'ai vu à l'école"),
        ], dict: dict),
        "Je l'ai vu à l'école",
      );
    });
    test('sans dictionnaire : la confiance de ML Kit départage', () {
      expect(
        ReadingVote.combine([
          const OcrReading('Hello Jonh', confidence: {'jonh': 0.4}),
          const OcrReading('Hello John', confidence: {'john': 0.95}),
        ]),
        'Hello John',
      );
    });
    test('garde les répliques et le tiret de début', () {
      final t = ReadingVote.combine([
        OcrReading(joinParts(['Tu viens ?', 'Non'], dialogueStart: true)),
        OcrReading(joinParts(['Tu vlens ?', 'Non'], dialogueStart: true)),
      ], dict: dict);
      expect(splitParts(t), ['Tu viens ?', 'Non']);
      expect(startsWithDialogue(t), isTrue);
    });
    test('une seule lecture : inchangée', () {
      expect(ReadingVote.combine([const OcrReading('Bonjour')], dict: dict), 'Bonjour');
      expect(ReadingVote.combine(const []), '');
    });

    test('suivi : lectures en désaccord, une image de plus puis le vote', () {
      final t = SubtitleTracker(stableFrames: 2)..dictionary = () => dict;
      expect(t.push('Je pense que tu as raisori.'), isNull);
      expect(t.push('Je pense gue tu as raison.'), isNull);
      expect(t.push('Je pense que tu as raison.'), 'Je pense que tu as raison.');
    });
    test('suivi : dit le sous-titre même s\'il disparaît pendant qu\'on départage', () {
      final t = SubtitleTracker(stableFrames: 2)..dictionary = () => dict;
      expect(t.push('Il fait beau'), isNull);
      expect(t.push('Il fait bcau'), isNull);
      expect(t.push(''), 'Il fait beau');
    });
    test('suivi : 2e lecture de la même image', () {
      final t = SubtitleTracker(stableFrames: 1)..dictionary = () => dict;
      expect(
        t.push('Je rentre à la rnaison.',
            alternatives: [const OcrReading('Je rentre à la maison.')]),
        isNull,
      );
      expect(t.push(''), 'Je rentre à la maison.');
      expect(t.lastWasFull, isTrue);
    });
    test('suivi : un nouveau sous-titre fait dire celui qui attendait', () {
      final t = SubtitleTracker(stableFrames: 2)..dictionary = () => dict;
      t.push('Il fait beau');
      expect(t.push('Il fait bcau'), isNull);
      expect(t.push('Le chat est sur la table'), 'Il fait beau');
      expect(t.push('Le chat est sur la table'), 'Le chat est sur la table');
    });
  });

  group('Azure Translator', () {
    test('codes de langue', () {
      expect(SubtitleTranslator.azureLang('fr'), 'fr');
      expect(SubtitleTranslator.azureLang('no'), 'nb');
      expect(SubtitleTranslator.azureLang('tl'), 'fil');
      expect(SubtitleTranslator.azureLang('pt'), 'pt');
      expect(SubtitleTranslator.azureLang('pt', target: true), 'pt-pt');
    });
    test('lit la réponse', () {
      const body = '[{"translations":[{"text":"Où est la gare, s\'il vous plaît ?","to":"fr"}]},'
          '{"translations":[{"text":"Merci.","to":"fr"}]}]';
      expect(SubtitleTranslator.parseAzure(body, 2), ["Où est la gare, s'il vous plaît ?", 'Merci.']);
      expect(SubtitleTranslator.parseAzure(body, 3), isNull);
      expect(SubtitleTranslator.parseAzure('{"error":{}}', 1), isNull);
    });
    test('messages d\'erreur', () {
      expect(SubtitleTranslator.azureErrorMessage(401, '{"error":{"code":401000}}'), contains('Clé Azure'));
      expect(SubtitleTranslator.azureErrorMessage(403, '{"error":{"code":403001,"message":"quota"}}'),
          contains('Quota'));
      expect(SubtitleTranslator.azureErrorMessage(429, ''), contains('surchargé'));
      expect(SubtitleTranslator.azureErrorMessage(500, 'oops'), 'Azure a répondu 500.');
    });
  });

  group('Zone miroir', () {
    test('zone en bas : miroir en haut', () {
      final m = mirrorBand(0.62, 0.95)!;
      expect(m.$1, closeTo(0.05, 1e-9));
      expect(m.$2, closeTo(0.38, 1e-9));
    });
    test('zone en haut : miroir en bas', () {
      final m = mirrorBand(0.05, 0.40)!;
      expect(m.$1, closeTo(0.60, 1e-9));
      expect(m.$2, closeTo(0.95, 1e-9));
    });
    test('ne chevauche jamais la zone', () {
      final m = mirrorBand(0.30, 0.95)!;
      expect(m.$1, closeTo(0.05, 1e-9));
      expect(m.$2, closeTo(0.28, 1e-9));
    });
    test('pas de miroir pour une zone qui prend presque toute la hauteur', () {
      expect(mirrorBand(0.05, 0.95), isNull);
    });
  });

  group('Nouvelles langues', () {
    test('codes et écritures', () {
      expect(supportedLanguage('nb-NO')?.code, 'no');
      expect(supportedLanguage('pl')?.label, 'Polski');
      expect(languageFor('ja').script, SubtitleScript.japanese);
      expect(languageFor('ko').script, SubtitleScript.korean);
      expect(languageFor('nl').script, SubtitleScript.latin);
      expect(SubtitleScript.fromName('chinese'), SubtitleScript.chinese);
      expect(SubtitleScript.fromName('???'), SubtitleScript.latin);
      expect(kOtherLanguages.containsKey('nl'), isFalse);
      expect(isReadLanguage('zh'), isTrue);
    });
    test('traduction : codes DeepL et Azure', () {
      expect(SubtitleTranslator.deeplTarget('zh'), 'ZH-HANS');
      expect(SubtitleTranslator.deeplTarget('no'), 'NB');
      expect(SubtitleTranslator.deeplTarget('nl'), 'NL');
      expect(SubtitleTranslator.azureLang('zh'), 'zh-Hans');
    });
    test('comparaison : toutes les écritures', () {
      expect(normalizeForCompare('你好，世界！'), '你好 世界');
      expect(normalizeForCompare('Łódź'), 'lodz');
      expect(normalizeForCompare('Přečtu titulky'), 'prectu titulky');
      expect(similarity(normalizeForCompare('안녕하세요'), normalizeForCompare('안녕하세요!')), 1.0);
    });
    test('temps de parole', () {
      expect(speechWeight('ab'), 2);
      expect(speechWeight('你好'), 6);
      expect(speechWeight('안녕'), 6);
    });
    test('répliques en chinois', () {
      expect(subtitleParts(['－你好', '－再见']), ['你好。', '再见']);
      expect(cleanSubtitle(['我觉得', '你说得对。']), '我觉得你说得对。');
    });
    test('vote caractère par caractère', () {
      expect(ReadingVote.tokens('我觉得 OK 吗'), ['我', '觉', '得', 'OK', '吗']);
      expect(
        ReadingVote.combine(const [
          OcrReading('我觉得你说得对'),
          OcrReading('我觉得你说得封'),
          OcrReading('我觉得你说得对'),
        ]),
        '我觉得你说得对',
      );
      expect(ReadingVote.joinTokens(['Hello', 'world']), 'Hello world');
    });
    test('phrases coupées en chinois', () {
      expect(SentenceJoiner.isIncomplete('我觉得，', 'zh'), isTrue);
      expect(SentenceJoiner.isIncomplete('我觉得你说得对。', 'zh'), isFalse);
      expect(SentenceJoiner.join('我觉得…', '…你说得对。'), '我觉得你说得对。');
    });
  });
  group('Mots raccourcis, phrases coupées', () {
    test('« | » collé à des lettres : I ou l', () {
      expect(cleanSubtitle(['|l est parti.']), 'Il est parti.');
      expect(cleanSubtitle(['|ls arrivent']), 'Ils arrivent');
      expect(cleanSubtitle(['A|ors on y va']), 'Alors on y va');
      expect(cleanSubtitle(["|'homme est là"]), "l'homme est là");
      expect(cleanSubtitle(["|'m here"]), "I'm here");
      expect(cleanSubtitle(['Il faut a||er']), 'Il faut aller');
      expect(cleanSubtitle(['| Bonjour |']), 'Bonjour');
    });

    test('ligne voisine : la 1re ligne d\'un sous-titre qui dépasse de la zone est lue', () {
      const zone = Rect.fromLTRB(0.15, 0.62, 0.85, 0.95);
      final rects = [
        const Rect.fromLTRB(0.30, 0.55, 0.70, 0.61), // 1re ligne, au-dessus de la zone
        const Rect.fromLTRB(0.25, 0.63, 0.75, 0.69), // 2e ligne, dans la zone
        const Rect.fromLTRB(0.40, 0.20, 0.60, 0.26), // texte loin au-dessus
        const Rect.fromLTRB(0.02, 0.70, 0.10, 0.73), // logo à gauche
      ];
      expect(linesInZone(rects, zone), [0, 1]);
    });

    test('ligne voisine : pas une ligne d\'une autre taille ou trop loin', () {
      const line = Rect.fromLTRB(0.25, 0.63, 0.75, 0.69);
      expect(isNeighbourLine(line, const Rect.fromLTRB(0.30, 0.55, 0.70, 0.61)), isTrue);
      expect(isNeighbourLine(line, const Rect.fromLTRB(0.30, 0.45, 0.70, 0.51)), isFalse); // trop loin
      expect(isNeighbourLine(line, const Rect.fromLTRB(0.40, 0.47, 0.60, 0.61)), isFalse); // bien plus haute
      expect(isNeighbourLine(line, const Rect.fromLTRB(0.80, 0.55, 0.95, 0.61)), isFalse); // pas alignée
    });

    test('lecture renforcée : le recadrage contient la ligne qui dépasse de la zone', () {
      const zone = Rect.fromLTRB(0.15, 0.62, 0.85, 0.95);
      const visible = Rect.fromLTRB(0, 0, 1, 1);
      final c = enhancedCrop(zone, [const Rect.fromLTRB(0.08, 0.64, 0.93, 0.70)], visible);
      expect(c.left, lessThan(0.08));
      expect(c.right, greaterThan(0.93));
      final none = enhancedCrop(zone, const [], visible);
      expect(none.left, 0);
      expect(none.right, 1);
      expect(none.top, lessThan(zone.top));
    });

    test('lecture renforcée : une ligne qui touche le bord du recadrage est écartée', () {
      const crop = Rect.fromLTRB(0.13, 0.60, 0.87, 0.97);
      expect(touchesCropEdge(const Rect.fromLTRB(0.13, 0.64, 0.80, 0.70), crop), isTrue);
      expect(touchesCropEdge(const Rect.fromLTRB(0.20, 0.64, 0.868, 0.70), crop), isTrue);
      expect(touchesCropEdge(const Rect.fromLTRB(0.20, 0.64, 0.80, 0.70), crop), isFalse);
      // Bord du recadrage = bord de l'image : la ligne n'est pas coupée par le recadrage.
      expect(touchesCropEdge(const Rect.fromLTRB(0.0, 0.64, 0.8, 0.70), const Rect.fromLTRB(0, 0.6, 1, 0.97)),
          isFalse);
    });

    test('vote : un mot absent de la lecture de référence revient si d\'autres l\'ont lu', () {
      final dict = WordList.fromWords(['je', 'pense', 'que', 'tu', 'as', 'raison', 'mes', 'amis']);
      // Deux lectures renforcées identiques (sans le dernier mot) et une lecture normale complète.
      expect(
        ReadingVote.combine([
          const OcrReading('Je pense que tu as'),
          const OcrReading('Je pense que tu as'),
          const OcrReading('Je pense que tu as raison'),
          const OcrReading('Je pense que tu as raison'),
        ], dict: dict),
        'Je pense que tu as raison',
      );
      expect(
        ReadingVote.combine([
          const OcrReading('pense que tu as raison'),
          const OcrReading('pense que tu as raison'),
          const OcrReading('Je pense que tu as raison'),
        ], dict: dict),
        'Je pense que tu as raison',
      );
      // Un mot parasite vu une seule fois sur trois n'est pas ajouté.
      expect(
        ReadingVote.combine([
          const OcrReading('mes amis'),
          const OcrReading('mes amis'),
          const OcrReading('mes x amis'),
        ], dict: dict),
        'mes amis',
      );
    });

    test('suivi : après un écran vide, un sous-titre est dit en entier', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Tu sais ce que je veux dire'), 'Tu sais ce que je veux dire');
      for (var i = 0; i < 3; i++) {
        t.push('');
      }
      expect(t.push('ce que je veux dire, voilà tout'), 'ce que je veux dire, voilà tout');
    });
  });
  group('Phrases sautées, traductions bizarres', () {
    test('file de la voix : de courts dialogues ne sont plus abandonnés', () {
      // 4 répliques courtes en attente (2 sous-titres) : rien n'est retiré.
      expect(
        SpeechService.toDrop([
          (batch: 1, weight: 8), (batch: 1, weight: 6),
          (batch: 2, weight: 10), (batch: 2, weight: 7), (batch: 3, weight: 12),
        ], SpeechService.maxWaitingChars),
        0,
      );
    });
    test('file de la voix : trop de retard, les plus anciens sous-titres entiers partent', () {
      expect(
        SpeechService.toDrop([
          (batch: 1, weight: 30), (batch: 1, weight: 20),
          (batch: 2, weight: 100), (batch: 3, weight: 120),
        ], 240),
        2, // les deux répliques du sous-titre 1
      );
      // Jamais le dernier sous-titre arrivé, même très long.
      expect(SpeechService.toDrop([(batch: 5, weight: 400)], 240), 0);
      expect(SpeechService.toDrop([(batch: 4, weight: 50), (batch: 5, weight: 400)], 240), 1);
    });

    test('suivi : deux répliques qui se ressemblent sont dites toutes les deux', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Oui, monsieur.'), 'Oui, monsieur.');
      expect(t.push('Non, monsieur.'), 'Non, monsieur.');
    });
    test('suivi : la même réplique, plus tard, est redite', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Non merci.'), 'Non merci.');
      for (var i = 0; i < 12; i++) {
        t.push('Je ne viens pas avec toi ce soir.');
      }
      expect(t.push('Non merci.'), 'Non merci.');
    });
    test('suivi : relu juste après un trou de lecture, pas redit', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Non merci.'), 'Non merci.');
      for (var i = 0; i < 3; i++) {
        t.push('');
      }
      expect(t.push('Non merci.'), isNull);
    });

    test('traduction : pause d\'un moteur en ligne selon l\'erreur', () {
      expect(SubtitleTranslator.pauseAfter(456), const Duration(hours: 6)); // quota DeepL
      expect(SubtitleTranslator.pauseAfter(403), const Duration(hours: 6)); // clé refusée
      expect(SubtitleTranslator.pauseAfter(429), const Duration(seconds: 20));
      expect(SubtitleTranslator.pauseAfter(null), const Duration(minutes: 1)); // réseau
    });

    test('langue : un sous-titre moyen et peu sûr ne fait pas changer seul', () {
      final d = LanguageDecision('en');
      expect(d.update('Bon appétit à tous', {'fr': 0.8}), 'en');
      expect(d.update('Merci beaucoup, madame', {'fr': 0.8}), 'fr');
    });
  });
  test('traduction désactivée par défaut (lecture des sous-titres tels quels)', () {
    expect(kTranslationEnabled, isFalse);
  });

  group('Voix plus naturelle', () {
    test('sous-titre en majuscules remis en minuscules', () {
      expect(speakableText('TU VIENS ? NON, PAS CE SOIR.'), 'Tu viens ? Non, pas ce soir.');
      expect(speakableText("C'EST LE FBI ! OK."), "C'est le FBI ! OK.");
      expect(speakableText("I DON'T KNOW, I'M TIRED.", lang: 'en'), "I don't know, I'm tired.");
      expect(speakableText('ISTANBUL', lang: 'tr'), 'Istanbul');
    });

    test('texte normal et sigle isolé inchangés', () {
      expect(speakableText('Il travaille à la SNCF.'), 'Il travaille à la SNCF.');
      expect(speakableText('OK.'), 'OK.');
      expect(speakableText('NON'), 'Non'); // épelé « N, O, N » avant le 26/11/2026
    });

    test('nom du personnage retiré', () {
      expect(speakableText('JEAN : Tu viens ?'), 'Tu viens ?');
      expect(speakableText('MARIE-CLAIRE: Bonjour.'), 'Bonjour.');
      expect(speakableText('JOHN SMITH: Hello there.'), 'Hello there.');
      expect(speakableText('ATTENTION : la porte.'), 'Attention : la porte.');
      expect(speakableText('OK : on y va.'), 'OK : on y va.');
    });

    test('ponctuation adaptée à la voix', () {
      expect(speakableText('...et puis il est parti.'), 'et puis il est parti.');
      expect(speakableText('Je...je ne sais pas...'), 'Je… je ne sais pas…');
      expect(speakableText('Quoi ?!! Non !!!'), 'Quoi ?! Non !');
      expect(speakableText('Il a dit « demain ».'), 'Il a dit demain.');
      expect(speakableText('UN HOMME EST LÀ.'), 'Un homme est là.');
      expect(speakableText('Oui - enfin, non.'), 'Oui, enfin, non.');
      expect(speakableText('...'), '...');
    });

    test('voix robotiques jamais choisies automatiquement', () {
      final c = VoiceCatalog()
        ..load([
          {'name': 'Eddy', 'locale': 'fr-FR', 'quality': 'default', 'gender': 'male',
            'identifier': 'com.apple.eloquence.fr-FR.Eddy'},
          {'name': 'Albert', 'locale': 'en-US', 'quality': 'default', 'gender': 'male',
            'identifier': 'com.apple.speech.synthesis.voice.Albert'},
          {'name': 'Samantha', 'locale': 'en-US', 'quality': 'default', 'gender': 'female',
            'identifier': 'com.apple.voice.compact.en-US.Samantha'},
          {'name': 'Thomas', 'locale': 'fr-FR', 'quality': 'default', 'gender': 'male',
            'identifier': 'com.apple.voice.compact.fr-FR.Thomas'},
        ]);
      expect(c.best('fr')!.name, 'Thomas');
      expect(c.best('en')!.name, 'Samantha');
      // 2e personnage : pas Eddy ni Albert, la même voix sera prise (plus grave).
      expect(c.secondVoice('fr', c.best('fr')), isNull);
      expect(c.secondVoice('en', c.best('en')), isNull);
      expect(c.labelsFor('fr')['Eddy|fr-FR'], contains('robotique'));
      expect(kSecondVoicePitch, greaterThan(0.8));
    });
  });
  test('barre de langue : « Auto » et la langue du téléphone', () {
    expect(phoneLanguage('fr-FR').code, 'fr');
    expect(phoneLanguage('de-AT').code, 'de');
    expect(phoneLanguage('nb-NO').code, 'no');
    expect(phoneLanguage('zh-Hans-CN').code, 'zh');
    expect(phoneLanguage('pt-BR').code, 'pt');
    // Téléphone dans une langue que VoxLiso ne lit pas : le français.
    expect(phoneLanguage('ar-EG').code, 'fr');
  });
  group('Sous-titres brefs', () {
    final dict = WordList.fromWords(
        ['non', 'merci', 'je', 'ne', 'sais', 'pas', 'quoi', 'faire']);
    SubtitleTracker tracker() => SubtitleTracker()..dictionary = () => dict;

    test('vu une seule fois, fait de vrais mots : dit quand même', () {
      final t = tracker();
      expect(t.push('Non merci.'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), 'Non merci.');
    });
    test('image floue vue une seule fois : pas dite', () {
      final t = tracker();
      expect(t.push('Nqn mrc1.'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), isNull);
    });
    test('début d\'un sous-titre qui apparaît : pas dit à part', () {
      final t = tracker();
      expect(t.push('Je ne sais'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), 'Je ne sais pas quoi faire.');
    });
    test('vu une fois puis écran vide : dit à la 2e image vide', () {
      final t = tracker();
      expect(t.push('Non merci.'), isNull);
      expect(t.push(''), isNull);
      expect(t.push(''), 'Non merci.');
    });
    test('sans dictionnaire : comme avant (deux images)', () {
      final t = SubtitleTracker();
      expect(t.push('Non merci.'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), isNull);
    });
  });

  group('Temps réel', () {
    final dict = WordList.fromWords([
      'non', 'merci', 'je', 'ne', 'sais', 'pas', 'quoi', 'faire', 'tu', 'viens', 'ce', 'soir',
    ]);
    SubtitleTracker tracker() => SubtitleTracker()
      ..fastClean = true
      ..dictionary = () => dict;

    test('sous-titre net : dit dès la 1re image', () {
      final t = tracker();
      expect(t.push('Je ne sais pas quoi faire.'), 'Je ne sais pas quoi faire.');
      expect(t.push('Je ne sais pas quoi faire.'), isNull);
      expect(t.lastAppearedAt, isNotNull);
    });
    test('lecture douteuse : attend comme avant', () {
      final t = tracker();
      expect(t.push('Je ne sqis pas qvoi faire.'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), 'Je ne sais pas quoi faire.');
    });
    test('ML Kit peu sûr : attend comme avant', () {
      final t = tracker();
      expect(t.push('Non merci.', confidence: {'non': 0.3, 'merci': 0.4}), isNull);
    });
    test('sans dictionnaire : attend comme avant', () {
      final t = SubtitleTracker()..fastClean = true;
      expect(t.push('Non merci.'), isNull);
      expect(t.push('Non merci.'), 'Non merci.');
    });
    test('deux sous-titres à la suite : le nouveau suit aussitôt', () {
      final t = tracker()..fastClean = false;
      expect(t.push('Non merci.'), isNull); // vu une fois
      t.fastClean = true;
      expect(t.push('Tu viens ce soir ?'), 'Non merci.');
      expect(t.takeReady(), 'Tu viens ce soir ?');
      expect(t.takeReady(), isNull);
      expect(t.push('Tu viens ce soir ?'), isNull);
    });
    test('sous-titre encore en train d\'apparaître : la suite est dite à part', () {
      final t = tracker();
      expect(t.push('Je ne'), 'Je ne');
      expect(t.push('Je ne sais pas quoi faire.'), 'sais pas quoi faire.');
      expect(t.push('Je ne sais pas quoi faire.'), isNull);
    });
    test('fin ajoutée à l\'image suivante : dite aussi', () {
      final t = tracker();
      expect(t.push('Je ne sais pas quoi faire ce'), 'Je ne sais pas quoi faire ce');
      expect(t.push('Je ne sais pas quoi faire ce soir'), 'soir');
      expect(t.lastWasFull, isFalse);
      expect(t.push('Je ne sais pas quoi faire ce soir'), isNull);
    });
    test('lecture nette', () {
      expect(ReadingVote.looksClean('Non, merci !', dict), isTrue);
      expect(ReadingVote.looksClean('Non, mrc1 !', dict), isFalse);
      expect(ReadingVote.looksClean('Non merci', dict, confidences: [0.9, 0.95]), isTrue);
      expect(ReadingVote.looksClean('Non merci', dict, confidences: [0.4, 0.5]), isFalse);
      expect(ReadingVote.looksClean('?!', dict), isFalse);
      expect(ReadingVote.looksClean('Non merci', null), isFalse);
    });
  });

  group('Seulement les sous-titres', () {
    final dict = WordList.fromWords([
      'non', 'merci', 'je', 'ne', 'sais', 'pas', 'quoi', 'faire', 'tu', 'viens', 'reste',
      'ok', 'ans', 'rendez', 'vous', 'à', 'ce', 'soir', 'on', 'part',
    ]);
    const zone = Rect.fromLTRB(0.15, 0.62, 0.85, 0.95);
    const sub = Rect.fromLTRB(0.3, 0.83, 0.7, 0.87); // centré, hauteur 0,04
    SeenGeom g(Rect r, String text, {double? angle}) => SeenGeom(r, text, angle: angle);
    StyleVerdict run(SubtitleStyle st, List<SeenGeom> lines, {int visible = 2, bool clean = false}) =>
        st.filter(lines, zone: zone, visibleLines: visible, dict: dict, needClean: clean);
    SubtitleStyle learnedStyle([DateTime Function()? clock, double? angle]) {
      final st = SubtitleStyle(clock: clock);
      for (final text in ['Non merci', 'Tu viens', 'Je ne sais pas']) {
        st.learn([g(sub, text, angle: angle)], dict: dict);
      }
      return st;
    }

    test('heure, chaîne, adresse web, mot-dièse : écartés', () {
      expect(isJunkLine('20:45', dict), isTrue);
      expect(isJunkLine('TF1', dict), isTrue);
      expect(isJunkLine('HD', dict), isTrue);
      expect(isJunkLine('www.france.tv', dict), isTrue);
      expect(isJunkLine('#Quotidien', dict), isTrue);
      expect(isJunkLine('Non.', dict), isFalse);
      expect(isJunkLine('OK', dict), isFalse);
      expect(isJunkLine('- 20 ans ?', dict), isFalse);
      expect(isJunkLine('Rendez-vous à 20h30.', dict), isFalse);
    });
    test('lignes réelles : les petits bouts du décor ne comptent pas', () {
      expect(isRealLine('Non merci', dict), isTrue);
      expect(isRealLine('ll', dict), isFalse);
      expect(isRealLine('20:45', dict), isFalse);
    });
    test('lignes l\'une sous l\'autre, ou ligne coupée en deux : un seul groupe', () {
      final groups = groupLines([
        sub,
        const Rect.fromLTRB(0.35, 0.88, 0.65, 0.92),
        const Rect.fromLTRB(0.16, 0.65, 0.3, 0.72),
      ]);
      expect(groups, [
        [0, 1],
        [2],
      ]);
      expect(groupLines([
        const Rect.fromLTRB(0.25, 0.83, 0.47, 0.87),
        const Rect.fromLTRB(0.53, 0.83, 0.75, 0.87),
      ]), [
        [0, 1],
      ]);
    });
    test('avant d\'apprendre : sous-titre lu, petit panneau sur le côté écarté', () {
      final v = run(SubtitleStyle(), [
        g(const Rect.fromLTRB(0.16, 0.65, 0.3, 0.72), 'HÔTEL'),
        g(sub, 'Non merci'),
      ]);
      expect(v.kept, {1});
      expect(v.ignored, {0});
      expect(v.reasons, {'pas centré'});
    });
    test('avant d\'apprendre : sous-titre un peu décalé, ou penché, lu quand même', () {
      expect(run(SubtitleStyle(), [g(const Rect.fromLTRB(0.4, 0.83, 0.62, 0.87), 'Non')]).kept, {0});
      expect(run(SubtitleStyle(), [g(sub, 'Non merci', angle: 90)]).kept, {0});
    });
    test('vraie phrase pas centrée : lue quand même', () {
      final v = run(SubtitleStyle(),
          [g(const Rect.fromLTRB(0.16, 0.8, 0.3, 0.84), 'Je ne sais pas quoi faire.')]);
      expect(v.kept, {0});
    });
    test('image pleine de texte (menu) : rien lu tant que rien n\'est appris', () {
      final v = run(SubtitleStyle(), [g(sub, 'Non merci')], visible: 12);
      expect(v.kept, isEmpty);
      expect(v.busy, isTrue);
      expect(v.reasons, {'menu ou page'});
      expect(run(SubtitleStyle(), [g(sub, 'Non merci')], visible: 9).kept, {0});
    });
    test('zone du haut : texte net exigé au début', () {
      expect(run(SubtitleStyle(), [g(sub, 'Xqzt brmw')], clean: true).kept, isEmpty);
      expect(run(SubtitleStyle(), [g(sub, 'Non merci')], clean: true).kept, {0});
    });
    test('appris : même taille et même place seulement', () {
      final st = learnedStyle();
      expect(st.learned, isTrue);
      expect(st.height, closeTo(0.04, 1e-9));
      expect(st.center, closeTo(0.5, 1e-9));
      // Deux fois plus grand (titre, enseigne) : écarté.
      final big = run(st, [g(const Rect.fromLTRB(0.3, 0.8, 0.7, 0.88), 'Non merci')]);
      expect(big.kept, isEmpty);
      expect(big.reasons, {'autre taille'});
      // Un peu plus grand ou plus petit (majuscules, accents) : lu.
      expect(run(st, [g(const Rect.fromLTRB(0.3, 0.83, 0.7, 0.88), 'Non merci')]).kept, {0});
      // Même taille mais à côté : écarté, sauf une vraie phrase.
      const off = Rect.fromLTRB(0.58, 0.83, 0.8, 0.87);
      expect(run(st, [g(off, 'POLICE')]).kept, isEmpty);
      expect(run(st, [g(off, 'Je ne sais pas quoi faire.')]).kept, {0});
      // Ligne coupée en deux par ML Kit : les deux morceaux sont lus.
      expect(
          run(st, [
            g(const Rect.fromLTRB(0.25, 0.83, 0.47, 0.87), 'Tu viens'),
            g(const Rect.fromLTRB(0.53, 0.83, 0.75, 0.87), 'ce soir'),
          ]).kept,
          {0, 1});
      // Menu à l'écran : le sous-titre qui a le bon aspect est lu, le reste non.
      expect(run(st, [g(sub, 'Non merci')], visible: 12).kept, {0});
      expect(run(st, [g(off, 'Je ne sais pas quoi faire.')], visible: 12).kept, isEmpty);
    });
    test('appris penché (téléphone pas droit) : l\'inclinaison compte à partir de là', () {
      final st = learnedStyle(null, 4);
      expect(run(st, [g(sub, 'On part', angle: 6)]).kept, {0});
      final v = run(st, [g(sub, 'On part', angle: 25)]);
      expect(v.kept, isEmpty);
      expect(v.reasons, {'penché'});
    });
    test('apprend seulement sur un sous-titre seul et assez lisible', () {
      final st = SubtitleStyle();
      st.learn([g(sub, 'Non merci'), g(const Rect.fromLTRB(0.16, 0.65, 0.3, 0.72), 'HÔTEL')],
          dict: dict);
      st.learn([g(sub, 'Xqzt brmw')], dict: dict);
      expect(st.samples, 0);
      st.learn([g(sub, 'Je ne sais pas qvoi')], dict: dict); // 4 mots sur 5
      expect(st.samples, 1);
    });
    test('téléphone déplacé : réapprend après 3 sous-titres du même aspect', () {
      var now = DateTime(2026, 11, 27, 18);
      final st = learnedStyle(() => now);
      const moved = Rect.fromLTRB(0.25, 0.78, 0.65, 0.87); // plus grand, décalé
      now = now.add(const Duration(seconds: 2));
      expect(run(st, [g(moved, 'Non merci')]).kept, isEmpty);
      now = now.add(const Duration(seconds: 2));
      expect(run(st, [g(moved, 'Tu viens')]).kept, isEmpty);
      now = now.add(const Duration(seconds: 2));
      expect(run(st, [g(moved, 'Je reste')]).kept, {0});
      expect(st.height, closeTo(0.09, 1e-9));
      now = now.add(const Duration(seconds: 2));
      expect(run(st, [g(moved, 'Non')]).kept, {0});
      expect(run(st, [g(sub, 'Non merci')]).kept, isEmpty);
    });
    test('bloqué 10 s sans rien lire : l\'aspect appris est oublié', () {
      var now = DateTime(2026, 11, 28, 10);
      final st = learnedStyle(() => now);
      const big = Rect.fromLTRB(0.3, 0.8, 0.7, 0.88);
      now = now.add(const Duration(seconds: 1));
      expect(run(st, [g(big, 'Xqzt')]).kept, isEmpty);
      now = now.add(const Duration(seconds: 5));
      expect(run(st, [g(big, 'Xqzt')]).kept, isEmpty);
      now = now.add(const Duration(seconds: 6));
      expect(run(st, [g(big, 'Xqzt')]).kept, {0});
      expect(st.learned, isFalse);
    });
  });

  group('Bips de cadrage', () {
    test('rien dans la zone : pas de bip', () {
      expect(aimBeepHz(0, 1), isNull);
    });
    test('plus aigu quand le texte est lisible', () {
      expect(aimBeepHz(1, readabilityFromConfidence([0.3, 0.35])), 440);
      expect(aimBeepHz(2, readabilityFromConfidence([0.97, 0.99])), 1320);
      final mid = aimBeepHz(1, readabilityFromConfidence([0.7]))!;
      expect(mid, greaterThan(440));
      expect(mid, lessThan(1320));
      expect(readabilityFromConfidence(const []), 0.5);
    });
  });
  group('Profils de zone', () {
    const salon = ZoneProfile(
        name: 'Télé du salon', top: 0.6, bottom: 0.9, left: 0.1, right: 0.9, zoom: 2, exposure: -1);
    const bureau = ZoneProfile(
        name: 'Ordinateur', top: 0.7, bottom: 0.95, left: 0.2, right: 0.8, zoom: 1, exposure: 0);

    test('enregistrés puis relus', () {
      final back = decodeProfiles(encodeProfiles([salon, bureau]));
      expect(back.map((p) => p.name), ['Télé du salon', 'Ordinateur']);
      expect(back.first.zoom, 2);
      expect(back.first.exposure, -1);
    });
    test('même nom : remplacé ; supprimé par son nom', () {
      final changed = ZoneProfile(
          name: 'télé du salon', top: 0.5, bottom: 0.8, left: 0.1, right: 0.9, zoom: 1, exposure: 0);
      final list = upsertProfile([salon, bureau], changed);
      expect(list.length, 2);
      expect(list.first.top, 0.5);
      expect(removeProfile(list, 'ORDINATEUR').map((p) => p.name), ['télé du salon']);
    });
    test('8 profils au plus', () {
      var list = <ZoneProfile>[];
      for (var i = 0; i < 10; i++) {
        list = upsertProfile(list, ZoneProfile(
            name: 'P$i', top: 0.6, bottom: 0.9, left: 0.1, right: 0.9, zoom: 1, exposure: 0));
      }
      expect(list.length, ZoneProfile.max);
      expect(list.first.name, 'P2');
    });
    test('profil en cours reconnu', () {
      expect(salon.matches(top: 0.601, bottom: 0.9, left: 0.1, right: 0.9, zoom: 2, exposure: -1), isTrue);
      expect(salon.matches(top: 0.7, bottom: 0.9, left: 0.1, right: 0.9, zoom: 2, exposure: -1), isFalse);
    });
    test('données abîmées : liste vide', () {
      expect(decodeProfiles('pas du json'), isEmpty);
      expect(decodeProfiles('[{"top": 0.5}]'), isEmpty);
    });
  });
  group('Mots épelés lettre par lettre (retour du 26/11/2026)', () {
    test('mot en majuscules dans une phrase normale', () {
      expect(speakableText('Il a dit NON !'), 'Il a dit Non !');
      expect(speakableText('Je VEUX partir.'), 'Je Veux partir.');
      expect(speakableText('Bienvenue à PARIS.'), 'Bienvenue à Paris.');
    });
    test('réplique courte en majuscules', () {
      expect(speakableText('OUI.'), 'Oui.');
      expect(speakableText('- TU ? - MOI.'), '- Tu ? - Moi.');
    });
    test('majuscule mal lue au milieu d\'un mot', () {
      expect(speakableText('Tu vIens ?'), 'Tu viens ?');
      expect(speakableText('SHte plaît'), 'Shte plaît');
    });
    test('lettres espacées', () {
      expect(speakableText('N O N, merci.'), 'Non, merci.');
    });
    test('sigles, chiffres romains et codes gardés', () {
      expect(speakableText('Le FBI arrive.'), 'Le FBI arrive.');
      expect(speakableText('Louis XIV est là.'), 'Louis XIV est là.');
      expect(speakableText('Appelle le MI6.'), 'Appelle le MI6.');
      expect(speakableText('On regarde la TV.'), 'On regarde la TV.');
    });
  });
  test('scène rapide : 6 sous-titres de 60 caractères en attente, aucun abandonné', () {
    expect(
      SpeechService.toDrop([for (var b = 1; b <= 6; b++) (batch: b, weight: 60)],
          SpeechService.maxWaitingChars),
      0,
    );
  });

  group('Apprentissage des mots (28/11/2026)', () {
    WordList dict() => WordList.fromWords([
          'je', 'tu', 'viens', 'où', 'es', 'merci', 'de', 'la', 'maison', 'rentre', 'elle',
          'est', 'va', 'ne', 'sais', 'sait', 'pas', 'non', 'on', 'il', 'regarde', 'en',
          'oui', 'nous', 'vous', 'à',
        ]);
    OcrReading r(String t, [Map<String, double> c = const {}]) => OcrReading(t, confidence: c);

    test('un nom lu sans hésiter dans 3 sous-titres est appris', () {
      final d = dict();
      final l = WordLearner();
      expect(l.observe('fr', 'Arya, viens !', dict: d, readings: [r('Arya, viens !'), r('Arya, viens !')]),
          isEmpty);
      expect(l.observe('fr', 'Où es-tu, Arya ?', dict: d, readings: [r('Où es-tu, Arya ?'), r('Où es-tu, Arya ?')]),
          isEmpty);
      expect(d.contains('arya'), isFalse);
      expect(l.observe('fr', 'Merci Arya.', dict: d, readings: [r('Merci Arya.'), r('Merci Arya.')]),
          ['arya']);
      expect(d.contains('arya'), isTrue);
      expect(ReadingVote.isKnownWord('Arya', d), isTrue);
      expect(ReadingVote.looksClean('Merci Arya.', d), isTrue);
      expect(l.wordsOf('fr'), ['arya']);
    });

    test('le même sous-titre redit ne compte qu\'une fois', () {
      final d = dict();
      final l = WordLearner();
      for (var i = 0; i < 5; i++) {
        l.observe('fr', 'Merci Arya.', dict: d, readings: [r('Merci Arya.'), r('Merci Arya.')]);
      }
      expect(d.contains('arya'), isFalse);
    });

    test('lectures en désaccord ou ML Kit peu sûr : rien n\'est appris', () {
      final d = dict();
      final l = WordLearner();
      l.observe('fr', 'Merci Arya.', dict: d, readings: [r('Merci Arya.'), r('Merci Arva.')]);
      l.observe('fr', 'Viens Arya.', dict: d, readings: [r('Viens Arya.', {'arya': 0.5})]);
      l.observe('fr', 'Non Arya.', dict: d, readings: [r('Non Arya.'), r('Non Arva.')]);
      l.observe('fr', 'Oui Arya.', dict: d, readings: [r('Oui Arya.'), r('Oui Arva.')]);
      expect(d.contains('arya'), isFalse);
      // Lecture unique, ML Kit sûr de lui : compte entièrement.
      l.observe('fr', 'Va Arya.', dict: d, readings: [r('Va Arya.', {'arya': 0.95})]);
      l.observe('fr', 'Tu es Arya.', dict: d, readings: [r('Tu es Arya.', {'arya': 0.9})]);
      l.observe('fr', 'Elle est Arya.', dict: d, readings: [r('Elle est Arya.', {'arya': 0.92})]);
      expect(d.contains('arya'), isTrue);
    });

    test('sigles et sous-titres pleins de mots inconnus ne sont pas appris', () {
      final d = dict();
      final l = WordLearner();
      for (final t in ['Regarde la HD', 'Regarde en HD', 'Regarde HD']) {
        l.observe('fr', t, dict: d, readings: [r(t), r(t)]);
      }
      for (final t in ['Xqoz brul tank vex', 'Xqoz brul tank vix', 'Xqoz brul tank vox']) {
        l.observe('fr', t, dict: d, readings: [r(t), r(t)]);
      }
      expect(l.wordCount(), 0);
    });

    test('erreur de lecture vue 2 fois : corrigée directement', () {
      final d = dict();
      final l = WordLearner();
      l.observe('fr', 'Je rentre à la maison.',
          dict: d, readings: [r('Je rentre à la rnaison.'), r('Je rentre à la maison.')]);
      expect(l.applyFixes('fr', 'Va à la rnaison.', dict: d), 'Va à la rnaison.');
      l.observe('fr', 'Elle est à la maison.',
          dict: d, readings: [r('Elle est à la maison.'), r('Elle est à la rnaison.')]);
      expect(l.fixCountOf('fr'), 1);
      expect(l.applyFixes('fr', 'Va à la rnaison.', dict: d), 'Va à la maison.');
      expect(l.applyFixes('fr', 'Rnaison !', dict: d), 'Maison !');
      expect(l.applyFixes('de', 'rnaison', dict: d), 'rnaison');
    });

    test('un nom appris : la correction y ramène les lectures abîmées', () {
      final d = dict();
      final l = WordLearner();
      for (final t in ['Hermione, viens.', 'Merci Hermione.', 'Non, Hermione.']) {
        l.observe('fr', t, dict: d, readings: [r(t), r(t)]);
      }
      expect(d.contains('hermione'), isTrue);
      expect(SpellFixer.fix('Herrnione, viens.', d, lang: 'fr'), 'Hermione, viens.');
      expect(SpellFixer.fix('Hermione, viens.', d, lang: 'fr'), 'Hermione, viens.');
    });

    test('suites de mots apprises : départagent deux vrais mots', () {
      final d = dict();
      final l = WordLearner();
      final readings = [r('je ne sait pas'), r('je ne sais pas')];
      expect(ReadingVote.combine(readings, dict: d), 'je ne sait pas');
      for (final t in ['Je ne sais pas.', 'Non, je ne sais pas.', 'Oui, je ne sais pas.', 'Tu ne sais pas.']) {
        l.observe('fr', t, dict: d, readings: [r(t), r(t)]);
      }
      final ctx = l.contextFor('fr')!;
      expect(ctx.follows('ne', 'sais'), 1.0);
      expect(ctx.follows('ne', 'sait'), 0.0);
      expect(ReadingVote.combine(readings, dict: d, context: ctx), 'je ne sais pas');
      // Pas de suite entre deux phrases.
      expect(ctx.follows('pas', 'non'), 0.0);
    });

    test('mémorisé, relu, désactivé, oublié', () {
      final d = dict();
      final l = WordLearner();
      for (final t in ['Arya, viens !', 'Merci Arya.', 'Non, Arya.']) {
        l.observe('fr', t, dict: d, readings: [r(t), r(t)]);
      }
      final again = WordLearner.fromJson(l.toJson());
      final d2 = dict();
      again.bind('fr', d2);
      expect(d2.contains('arya'), isTrue);
      again.enabled = false;
      expect(d2.contains('arya'), isFalse);
      expect(again.observe('fr', 'Merci Hermione.', dict: d2), isEmpty);
      again.enabled = true;
      expect(d2.contains('arya'), isTrue);
      again.forget('fr', 'arya');
      expect(d2.contains('arya'), isFalse);
      expect(again.wordCount(), 0);
      expect(WordLearner.fromJson('pas du json').wordCount(), 0);
      l.clear();
      expect(d.contains('arya'), isFalse);
      expect(l.wordCount(), 0);
    });

    test('le suivi garde les lectures du sous-titre dit', () {
      final t = SubtitleTracker(stableFrames: 2);
      expect(t.push('Merci Arya.'), isNull);
      expect(t.push('Merci Arya.'), isNotNull);
      expect(t.lastReadings.length, 2);
    });
  });

  group('Ponctuation', () {
    final fr = WordList.fromWords([
      'viens', 'arrête', 'pourquoi', 'quoi', 'que', 'quel', 'tu', 'hôte', 'hôtel', 'miche',
      'bon', 'alors', 'on', 'y', 'va', 'oui', 'mais', 'non', 'vite', 'as', 'vu', 'il', 'en', 'a', 'sur',
    ]);
    final es = WordList.fromWords(['qué', 'haces', 'vienes', 'no', 'me', 'digas', 'quieres', 'venir', 'nuevo']);
    final en = WordList.fromWords(['stop', 'really', 'here', 'go']);
    test('« ! » lu comme un l, un 1 ou un I', () {
      expect(fixPunctuation('Viensl', lang: 'fr', dict: fr), 'Viens!');
      expect(fixPunctuation('Viens1 Vite!', lang: 'fr', dict: fr), 'Viens! Vite!');
      expect(fixPunctuation('Arrêtel', lang: 'fr', dict: fr), 'Arrête!');
      expect(fixPunctuation('Stopl', lang: 'en', dict: en), 'Stop!');
    });
    test('vrais mots et noms propres gardés', () {
      expect(fixPunctuation('Quel', lang: 'fr', dict: fr), 'Quel');
      expect(fixPunctuation('Hôtel', lang: 'fr', dict: fr), 'Hôtel');
      expect(fixPunctuation('Tu as vu Michel', lang: 'fr', dict: fr), 'Tu as vu Michel');
      expect(fixPunctuation('Viensl', lang: 'fr'), 'Viensl'); // sans dictionnaire : on ne devine pas
    });
    test('« ? » lu comme un 7', () {
      expect(fixPunctuation('Pourquoi7', lang: 'fr', dict: fr), 'Pourquoi?');
      expect(fixPunctuation('Tu viens 7', lang: 'fr', dict: fr), 'Tu viens ?');
      expect(fixPunctuation('Il en a 3 sur 7', lang: 'fr', dict: fr), 'Il en a 3 sur 7');
      expect(fixPunctuation('Really7', lang: 'en', dict: en), 'Really?');
    });
    test('apostrophes et élisions', () {
      expect(fixPunctuation("j' ai vu l` homme", lang: 'fr'), "j'ai vu l'homme");
      expect(fixPunctuation("I' m here, don' t go", lang: 'en'), "I'm here, don't go");
    });
    test('espaces et signes en double', () {
      expect(fixPunctuation('Oui,mais non.Tu viens?Non', lang: 'fr'), 'Oui, mais non. Tu viens? Non');
      expect(fixPunctuation('oui , mais demain .', lang: 'fr'), 'oui, mais demain.');
      expect(fixPunctuation('Oui,.', lang: 'fr'), 'Oui.');
      expect(fixPunctuation('Non ?.', lang: 'fr'), 'Non ?');
      expect(fixPunctuation('3,5 euros', lang: 'fr'), '3,5 euros');
      expect(fixPunctuation('U.S.A. et M.Dupont', lang: 'fr'), 'U.S.A. et M.Dupont');
      expect(fixPunctuation('Je sais... oui', lang: 'fr'), 'Je sais... oui');
    });
    test('point suivi d\'une minuscule : virgule', () {
      expect(fixPunctuation('Bon. alors on y va', lang: 'fr', dict: fr), 'Bon, alors on y va');
      expect(fixPunctuation('etc. et', lang: 'fr'), 'etc. et');
    });
    test('espagnol : « ¿ » et « ¡ »', () {
      expect(fixPunctuation('iQué haces?', lang: 'es', dict: es), '¿Qué haces?');
      expect(fixPunctuation('jNo me digas!', lang: 'es', dict: es), '¡No me digas!');
      expect(fixPunctuation('¿Vienes', lang: 'es', dict: es), '¿Vienes?');
      expect(fixPunctuation('¿Vienes.', lang: 'es', dict: es), '¿Vienes?');
      expect(fixPunctuation('¿Vienes...', lang: 'es', dict: es), '¿Vienes...');
      expect(fixPunctuation('¿Sr. García?', lang: 'es', dict: es), '¿Sr. García?');
      expect(fixPunctuation('¿Quieres venir,', lang: 'es', dict: es), '¿Quieres venir,');
      expect(fixPunctuation('iPhone nuevo', lang: 'es', dict: es), 'iPhone nuevo');
    });
    test('vote : un « ? » perdu par deux lectures sur trois reste', () {
      final dict = WordList.fromWords(['tu', 'viens', 'ce', 'soir']);
      expect(
        ReadingVote.combine([
          const OcrReading('Tu viens ce soir'),
          const OcrReading('Tu viens ce soir ?'),
          const OcrReading('Tu viens ce soir'),
        ], dict: dict),
        'Tu viens ce soir ?',
      );
      expect(
        ReadingVote.combine([
          const OcrReading('Tu viens, ce soir?'),
          const OcrReading('Tu viens ce soir.'),
          const OcrReading('Tu viens, ce soir?'),
        ], dict: dict),
        'Tu viens, ce soir?',
      );
    });
    test('vote : la ponctuation ne compte pas comme un mot', () {
      final dict = WordList.fromWords(['qué', 'haces']);
      expect(
        ReadingVote.combine([
          const OcrReading('¿ Qué haces ?'),
          const OcrReading('Qué haces'),
        ], dict: dict),
        '¿ Qué haces ?',
      );
    });
    test('voix : signe en tête retiré, tiret de fin en suspension', () {
      expect(speakableText(', et puis on part'), 'et puis on part');
      expect(speakableText('Je pense que -'), 'Je pense que…');
    });
  });
}
