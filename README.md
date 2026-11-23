# VoxLiso

Application **Android et iPhone** qui lit à voix haute les sous-titres affichés sur une télévision ou un écran d'ordinateur.

On pointe la caméra du téléphone vers l'écran, on place la bande jaune sur les sous-titres, on appuie sur **« Lire les sous-titres »**, et le téléphone les dit à voix haute au fur et à mesure.

Langues : **français, allemand, espagnol, italien, anglais, portugais**, et aussi **néerlandais, polonais, roumain, suédois, danois, norvégien, finnois, tchèque, slovaque, hongrois, turc, catalan, croate, chinois, japonais, coréen**.

---

## Fonctionnement

```
Caméra (≈3 images/s) ──► Reconnaissance du texte ──► Zone des sous-titres ──► Nettoyage ──► Détection des nouveaux sous-titres ──► Voix
                          (Google ML Kit, sur le       (bande jaune réglable)   ([Musique], ♪,     (lu une seule fois,             (voix du téléphone,
                           téléphone, hors ligne)                              tirets de dialogue)  même s'il reste affiché)        dans la langue choisie)
```

- **Tout se passe sur le téléphone** : pas d'internet, pas de serveur, aucune image envoyée.
- **Un sous-titre n'est lu qu'une fois**, même s'il reste affiché plusieurs secondes et même si la caméra le relit avec de petites erreurs.
- **Sous-titres en direct** (journaux TV qui défilent mot par mot) : seule la partie nouvelle est lue.
- Les lignes reconnues sont **encadrées en vert** si elles sont dans la bande jaune (lues), **en orange** si elles sont en dehors (ignorées).
- **Historique** (🕘 en haut) : toutes les phrases lues, avec l'heure ; touchez-en une pour la réentendre, ou copiez-la. Le bouton ↻ à côté du dernier sous-titre le répète.
- **Tutoriel** au premier lancement (à revoir dans Réglages > Accessibilité).
- **Mode grands boutons** (Réglages > Accessibilité) : textes et boutons agrandis, bouton « Répéter », boutons Monter / Descendre / Agrandir / Réduire pour placer la zone sans glisser (affichés aussi avec TalkBack ou VoiceOver), annonces vocales et vibration à chaque sous-titre.
- **Écran du téléphone** (Android) : lit les sous-titres des vidéos regardées sur le téléphone lui-même (YouTube, navigateur, vos vidéos), sans caméra. Appuyez sur « Lire », autorisez la capture de l'écran, puis ouvrez la vidéo ; pour arrêter, notification VoxLiso > Arrêter. **Netflix, Disney+ et Prime Video protègent leur écran : leurs sous-titres ne peuvent pas être lus.** Pas disponible sur iPhone.
- **Tester sur une photo** (icône de scanner en haut) : prend une photo et affiche tout le texte trouvé. Pratique pour vérifier que la caméra lit bien.
- Le **diagnostic** (icône 🐞 en haut) affiche ce que la caméra voit : format d'image, nombre de lignes trouvées, texte lu.

### Réglages disponibles
| Réglage | Effet |
|---|---|
| Langue (Auto / FR / DE…) | **Auto** (par défaut) reconnaît la langue de chaque sous-titre et prend la bonne voix. La barre montre les langues cochées dans **Réglages > Langues des sous-titres** (par défaut FR, DE, ES, IT, EN, PT ; 22 langues au choix). Les sous-titres dans une **langue non cochée** (ou en slovène, vietnamien…) sont **traduits automatiquement** (en français par défaut ; langue téléchargée en Wi-Fi au premier besoin, ou en ligne). Sinon, la langue choisie est imposée. |
| Chinois, japonais, coréen | Moteurs de reconnaissance ML Kit dédiés (ils lisent aussi l'alphabet latin), choisis tout seuls en touchant ZH, JA ou KO, ou dans **Écriture des sous-titres**. Texte sans espaces : comparaison et vote caractère par caractère, lignes réunies sans espace, ponctuation 。，、 reconnue, temps de parole compté triple pour la vitesse automatique. Caméra et écran du téléphone. |
| Zone des sous-titres | Bande jaune à déplacer / agrandir avec le doigt. Seul le texte dedans est lu (le logo de la chaîne, l'heure… sont ignorés). |
| Sous-titres en haut | Quand rien n'est lu dans la zone, VoxLiso lit aussi la même bande de l'autre côté de l'image (cadre en pointillés) : sous-titres placés en haut quand le bas est pris par un texte, un nom ou un générique. Texte fixe ignoré là aussi. Mode écran : en plein écran seulement. Réglage « Sous-titres en haut de l'image » (activé). |
| Repérer les sous-titres | Bouton qui observe l'écran quelques secondes (jusqu'à 12 s ; 30 s en mode écran du téléphone) et place la zone autour du texte qui change, en écartant le texte fixe. |
| Lecture renforcée | Pendant la lecture, chaque image est relue une 2e fois sur la zone recadrée, contrastée (niveaux étirés) et agrandie (jusqu'à 1600 px). |
| Lecture par vote | Un sous-titre est lu sur plusieurs images (et deux fois par image) ; les lectures sont comparées **mot à mot** et, pour chaque mot, on garde la variante la plus vue, en préférant les vrais mots de la langue (dictionnaire) et ceux que ML Kit lit avec assurance (Android). Si les lectures ne sont pas d'accord, VoxLiso attend une image de plus pour départager (le sous-titre est dit quand même s'il disparaît entre-temps). |
| Correction | Mots mal lus corrigés avec un dictionnaire par langue (confusions « rn »/« m », « 1 »/« l »…, accents oubliés). Listes : FrequencyWords (Hermit Dave), corpus OpenSubtitles2018, CC BY-SA 4.0 — voir `assets/dict/LICENCE.md`. |
| Texte fixe ignoré | Un texte qui ne change pas pendant plus de 20 s (logo de chaîne, heure, menu) n'est pas lu ; il est encadré en gris. |
| Écran noir | En option (désactivé par défaut) : pendant la lecture (caméra), après 8 s sans toucher l'écran, il passe au noir (luminosité au minimum sur Android) ; le toucher le rallume. |
| Mises à jour | Android : VoxLiso vérifie les nouvelles versions sur GitHub (au plus toutes les 6 h) et propose « Mettre à jour » : téléchargement par le gestionnaire de téléchargements d'Android (il continue écran éteint ou VoxLiso fermé, reprend après une coupure de réseau, progression dans les notifications ; « Masquer » ferme la fenêtre), puis installation après confirmation, dès que VoxLiso est à l'écran. Le fichier téléchargé est effacé une fois la nouvelle version installée. Bouton « Rechercher une mise à jour » dans les réglages. |
| Zone centrée | La zone de lecture est un rectangle centré (15–85 % de la largeur par défaut) : le texte des côtés (logos, heure, décor) est ignoré. Poignées jaunes sur les 4 côtés. |
| Vue 16:9 | Par défaut, l'aperçu est au format des télés (16:9), téléphone debout comme couché. Debout, il montre la bande centrale de l'image ; seul le texte visible est lu. Désactivable dans les réglages (vue 9:16). |
| Zoom | Pour « rapprocher » une télé éloignée. |
| Luminosité | À baisser si l'écran de la télé apparaît « brûlé » (blanc) sur l'aperçu. |
| Voix | **Moteur de voix** au choix sur Android (Google, Samsung…), bouton **Installer d'autres voix**, **hauteur** réglable (grave / aiguë) pour chaque voix. Par langue : voix principale et voix du 2e personnage, à écouter avec ▶. Sur iPhone, nom, homme/femme et voix « améliorées » ; sur Android, qualité seulement (écouter pour choisir). Par défaut : la voix la plus naturelle installée. |
| Une voix par personnage | Dans les dialogues à tirets, la 2e réplique est lue avec une autre voix (ou plus grave s'il n'y en a qu'une). |
| Traduction | Lire les sous-titres traduits en français, allemand, espagnol, italien, anglais ou portugais, sur le téléphone. Chaque langue se télécharge une fois (≈30 Mo), ensuite sans internet. **Option Microsoft Azure Translator** (essayée en premier) : avec une clé du palier gratuit F0 (2 millions de caractères par mois, renouvelés ; ressource « Translator » sur portal.azure.com), traduction en ligne ; quota du mois atteint → DeepL puis hors ligne. Clé et région intégrables à l'APK par les secrets GitHub `AZURE_TRANSLATOR_KEY` et `AZURE_TRANSLATOR_REGION` (région vide ou `global` pour une ressource globale), ou à saisir dans les réglages. **Option DeepL** : avec une clé DeepL (formule gratuite « API Developer » : 1 million de caractères au total ; l'ancienne formule « API Free » n'est plus proposée), traduction en ligne de meilleure qualité, retour automatique au hors ligne sans réseau ou quota épuisé. Une clé peut être **intégrée à l'APK** sans l'écrire dans le code : secret GitHub `DEEPL_KEY`, ajouté à la compilation (`--dart-define`). Une clé saisie dans les réglages la remplace. Jamais intégrée à la version boutique. |
| Phrases coupées | Quand une phrase est répartie sur deux sous-titres (« Je pense que… » / « …tu as raison »), elle est traduite en entier plutôt qu'en deux morceaux : un sous-titre qui finit par « … », une virgule ou un petit mot (« que », « the », « und »…) attend la suite jusqu'à 3,5 s. Pas de regroupement si le sous-titre suivant est une nouvelle réplique (tiret). Seulement pendant la traduction. |
| Vitesse de la voix | De x0,5 à x2. **Vitesse automatique** (activée par défaut) : quand les sous-titres défilent plus vite que la voix, elle accélère un peu (jusqu'à +40 %, par paliers) pour ne pas prendre de retard, puis revient doucement à la vitesse choisie. « voix accélérée ×1,2 » s'affiche pendant ce temps. |
| Réactivité | Rapide / Normale / Stable (Stable = moins d'erreurs si le téléphone bouge). |
| Mode photo | Analyse de vraies photos au lieu de la vidéo : plus lent, mais plus fiable sur certains téléphones. |
| Couper la phrase en cours | Passe directement au nouveau sous-titre si la voix est en retard. |
| Ignorer les descriptions sonores | Ne lit pas `[Musique]`, `(rires)`, `♪`. |

---

## Obtenir l'application

### Télécharger l'APK Android déjà compilé
Sur le téléphone Android, ouvrez **https://github.com/sairus95/VoxLiso/releases/latest**, touchez **VoxLiso.apk**, puis autorisez « l'installation depuis cette source ». Chaque modification envoyée sur GitHub recompile l'application et publie une nouvelle version à cette adresse.

### Option A — Android, compiler sur votre propre compte GitHub
1. Créez un compte gratuit sur [github.com](https://github.com) et un nouveau dépôt (« New repository »).
2. Envoyez-y le contenu de ce dossier (bouton « Add file » > « Upload files », glissez tous les fichiers, y compris le dossier `.github`).
   Si le dossier `.github` n'apparaît pas (dossier caché sur Mac/Windows) : « Add file » > « Create new file », tapez le nom `.github/workflows/build.yml` et collez-y le contenu de ce fichier.
3. Ouvrez l'onglet **Actions** : la compilation démarre toute seule (≈10 min).
4. Cliquez sur l'exécution terminée, puis téléchargez **voxliso-android** dans « Artifacts ». Dézippez : vous obtenez `app-release.apk`.
5. Envoyez l'APK sur le téléphone Android, ouvrez-le et autorisez « l'installation depuis cette source ».

### Option B — Sur votre ordinateur (Android et iPhone)
Prérequis : [Flutter](https://docs.flutter.dev/get-started/install) (version 3.44 ou plus récente). Pour l'iPhone : un **Mac** avec **Xcode**.

```bash
cd VoxLiso
flutter create --platforms=android,ios --org com.voxliso --project-name voxliso .
dart run tool/setup.dart        # ajoute les autorisations caméra / voix et les versions minimales
flutter pub get
flutter test                    # vérifie la logique de détection des sous-titres
flutter run                     # téléphone branché en USB
```

- **APK Android** : `flutter build apk --release` → `build/app/outputs/flutter-apk/app-release.apk`
- **iPhone** : ouvrez `ios/Runner.xcworkspace` dans Xcode, choisissez votre compte Apple dans *Signing & Capabilities*, branchez l'iPhone et cliquez ▶. Avec un compte Apple gratuit, l'app doit être réinstallée tous les 7 jours ; pour la distribuer (App Store, TestFlight), il faut le programme développeur Apple (99 €/an).

Configuration minimale : Android 7.0 ou plus, iOS 15.5 ou plus.

---

## Conseils d'utilisation
- **En paysage**, sur un petit support face à la télé : c'est la meilleure position. La télé remplit l'image, les sous-titres sont plus grands et le téléphone ne bouge pas. Activez la rotation automatique de l'écran du téléphone.
- **En portrait**, tenez le téléphone le plus immobile possible.
- La bande jaune est mémorisée séparément pour le portrait et pour le paysage.
- Utilisez le **zoom** pour que les sous-titres occupent une bonne partie de la largeur de l'aperçu.
- Évitez les reflets sur l'écran (lampe, fenêtre).
- Si la voix ne parle pas dans la bonne langue : installez la voix correspondante.
  - Android : *Paramètres > Accessibilité > Synthèse vocale > Moteur Google > Installer les données vocales*.
  - iPhone : *Réglages > Accessibilité > Contenu énoncé > Voix*.

## Limites connues
- Les sous-titres très petits, flous ou sur fond très chargé peuvent être mal lus : rapprochez-vous ou zoomez.
- La voix a un léger décalage (≈1 s) par rapport à l'image : le temps de confirmer la lecture.
- L'écran du téléphone reste allumé pendant la lecture (nécessaire pour que la caméra fonctionne).

---

## Organisation du code
| Fichier | Rôle |
|---|---|
| `lib/main.dart` | Démarrage, thème, orientations autorisées (portrait et paysage) |
| `lib/reader_screen.dart` | Écran principal : caméra, analyse des images, commandes |
| `lib/camera_input.dart` | Conversion des images caméra pour ML Kit (Android NV21 / iOS BGRA) |
| `lib/roi_overlay.dart` | Bande jaune réglable et cadres verts |
| `lib/text_tools.dart` | Nettoyage des sous-titres, comparaison de textes |
| `lib/subtitle_tracker.dart` | Décide quand lire un sous-titre (stabilité, doublons, défilement) |
| `lib/speech_service.dart` | Synthèse vocale et file d'attente |
| `lib/rate_pacer.dart` | Vitesse automatique : accélération selon le retard de la voix |
| `lib/languages.dart` | Les 22 langues lues (voix, écriture), les autres langues traduites, et les outils d'écriture (`isCjkRune`, `speechWeight`) |
| `lib/language_detector.dart` | Détection automatique de la langue (ML Kit Language ID) |
| `lib/voices.dart` | Liste et classement des voix du téléphone, choix du 2e personnage |
| `lib/translator.dart` | Traduction hors ligne (ML Kit Translation) et téléchargement des langues |
| `lib/reading_vote.dart` | Vote mot à mot entre plusieurs lectures d'un même sous-titre |
| `lib/sentence_joiner.dart` | Repérage des phrases coupées entre deux sous-titres et réunion des morceaux avant traduction |
| `lib/history.dart` | Historique des sous-titres lus et son écran |
| `lib/tutorial.dart` | Tutoriel illustré du premier lancement |
| `lib/screen_capture.dart` | Lien avec le service Android de lecture de l'écran du téléphone |
| `native/android/` | Code Kotlin : capture de l'écran (MediaProjection) + OCR ML Kit natif, installé par `tool/setup.dart` |
| `lib/settings.dart`, `lib/settings_sheet.dart` | Réglages enregistrés et écran des réglages |
| `tool/setup.dart` | Configure les dossiers Android/iOS générés (et installe l'icône) |
| `lib/logo.dart` | Logo (bulle-onde) et nom « VoxLiso » dessinés dans l'application |
| `tool/icone/`, `assets/launcher/` | Logo « Bulle-onde » (jaune #FFC93C, bleu nuit #12204A) et images générées pour Android et iOS |
| `test/subtitle_logic_test.dart` | Tests de la logique des sous-titres |

Ajouter une langue à alphabet latin : une ligne dans `lib/languages.dart` (et la retirer de `kOtherLanguages`), plus son dictionnaire `assets/dict/<code>.txt.gz` (FrequencyWords 2018, voir `assets/dict/LICENCE.md`) et son code dans `SpellFixer.languages`.

Bibliothèques : `camera`, `camera_android`, `google_mlkit_text_recognition`, `google_mlkit_language_id`, `google_mlkit_translation`, `flutter_tts`, `wakelock_plus`, `shared_preferences`.
