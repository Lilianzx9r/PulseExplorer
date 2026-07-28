# Changelog

## v0.6.0 — 2026-07-28

### Ajouté
- `AiProvider` enrichi avec `connect()`, `test()`, `chat()`, `models()` et les
  drapeaux de capacité (`supportsVision/Tools/Streaming/Json/
  FunctionCalling/Embeddings/Reasoning`), avec implémentations par défaut.
- Nouveaux providers dans `ProviderCatalog` : DeepSeek, Together.ai,
  Fireworks, Cerebras, SambaNova, Ollama (local), LM Studio (local).
- `ProviderKeyDialog` gère désormais aussi les providers locaux (champ URL,
  clé optionnelle).
- `ProviderKeyStore` : stockage des URL de base par provider
  (`loadAllBaseUrls/loadBaseUrl/saveBaseUrl`).
- `AgentOrchestrator` (`lib/agents/agent_orchestrator.dart`) : exécution
  parallèle avec timeout individuel par agent, journalisation
  (`AgentExecutionLog`), statistiques de run (`OrchestrationResult`).
- `AgentManager.mergeExternalResults()` : logique de fusion exposée pour être
  réutilisée par `AgentOrchestrator` sans duplication.
- `lib/agents/agent_presets.dart` : catalogue des 15 agents thématiques
  (Moto, Nature, Patrimoine, Photographie, Gastronomie, Randonnée, UNESCO,
  Camping, Road Trip, Famille, Histoire, Architecture, Panoramas, Insolite,
  Local).
- `lib/sources/poi_source.dart` : abstraction `PoiSource`
  (`search/details/images/categories`).
- `lib/sources/wikidata_source.dart` : première source concrète (recherche
  par label et recherche géographique via SPARQL, sans clé API).
- `ARCHITECTURE.md`, `ROADMAP.md`, `CHANGELOG.md`.

### Modifié
- `ai_lab_screen.dart` : le catalogue d'agents par défaut passe de 4 agents
  génériques aux 15 agents thématiques (`AgentPresets.all`). Les
  configurations déjà sauvegardées par l'utilisateur restent prioritaires.
- `OpenRouterProvider`, `GeminiProvider`, `OpenAiCompatibleProvider` :
  passent de `implements AiProvider` à `extends AiProvider` pour hériter des
  implémentations par défaut ; ajout d'overrides pertinents
  (`connect()`, `models()` dynamique pour OpenRouter, drapeaux de capacité).

### Non modifié (compatibilité)
- Aucune signature publique existante supprimée. `explorer_screen.dart`
  (seul consommateur externe de `AiProvider` en dehors de `lib/agents/`)
  n'utilise que `.id/.name/.complete()`, non affecté par l'enrichissement de
  l'interface.

## v0.5.4 — 2026-07-28
- Gestion des clés API multi-providers (Sprint 1, commit 1) :
  `ProviderKeyStore`, `ProviderTestService`, `ProviderKeyDialog`, onglet
  Providers du Laboratoire IA rendu fonctionnel pour Gemini/Mistral/Groq en
  plus d'OpenRouter.
