# PulseExplorer v0.5.1 — Providers IA multiples

## Base

Cette archive est basée sur les sources fournies dans `PulseExplorer_sources_20260727_121936.zip`.

## Objectif

Faire utiliser à Explorer le provider et le modèle définis dans le Laboratoire IA, au lieu de forcer OpenRouter pour tous les agents.

## Fichiers modifiés

- `lib/explorer_screen.dart`
- `lib/ai_lab_screen.dart`
- `lib/agents/agents.dart`
- `lib/agents/provider_factory.dart` (nouveau fichier)
- `lib/agents/provider_credentials.dart` (nouveau fichier)

## Fonctionnalités

- Provider sélectionnable par agent.
- Modèle sélectionnable par agent.
- Clés API locales séparées pour OpenRouter, Gemini, Mistral et Groq.
- Factory unique de création des providers.
- Support de Gemini via `GeminiProvider`.
- Support de Mistral et Groq via `OpenAiCompatibleProvider`.
- Explorer charge les agents sauvegardés par `AgentConfigurationStore`.
- Les agents désactivés ne sont pas exécutés.
- Une clé OpenRouter déjà configurée dans l'ancien mécanisme reste utilisable comme fallback.

## Fichiers ajoutés

- `lib/agents/provider_factory.dart`
- `lib/agents/provider_credentials.dart`
- `MODIFICATIONS_v0.5.1.md`

## Tests à effectuer localement

```powershell
flutter analyze
flutter test
flutter build windows
```

## Important

Le SDK Flutter n'est pas disponible dans l'environnement de préparation de cette archive. La compilation doit donc être validée dans l'environnement de développement local.
