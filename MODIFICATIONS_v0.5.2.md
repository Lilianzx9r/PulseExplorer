# PulseExplorer v0.5.2 — Catalogue dynamique des modèles IA

## Objectif

Récupérer les modèles disponibles directement auprès de chaque provider configuré et les proposer dans le Laboratoire IA.

## Fichiers ajoutés

- `lib/agents/model_catalog_service.dart`

## Fichiers modifiés

- `lib/ai_lab_screen.dart`
- `lib/agents/provider_models.dart`

## Fonctionnalités

- OpenRouter : récupération des modèles dont le prix d'entrée et de sortie est nul.
- Gemini : récupération paginée des modèles supportant `generateContent`.
- Mistral : récupération des modèles disponibles et compatibles avec le chat.
- Groq : récupération des modèles actifs, avec exclusion des modèles non conversationnels évidents.
- Sélection du modèle directement dans la configuration de chaque agent.
- Actualisation indépendante des modèles par provider.
- Affichage du niveau `Free`, `Free Tier` ou `Payant possible`.
- Conservation du modèle existant si aucun catalogue n'est disponible.

## Sources API

Les endpoints utilisés correspondent aux API officielles des providers :

- OpenRouter : `/api/v1/models`
- Google Gemini : `/v1beta/models`
- Mistral : `/v1/models`
- Groq : `/openai/v1/models`

## Tests à effectuer localement

```powershell
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build windows
```

## Limite connue

La disponibilité gratuite effective dépend du provider, du compte et de ses quotas. L'interface distingue donc `Free` et `Free Tier` au lieu de prétendre qu'un provider est toujours gratuit.
