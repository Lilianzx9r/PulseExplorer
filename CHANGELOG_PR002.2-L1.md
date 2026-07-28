# PR002.2 — Lot 1

Quatre mini-commits, chacun compilable et relisable indépendamment.

## Commit 1 — `navigation_core.dart`
- Import déplacé avant la déclaration de classe (non conforme Dart sinon).
- `_initialized` encapsulé, exposé en lecture seule via `initialized`.
- Documentation ajoutée.
- Comportement public inchangé (`initialize/start/stop`).

## Commit 2 — `engine_history.dart` (nouveau)
- `EngineHistory` : historique borné (`maxEntries`, défaut 200) des
  `EngineEvent` publiés.
- `record()`, `forEngine(id)`, `clear()`, `entries` (vue non modifiable).
- Ne dépend que de `engine_event.dart`, aucun couplage avec le bus ou le
  registry.

## Commit 3 — `engine_observer.dart` (nouveau)
- Interface `EngineObserver` avec `onEngineEvent(EngineEvent)`.
- Découple les futurs observateurs (UI, logs, historique) du bus et du
  registry.

## Commit 4 — `engine_observer_registry.dart` (nouveau)
- `EngineObserverRegistry` : abonne un ensemble d'`EngineObserver` au
  `EngineEventBus`.
- Abonnement créé au premier `add()`, annulé dans `dispose()`.
- `add()` idempotent (pas de doublon), `remove()`, `count`.

## Tests
- `navigation_core_test.dart`
- `engine_history_test.dart`
- `engine_observer_registry_test.dart`

Les anciens stubs `engine_event_bus_test.dart` et `engine_registry_test.dart`
sont laissés tels quels (hors périmètre de ce lot).

## Compatibilité
Aucun fichier existant en dehors de `navigation_core.dart` n'est modifié.
Aucune API publique supprimée. `EngineObserver`/`EngineObserverRegistry`
sont des ajouts purs, non encore branchés sur `EngineRegistry` (prévu pour
un lot ultérieur : notifier automatiquement les observateurs lors de
`register`/`unregister`).
