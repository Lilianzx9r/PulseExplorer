# PR002.2 — Lot 2

Branche l'historique et les observateurs sur `EngineRegistry`, comme prévu
dans `IMPLEMENTATION_STATUS.md` (section "Non fait / prochain lot").

## Commit 1 — `engine_registry.dart`
- `EngineRegistry` prend désormais un `EngineEventBus?` optionnel en
  constructeur (`EngineRegistry({EngineEventBus? eventBus})`).
- `register()` publie un `EngineEvent(type: registered)`.
- `unregister()` publie un `EngineEvent(type: unregistered)` (seulement si
  un engine a effectivement été retiré).
- `clear()` publie un événement `unregistered` par engine retiré.
- **Compatibilité** : `EngineRegistry()` sans argument garde le
  comportement exact d'avant (aucun événement publié, aucune dépendance
  au bus).

## Commit 2 — `engine_history.dart`
- Ajout de `attach(EngineEventBus bus)` : abonnement automatique, chaque
  événement publié est enregistré via `record()`.
- Ajout de `detach()` : annule l'abonnement (l'historique déjà enregistré
  est conservé).
- Rappeler `attach()` avec un autre bus remplace proprement l'abonnement
  précédent.
- **Compatibilité** : `record()` manuel toujours utilisable indépendamment
  (aucun bus requis).

## Commit 3 — `navigation_v2.dart` (barrel) + tests
- Le barrel exporte maintenant l'ensemble de `core/` (event bus, registry,
  history, observer, observer registry, navigation_core, etc.), plus
  seulement 3 fichiers comme avant.
- `engine_registry_test.dart` et `engine_history_test.dart` remplacent les
  anciens stubs vides par de vrais tests (registry seul, registry + bus,
  history manuelle, history attachée à un bus).

## Non branché volontairement dans ce lot
- `EngineObserverRegistry` n'est pas automatiquement créé/attaché par
  `EngineRegistry` : c'est à l'appelant de créer son
  `EngineEventBus`/`EngineHistory`/`EngineObserverRegistry` et de les
  relier (voir tests pour l'usage). Un couplage plus fort (par ex.
  `EngineRegistry` créant son propre bus par défaut) peut être fait dans
  un lot ultérieur si tu le souhaites, mais casserait la signature
  actuelle de `EngineRegistry()`.
- `NavigationCore` toujours pas relié à `EngineRegistry` (orchestration
  réelle) — prochain lot naturel.

## Vérification
```
flutter analyze
flutter test test/navigation_v2/core/
```
