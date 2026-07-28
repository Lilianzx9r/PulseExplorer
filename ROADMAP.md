# PulseExplorer — Roadmap

## Sprint 1 — Stabilisation ✅ (largement fait)
- [x] Gestion des clés API multi-providers (`ProviderKeyStore`,
      `ProviderKeyDialog`, `ProviderTestService`).
- [x] `AiProvider` enrichi (`connect/test/chat/models/supportsX`).
- [x] Providers additionnels : DeepSeek, Together.ai, Fireworks, Cerebras,
      SambaNova, Ollama, LM Studio.
- [ ] Migration physique vers l'arborescence cible (`providers/`,
      `services/`, `repositories/`, ...) — reportée, nécessite compilation
      vérifiable à chaque étape.

## Sprint 2 — Laboratoire IA (test/benchmark)
- [ ] Test individuel d'un agent avec sa configuration réelle (pas
      seulement du provider brut).
- [ ] Historique des tests (persistant, par provider/agent).
- [ ] Comparaison de plusieurs modèles sur une même requête.
- [ ] Benchmark simple (latence, taux de succès) sur un panel de requêtes
      types.

## Sprint 3 — Multi-agents ✅ (base posée)
- [x] `AgentOrchestrator` : timeout par agent, annulation implicite via
      timeout, journalisation (`AgentExecutionLog`).
- [x] Fusion/consensus réutilisée entre `AgentManager` et
      `AgentOrchestrator`.
- [x] 15 agents thématiques (`AgentPresets`).
- [ ] Score de confiance multi-critères (nombre d'agents, qualité de
      description, présence de coordonnées/photos/liens, fraîcheur,
      popularité) — actuellement le consensus ne fait que fusionner/
      dédoublonner, sans calcul de score pondéré.
- [ ] Vue "débat des agents" (accord/désaccord affichés à l'utilisateur).

## Sprint 4 — Sources
- [x] Abstraction `PoiSource` (`search/details/images/categories`).
- [x] Première source concrète : Wikidata.
- [ ] Ré-exposition d'Overpass/OSM derrière `PoiSource` (le code existe déjà
      sous une autre forme : `overpass_service.dart`, `overpass_poi_service.dart`).
- [ ] Wikipedia / Wikivoyage, Wikimedia Commons (résolution d'images).
- [ ] GeoNames, OpenTripMap, DataTourisme, OpenRouteService.
- [ ] Service d'enrichissement combinant plusieurs `PoiSource` pour un même
      POI (géocodage, photos, résumé, horaires, distance).

## Sprint 5 — Roadbook
- [ ] Optimisation d'étapes / calcul de boucle.
- [ ] Export PDF du roadbook.
- [ ] Export Garmin / OsmAnd / Kurviger (au-delà du GPX déjà existant).

## Sprint 6 (nouveau) — Plugins
- [ ] Interface plugin (`id/name/version/description/author/license`).
- [ ] Découverte automatique des plugins `agents/`, `providers/`,
      `sources/`, `exports/`.

## Note de méthode
Les cases cochées reflètent l'état réel du code après relecture manuelle
(pas d'exécution de `flutter analyze` possible dans l'environnement de
génération actuel). **Merci de lancer `flutter analyze` après chaque
livraison et de signaler toute erreur** — c'est la seule vérification de
compilation fiable tant que le développement se fait via ce chat plutôt que
via un environnement avec SDK Flutter connecté (ex. Claude Code).
