# PulseExplorer v0.3 — multi-agents et multi-modèles

Cette version est basée sur l'archive PulseExplorer fournie.

## Agents IA

- IA généraliste A
- IA généraliste B (même requête, autre modèle)
- Expert moto / routes panoramiques
- Expert nature
- Expert villages / patrimoine
- OpenStreetMap / Overpass

Les agents IA utilisent les modèles gratuits déclarés dans
`HtmlPoiExtractor.kFreeModels` et la clé OpenRouter déjà configurée dans
l'application.

## Dernière requête

La dernière demande d'exploration est mémorisée via les préférences existantes
de `HtmlPoiExtractor` et restaurée au prochain lancement de l'écran Explorer.

## Compilation

```bash
flutter clean
flutter pub get
flutter analyze
flutter build windows
```

## Remarque

Les modèles IA nécessitent une clé OpenRouter configurée. L'agent OSM reste
indépendant de l'IA et nécessite une zone géographique (`BoundingBox`) pour
interroger Overpass.
