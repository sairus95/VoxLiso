# VoxLiso

Application **Android et iPhone** qui lit à voix haute les sous-titres affichés sur une télévision ou un écran d'ordinateur.

On pointe la caméra du téléphone vers l'écran, on place la bande jaune sur les sous-titres, on appuie sur **« Lire les sous-titres »**, et le téléphone les dit à voix haute au fur et à mesure.

Langues : **français, allemand, espagnol, italien**.

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
- Le **diagnostic** (icône 🐞 en haut) affiche ce que la caméra voit : format d'image, nombre de lignes trouvées, texte lu.

### Réglages disponibles
| Réglage | Effet |
|---|---|
| Langue (FR / DE / ES / IT) | Choisit la voix. Boutons directement sur l'écran principal. |
| Zone des sous-titres | Bande jaune à déplacer / agrandir avec le doigt. Seul le texte dedans est lu (le logo de la chaîne, l'heure… sont ignorés). |
| Zoom | Pour « rapprocher » une télé éloignée. |
| Luminosité | À baisser si l'écran de la télé apparaît « brûlé » (blanc) sur l'aperçu. |
| Vitesse de la voix | De x0,5 à x2. |
| Réactivité | Rapide / Normale / Stable (Stable = moins d'erreurs si le téléphone bouge). |
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
- Tenez le téléphone **en portrait**, le plus immobile possible (un petit support aide beaucoup).
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
| `lib/main.dart` | Démarrage, thème, verrouillage en portrait |
| `lib/reader_screen.dart` | Écran principal : caméra, analyse des images, commandes |
| `lib/camera_input.dart` | Conversion des images caméra pour ML Kit (Android NV21 / iOS BGRA) |
| `lib/roi_overlay.dart` | Bande jaune réglable et cadres verts |
| `lib/text_tools.dart` | Nettoyage des sous-titres, comparaison de textes |
| `lib/subtitle_tracker.dart` | Décide quand lire un sous-titre (stabilité, doublons, défilement) |
| `lib/speech_service.dart` | Synthèse vocale et file d'attente |
| `lib/languages.dart` | Les 4 langues et leurs voix |
| `lib/settings.dart`, `lib/settings_sheet.dart` | Réglages enregistrés et écran des réglages |
| `tool/setup.dart` | Configure les dossiers Android/iOS générés |
| `test/subtitle_logic_test.dart` | Tests de la logique des sous-titres |

Ajouter une langue à alphabet latin (anglais, portugais…) : une ligne dans `lib/languages.dart`.

Bibliothèques : `camera`, `google_mlkit_text_recognition`, `flutter_tts`, `wakelock_plus`, `shared_preferences`.
