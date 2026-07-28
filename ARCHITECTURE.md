# PulseExplorer — Architecture

## Vision

PulseExplorer évolue progressivement vers une plateforme d'exploration
touristique multi-agents : plusieurs agents IA spécialisés interrogent
plusieurs fournisseurs (OpenRouter, Gemini, Groq, Mistral, ...) et plusieurs
sources de données ouvertes, produisent des propositions de POI concurrentes,
qui sont ensuite fusionnées, dédoublonnées et scorées.

## État actuel (au 2026-07-28)

### Ce qui existe et fonctionne
- `lib/agents/ai_provider.dart` — interface `AiProvider` complète :
  `complete()`, `connect()`, `test()`, `chat()`, `models()`,
  `supportsVision/Tools/Streaming/Json/FunctionCalling/Embeddings/Reasoning()`.
  Implémentations par défaut fournies : un provider concret n'a besoin de
  surcharger que ce qui le distingue réellement.
- Providers concrets : `OpenRouterProvider`, `GeminiProvider`,
  `OpenAiCompatibleProvider` (générique, utilisé pour Groq, Mistral,
  DeepSeek, Together.ai, Fireworks, Cerebras, SambaNova, Ollama, LM Studio).
- `lib/agents/provider_models.dart` (`ProviderCatalog`) — catalogue déclaratif
  des 10 providers ci-dessus (nom, description, mode de coût).
- `lib/agents/provider_key_store.dart` — stockage local multi-providers des
  clés API et des URL de base (providers locaux).
- `lib/agents/provider_test_service.dart` — construction de provider +
  test de connexion à la demande (jamais automatique).
- `lib/widgets/provider_key_dialog.dart` — UI de saisie/test/enregistrement
  d'une clé, branchée dans `ai_lab_screen.dart` (onglet Providers).
- `lib/agents/agent_definition.dart` / `agent_presets.dart` — modèle d'agent
  configurable (nom, description, rôle, provider, modèle, instructions,
  activé/désactivé) + catalogue des 15 agents thématiques cibles (Moto,
  Nature, Patrimoine, Photographie, Gastronomie, Randonnée, UNESCO, Camping,
  Road Trip, Famille, Histoire, Architecture, Panoramas, Insolite, Local).
- `lib/agents/agent_manager.dart` — orchestration parallèle simple +
  dédoublonnage/fusion (nom normalisé + proximité géographique).
- `lib/agents/agent_orchestrator.dart` — orchestrateur enrichi : timeout
  individuel par agent, journalisation (`AgentExecutionLog`), réutilise la
  fusion de `AgentManager` sans dupliquer la logique.
- `lib/agents/poi_consensus.dart` — `ConsensusPoi` / `AgentOpinion` (opinions
  multiples par POI fusionné).
- `lib/sources/poi_source.dart` — abstraction `PoiSource`
  (`search/details/images/categories`).
- `lib/sources/wikidata_source.dart` — première implémentation concrète
  (recherche par label et recherche géographique SPARQL, sans clé API).
- `lib/ai_lab_screen.dart` — Laboratoire IA : onglets Agents / Providers /
  Sources, entièrement fonctionnel pour la configuration des clés.

### Ce qui n'existe pas encore (dette vs. cible)
- Arborescence physique cible (`lib/providers/`, `lib/services/`,
  `lib/repositories/`, `lib/models/`, `lib/exports/`, `lib/utils/`,
  `lib/plugins/`) : **non créée**. Les fichiers actuels restent dans
  `lib/agents/` et `lib/` (racine), pattern historique du projet. Une
  migration physique (déplacer les fichiers + corriger tous les imports sur
  l'ensemble du projet) est un chantier à part entière : elle touche
  potentiellement des dizaines de fichiers et **doit être vérifiée par
  `flutter analyze` réel**, ce qui n'est pas possible dans l'environnement
  actuel de génération de code (pas de SDK Flutter installé). Elle est donc
  volontairement reportée à une session où la compilation peut être
  vérifiée à chaque étape (ex. Claude Code / CI locale).
- Sources supplémentaires : OpenStreetMap/Overpass (existent déjà sous forme
  de services historiques `overpass_service.dart`/`overpass_poi_service.dart`,
  mais pas encore ré-exposés derrière l'interface `PoiSource`), Wikipedia,
  Wikimedia Commons, GeoNames, OpenTripMap, DataTourisme, OpenRouteService.
- Enrichissement automatique post-découverte (photos, résumé, horaires,
  distance, avis) au-delà de ce que fait déjà `html_poi_extractor.dart`.
- Moteur Roadbook (optimisation d'étapes, export PDF, Garmin, OsmAnd,
  Kurviger). L'export GPX existe déjà (`gpx_loader.dart`, `poi_export.dart`).
- Architecture plugins (`plugins/agents`, `plugins/providers`,
  `plugins/sources`, `plugins/exports` avec découverte automatique).
- Réduction des `StatefulWidget` volumineux existants (`main.dart` 128K,
  `gpx_only_view.dart` 100K, etc.) — non touchés par choix de prudence.

## Principes de développement (rappel)

- Partir systématiquement des sources existantes, ne jamais tout réécrire.
- Chaque livraison doit rester compilable.
- Les widgets ne contiennent pas de logique métier ; celle-ci va dans
  `lib/agents/`, `lib/sources/`, ou à terme `lib/services/`.
- Un agent = une mission/un point de vue, pas un agent = une source :
  plusieurs sources peuvent alimenter un même agent.
