# PulseExplorer — première architecture multi-agents

Cette version ajoute une première couche multi-agents sans supprimer le
fonctionnement existant.

## Agents inclus

### `WebPoiAgent`
Réutilise le pipeline actuel de `HtmlPoiExtractor` et donc le modèle IA
configuré dans PulseExplorer/OpenRouter.

### `OsmPoiAgent`
Interroge OpenStreetMap via le service Overpass déjà présent dans le projet.

### `AgentManager`
Lance les agents en parallèle, récupère leurs résultats, puis fusionne les
POI portant le même nom et les mêmes coordonnées approximatives.

## Exemple d'utilisation

```dart
import 'agents/agents.dart';

final manager = AgentManager(const [
  WebPoiAgent(),
  OsmPoiAgent(),
]);

final result = await manager.discover(
  DiscoveryRequest(
    query: 'Je souhaite visiter le Vercors en moto',
    interests: ['moto', 'nature', 'villages', 'routes panoramiques'],
    bounds: LatLngBounds(
      LatLng(44.7, 4.8),
      LatLng(45.4, 5.8),
    ),
  ),
);

for (final poi in result.pois) {
  print(
    '${poi.point.name} — '
    '${poi.agentCount} agent(s), '
    'confiance ${(poi.confidence * 100).round()}%',
  );
}
```

## Étape suivante

Cette première version est volontairement non intrusive : elle ajoute les
abstractions et les agents sans modifier les écrans existants.

La prochaine intégration pourra ajouter un écran de découverte permettant de :

1. saisir une requête libre ;
2. lancer les agents ;
3. afficher la progression ;
4. afficher les POI issus de chaque agent ;
5. afficher le consensus ;
6. convertir les résultats en `PoiLayer`.

## Vérification

Le projet doit être testé localement avec :

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

Puis :

```bash
flutter build apk
flutter build windows
```
