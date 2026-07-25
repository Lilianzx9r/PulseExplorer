# PulseExplorer multiagent v0.2.1

Correction du build Windows.

`WebPoiAgent` et `OsmPoiAgent` n'ont pas de constructeurs `const`, mais
l'écran Explorer les instanciait dans une expression `const`.

Correction appliquée : la liste des agents est maintenant non-const.

Test recommandé :

```bash
flutter clean
flutter pub get
flutter analyze
flutter build windows
```
