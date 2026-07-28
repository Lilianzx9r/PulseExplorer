# navigation_v2 — État d'implémentation

## core/ — présents et inchangés dans ce lot
- engine_event.dart
- engine_event_bus.dart
- engine_exception.dart
- engine_health.dart
- engine_registration.dart
- engine_registry.dart
- engine_registry_extensions.dart
- event_bus.dart
- navigation_context.dart
- navigation_engine.dart
- navigation_engine_state.dart
- navigation_event.dart
- navigation_result.dart
- navigation_state.dart
- snapshot_controller.dart

## core/ — modifiés / ajoutés par ce lot (PR002.2-L1)
- navigation_core.dart (fix structure + encapsulation) — Commit 1
- engine_history.dart (nouveau) — Commit 2
- engine_observer.dart (nouveau) — Commit 3
- engine_observer_registry.dart (nouveau) — Commit 4

## Non fait / prochain lot
- Brancher `EngineObserverRegistry` sur `EngineRegistry` (notification
  automatique à `register`/`unregister`/`clear`).
- Faire écrire `EngineEventBus` dans `EngineHistory` automatiquement
  (aujourd'hui `EngineHistory.record()` doit être appelé manuellement).
- `navigation_v2.dart` (barrel file) à mettre à jour pour exporter les
  nouveaux fichiers si on veut les rendre publics hors du package.
- `NavigationCore` reste un point d'entrée minimal, non encore relié à
  `EngineRegistry`/`NavigationEngine` (orchestration réelle prévue lot
  suivant).

## Vérification
Ce lot n'a pas été compilé dans cet environnement (pas de SDK Flutter
disponible ici). Merci de lancer :
```
flutter analyze
flutter test test/navigation_v2/core/
```
et de me signaler toute erreur.
