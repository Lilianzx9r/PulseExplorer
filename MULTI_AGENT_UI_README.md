# PulseExplorer — UI multi-agents v0.2

Cette version ajoute une première interface utilisateur réellement connectée
au moteur multi-agents.

## Accès

Depuis l'écran principal, utiliser :

**Explorer avec plusieurs agents IA**

## Fonctionnalités

- saisie d'une requête naturelle ;
- saisie des centres d'intérêt ;
- activation/désactivation de l'agent Web/IA ;
- activation/désactivation de l'agent OpenStreetMap ;
- réutilisation de la zone géographique sélectionnée dans l'application ;
- lancement parallèle via `AgentManager` ;
- affichage du nombre de POI par agent ;
- fusion et dédoublonnage ;
- affichage des POI confirmés par plusieurs agents ;
- affichage du niveau de confiance et des agents ayant contribué.

## Test local

```bash
flutter pub get
flutter analyze
flutter test
```

Puis :

```bash
flutter run
```

## Limite actuelle

Les résultats sont actuellement affichés dans l'écran Explorer. La prochaine
étape sera de permettre leur ajout direct dans une `PoiLayer` et leur affichage
sur la carte existante.
