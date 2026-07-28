# PulseExplorer v0.5.1 — Corrections de compilation

## Erreurs corrigées

### `lib/agents/provider_factory.dart`
Ajout de l'import explicite de `discovery_agent.dart`, nécessaire pour le type `DiscoveryAgent` utilisé par `AgentProviderFactory.createAgent`.

### `lib/explorer_screen.dart`
- Suppression de la référence à `_enabled`, qui n'existe plus depuis l'utilisation de `AgentDefinition.enabled`.
- Remplacement de `definition.label` par `definition.name`.
- Ajout de `_setAgentEnabled(...)` pour mettre à jour `AgentDefinition.enabled` et sauvegarder la configuration.

### `lib/agents/agent_definition.dart`
Le fichier est inclus dans l'archive afin de conserver la définition compatible avec la configuration persistante actuelle.

## Fichiers modifiés

- `lib/agents/provider_factory.dart`
- `lib/explorer_screen.dart`

## Fichier inclus pour cohérence

- `lib/agents/agent_definition.dart`

## Tests à effectuer

```powershell
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build windows
```
