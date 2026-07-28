# PR002.2 — Lot 4

Premier vrai engine : `GpsEngine`, branché sur `geolocator` (déjà présent
dans `pubspec.yaml`, aucune nouvelle dépendance).

## Commit 1 — `models/gps_fix.dart` (nouveau)
- `GpsFix` : modèle immuable (lat/lon/timestamp + accuracy/speed/heading
  optionnels), volontairement **sans dépendance à `geolocator`** pour
  rester réutilisable (ex. par un futur engine de simulation/rejeu GPX) et
  trivialement testable.

## Commit 2 — `engines/gps_engine.dart` (nouveau)
- `GpsEngine implements NavigationEngine` :
  - `initialize()` : vérifie que le service de localisation est actif,
    vérifie/demande la permission (une seule demande si `denied`),
    passe l'engine en `failed` avec un `EngineHealthReport.error`
    explicite si service désactivé / permission refusée.
  - `start()` : ouvre le flux de position (`Geolocator.getPositionStream`
    par défaut) et publie chaque fix sur `fixes` (`Stream<GpsFix>`
    broadcast) ; `currentFix` garde le dernier fix reçu. Lève
    `EngineStateException` si appelé après un `initialize()` en échec.
  - `stop()` : annule l'abonnement au flux.
  - `dispose()` : `stop()` + ferme `fixes`.
- **Testabilité** : les 3 vérifications geolocator (`isServiceEnabled`,
  `checkPermission`, `requestPermission`) et la source des fixes
  (`fixStream`) sont injectables via le constructeur — aucun test n'a
  besoin de driver le vrai plugin/canal de plateforme.

## Commit 3 — barrel + tests
- `navigation_v2.dart` exporte désormais `engines/gps_engine.dart` et
  `models/gps_fix.dart`.
- `gps_engine_test.dart` : service désactivé, permission refusée deux fois,
  permission `deniedForever`, permission déjà accordée, demande unique de
  permission puis succès, propagation des fixes, `stop()` coupe bien le
  flux, `dispose()` ferme le stream.

## Intégration avec le socle (Lots 1-3)
```dart
final bus = EngineEventBus();
final history = EngineHistory()..attach(bus);
final registry = EngineRegistry(eventBus: bus);
final core = NavigationCore(registry: registry);

final gps = GpsEngine();
registry.register(EngineRegistration(id: 'gps', engine: gps));

final initResult = await core.initialize();
if (!initResult.ok) {
  // ex: "gps: Permission de localisation refusée." — remonté sans
  // bloquer l'initialisation d'un futur engine 'compass' ou 'map'.
}
await core.start();

gps.fixes.listen((fix) {
  // mettre à jour la carte / le positionNotifier existant
});
```

## Non fait / à décider avec toi
- Ce `GpsEngine` est **indépendant** du code GPS existant
  (`gps_simulator.dart`, `positionNotifier`/`headingNotifier` de
  `TripNavigationScreen`, `flutter_compass`). Il ne les remplace pas
  encore — c'est un nouveau composant navigation_v2 autonome.
- Deux options pour la suite :
  1. Faire consommer `TripNavigationScreen` par les fixes de `GpsEngine`
     (remplacer progressivement `positionNotifier`) ;
  2. Ajouter un `CompassEngine` similaire (autour de `flutter_compass`,
     déjà en dépendance) pour compléter le socle avant de toucher à l'UI.
- Pas de recalcul d'itinéraire ni de logique de guidage ici — uniquement
  la remontée de position brute, cohérent avec le périmètre "engine" du
  socle navigation_v2.

## Vérification
```
flutter analyze
flutter test test/navigation_v2/
```
