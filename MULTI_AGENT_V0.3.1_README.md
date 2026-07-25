# PulseExplorer v0.3.1 — archive corrigée

Cette version reprend PulseExplorer v0.3 et corrige le comportement de l'écran
multi-agents lorsque les prérequis de recherche ne sont pas disponibles.

## Corrections

- message explicite si aucune clé OpenRouter n'est configurée ;
- message explicite si l'agent OSM est utilisé sans zone géographique ;
- le bouton de recherche n'échoue plus silencieusement avec 0 POI ;
- dédoublonnage des opinions d'un même agent sur un même POI.

## Test

```bash
flutter clean
flutter pub get
flutter analyze
flutter build windows
```

Pour obtenir des résultats IA, configurez d'abord la clé OpenRouter dans les
paramètres IA de PulseExplorer.

Pour obtenir des résultats OSM, ouvrez Explorer depuis une zone géographique
déjà sélectionnée dans l'application.
