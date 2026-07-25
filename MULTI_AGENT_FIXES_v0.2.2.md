# PulseExplorer multiagent v0.2.2

Correction renforcée de l'erreur Dart :

> Cannot invoke a non-'const' constructor where a const expression is expected

La version précédente n'avait pas supprimé toutes les occurrences de `const`
autour de `WebPoiAgent()` et `OsmPoiAgent()`.

La correction v0.2.2 vérifie et supprime les contextes `const` incompatibles
dans `lib/explorer_screen.dart`.

Test recommandé :

```bash
flutter clean
flutter pub get
flutter analyze
flutter build windows
```
