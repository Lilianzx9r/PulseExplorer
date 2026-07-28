# PR002.2 — Lot 5

Deuxième engine, en parallèle du GPS : `CompassEngine`, branché sur
`flutter_compass` (déjà dans `pubspec.yaml`, aucune nouvelle dépendance).
Même structure que `GpsEngine` (Lot 4) pour rester cohérent.

## Commit 1 — `models/compass_fix.dart` (nouveau)
- `CompassFix` : `headingDeg` + `timestamp` + `accuracy` optionnel, sans
  dépendance à `flutter_compass`.

## Commit 2 — `engines/compass_engine.dart` (nouveau)
- `CompassEngine implements NavigationEngine` :
  - `initialize()` : vérifie la disponibilité du capteur
    (`FlutterCompass.events != null` par défaut). Si absent → `failed`
    avec un `EngineHealthReport.error` explicite, **sans exception** — un
    appareil sans boussole ne doit pas empêcher le GPS ou d'autres engines
    de démarrer via `NavigationCore` (sémantique best-effort déjà en place
    au Lot 3).
  - `start()` : s'abonne au flux de cap et publie chaque lecture sur
    `fixes` (`Stream<CompassFix>` broadcast) ; `currentFix` garde la
    dernière valeur. Les événements à `heading == null` (que
    `flutter_compass` peut émettre avant que le capteur se stabilise) sont
    filtrés en amont.
  - `stop()`/`dispose()` : identiques dans l'esprit à `GpsEngine`.
- **Testabilité** : `isAvailable` et `fixStream` injectables, comme pour
  `GpsEngine` — aucun test ne dépend du vrai capteur/canal de plateforme.

## Commit 3 — barrel + tests
- `navigation_v2.dart` exporte `engines/compass_engine.dart` et
  `models/compass_fix.dart`.
- `compass_engine_test.dart` : capteur absent, capteur disponible, échec
  de `start()` après `initialize()` en échec, propagation des lectures,
  `stop()` coupe le flux, `dispose()` ferme le stream.

## Intégration GPS + Compass ensemble
```dart
final bus = EngineEventBus();
final registry = EngineRegistry(eventBus: bus);
final core = NavigationCore(registry: registry);

registry.register(EngineRegistration(id: 'gps', engine: GpsEngine()));
registry.register(EngineRegistration(id: 'compass', engine: CompassEngine()));

final result = await core.initialize();
// result.message peut lister UNIQUEMENT 'compass: ...' si l'appareil n'a
// pas de boussole, sans empêcher 'gps' d'avoir été initialisé.
await core.start();
```

## Non fait / à décider
- Toujours pas de branchement sur l'UI existante (`TripNavigationScreen`,
  `MapOrientationController`) — ces deux engines restent autonomes pour
  l'instant, comme convenu.
- Pas de fusion GPS+compass (ex. lissage du cap avec la trajectoire GPS
  quand le compas est absent/imprécis) — possible sujet d'un lot ultérieur
  si utile.

## Vérification
```
flutter analyze
flutter test test/navigation_v2/
```
