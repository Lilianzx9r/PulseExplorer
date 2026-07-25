# PulseExplorer multiagent v0.3.2

Corrections du build Windows :

1. `explorer_screen.dart`
   - ajout de l'import `package:latlong2/latlong.dart` pour `LatLng`.
   - correction d'une chaîne de caractères coupée sur plusieurs lignes dans
     le sous-titre des agents ; utilisation de `\n`.

2. `ai_discovery_agent.dart`
   - correction de l'interpolation conditionnelle du contexte dans la chaîne
     triple-quoted ; la chaîne `Contexte :\n...` est maintenant valide.

Test recommandé :

```bash
flutter clean
flutter pub get
flutter analyze
flutter build windows
```
