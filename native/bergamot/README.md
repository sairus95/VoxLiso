# Moteur de traduction du téléphone (Android)

Bergamot, le traducteur de Firefox (Mozilla, MPL-2.0, cœur Marian sous MIT),
compilé pour Android arm64 et pour Linux (tests). Les modèles de langue sont
ceux de Firefox Translations (MPL-2.0), téléchargés par l'application au
premier besoin depuis le registre public de Mozilla.

Ces scripts, l'interface C (`capi/`) et les correctifs (`patches/`) viennent
de https://github.com/ostpnk/translate-engine (licence MIT, voir `LICENSE`),
commit de7e2759829acaa6cb07fdd2962492c8e38bb0cb, sans modification.

    native/bergamot/build/fetch-engine.sh native/bergamot/engine
    native/bergamot/build/build.sh android native/bergamot/engine   # ANDROID_NDK
    native/bergamot/build/build.sh linux   native/bergamot/engine

Résultat : `native/bergamot/out/<plateforme>/release/libbergamot-*.so`.
La compilation GitHub (`.github/workflows/build.yml`, tâche `bergamot`) la
fait une fois puis la garde en cache tant que ce dossier ne change pas.
