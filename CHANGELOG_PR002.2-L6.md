# PR002.2 — Lot 6

Troisième engine : `ItineraryEngine`, qui suit la progression le long
d'un `NavRoute` déjà calculé. Contrairement à `GpsEngine`/`CompassEngine`,
il n'a pas de capteur propre : c'est le code appelant qui lui transmet des
positions (typiquement `GpsEngine.fixes` → `itineraryEngine.updatePosition`),
les engines restant volontairement découplés entre eux (Lot 4/5).

⚠️ Nommage : le nom `RouteEngine` était déjà pris par l'enum existant
(`lib/route_options.dart`, OSRM/Valhalla/...). Le nouvel engine s'appelle
donc `ItineraryEngine`.

## Commit 1 — `models/route_progress.dart` (nouveau)
- `RouteProgress` : `currentStepIndex`, `distanceRemainingM`,
  `durationRemainingS`, `arrived`.

## Commit 2 — `engines/itinerary_engine.dart` (nouveau)
- `ItineraryEngine implements NavigationEngine`, réutilise directement
  `NavRoute`/`NavStep` de `navigation_service.dart` (pas de réinvention du
  calcul d'itinéraire, déjà solide et utilisé par `TripNavigationScreen`).
- `setRoute(NavRoute route)` : définit/remplace l'itinéraire suivi,
  réinitialise la progression. Utilisable avant `start()`, ou pendant
  l'exécution pour réagir à un recalcul.
- `start()` : échoue avec `EngineStateException` si aucun itinéraire n'a
  été défini. Au démarrage, cible la première étape *réelle* (index 1) —
  l'étape 0 ("depart") est located au point de départ lui-même, rien à
  "atteindre" là.
- `updatePosition(LatLng position)` : avance l'étape ciblée dès qu'on est
  à moins de `proximityM` (défaut 40 m, configurable) de sa position, peut
  sauter plusieurs étapes rapprochées en un seul appel ; publie un nouveau
  `RouteProgress` sur `progress`. Ne fait rien si l'engine n'est pas
  `running` ou si aucune route n'est définie — appelable sans précaution
  depuis un simple listener de position.
- `distanceRemainingM`/`durationRemainingS` : somme des `distanceM`/
  `durationS` des étapes restantes + distance/estimation jusqu'à l'étape
  ciblée. Approximation simple (pas de fraction de la portion déjà
  parcourue sur l'étape courante) — suffisant pour un premier lot,
  affinable si besoin.

## Commit 3 — barrel + tests
- `navigation_v2.dart` exporte `engines/itinerary_engine.dart` et
  `models/route_progress.dart`.
- `itinerary_engine_test.dart` : échec sans route, démarrage avec route,
  no-op avant `start()`, avancement d'étape + publication de progression,
  détection d'arrivée, distance décroissante, réinitialisation via
  `setRoute()`, fermeture du stream à `dispose()`. Itinéraire de test
  construit à la main (3 points ~111 m d'écart), sans appel réseau.

## Intégration des 3 engines ensemble
```dart
final registry = EngineRegistry(eventBus: EngineEventBus());
final core = NavigationCore(registry: registry);

final gps = GpsEngine();
final compass = CompassEngine();
final itinerary = ItineraryEngine();

registry.register(EngineRegistration(id: 'gps', engine: gps));
registry.register(EngineRegistration(id: 'compass', engine: compass));
registry.register(EngineRegistration(id: 'itinerary', engine: itinerary));

final route = await NavigationService.smartRoute(from, to, profile: 'driving');
itinerary.setRoute(route);

await core.initialize();
await core.start();

gps.fixes.listen((fix) => itinerary.updatePosition(LatLng(fix.latitude, fix.longitude)));
itinerary.progress.listen((p) {
  // mettre à jour l'UI : distance/durée restantes, étape courante
});
```

## Non fait / à décider
- Pas de détection de sortie de route (off-route) ni de déclenchement
  automatique de recalcul — `setRoute()` existe pour ça mais c'est au
  code appelant de décider quand recalculer (logique déjà présente dans
  `TripNavigationScreen`, à voir si on la migre ici plus tard).
- Toujours pas branché sur l'UI existante.

## Vérification
```
flutter analyze
flutter test test/navigation_v2/
```
