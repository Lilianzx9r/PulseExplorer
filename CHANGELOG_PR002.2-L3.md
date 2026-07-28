# PR002.2 — Lot 3

Relie `NavigationCore` à `EngineRegistry` : c'était le dernier point ouvert
listé dans `IMPLEMENTATION_STATUS.md`.

## Commit 1 — `navigation_core.dart`
- `NavigationCore` porte désormais un `EngineRegistry registry`
  (`NavigationCore({EngineRegistry? registry})`, un registry par défaut est
  créé si aucun n'est fourni — permet aussi d'injecter un registry déjà
  câblé sur un `EngineEventBus`/`EngineHistory`, cf. Lot 2).
- `initialize()`/`start()`/`stop()` propagent l'appel correspondant à
  **tous** les engines enregistrés dans `registry`.
- Sémantique "best effort" : un engine qui échoue (exception) n'empêche pas
  les autres d'être traités. Les échecs sont collectés et renvoyés dans un
  `NavigationResult.failure('id: erreur; id2: erreur2')`. Si tout réussit :
  `NavigationResult.success()`.
- `initialized` passe à `true` après `initialize()` même en cas d'échec
  partiel (cohérent avec le comportement "best effort").
- **Compatibilité** : `NavigationCore()` sans engine enregistré se comporte
  comme avant (`initialize/start/stop` réussissent trivialement).

## Commit 2 — tests
- `navigation_core_test.dart` remplace l'ancien test minimal : registry
  vide, propagation multi-engines, échec partiel non bloquant, injection
  d'un `EngineRegistry` personnalisé.

## Utilisation typique désormais possible
```dart
final bus = EngineEventBus();
final history = EngineHistory()..attach(bus);
final core = NavigationCore(registry: EngineRegistry(eventBus: bus));

core.registry.register(EngineRegistration(id: 'gps', engine: gpsEngine));
core.registry.register(EngineRegistration(id: 'compass', engine: compassEngine));

final result = await core.initialize();
if (!result.ok) {
  // result.message liste les engines en échec, sans bloquer les autres
}
await core.start();
```

## Non fait / prochain lot possible
- Pas de gestion d'état global pour `NavigationCore` lui-même (au-delà de
  `initialized`) — pourrait s'appuyer sur `NavigationEngineState`/
  `NavigationState` si besoin d'un état agrégé (ex. "running" seulement si
  tous les engines sont `running`).
- Pas de rollback automatique (ex. arrêter les engines déjà démarrés si un
  `start()` échoue au milieu) : à discuter si c'est le comportement voulu,
  ou si le "best effort" actuel convient pour PulseExplorer.

## Vérification
```
flutter analyze
flutter test test/navigation_v2/core/
```
