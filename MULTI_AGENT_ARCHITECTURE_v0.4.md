# PulseExplorer v0.4 — architecture Free-First

Cette version ajoute une première couche de configuration autour des agents IA.

## Nouveautés

### Providers
- OpenRouter avec récupération dynamique des modèles gratuits via `/models`.
- `openrouter/free` reste utilisable comme modèle de secours.
- Gemini API directe.
- Provider générique compatible OpenAI pour Groq et Mistral.

### Agents
Une page `Laboratoire IA` permet de consulter et activer/désactiver les agents.
Les configurations sont persistées avec `SharedPreferences`.

### Sources
Une page permet d'activer/désactiver les sources prévues :
- OpenStreetMap / Overpass
- Nominatim
- Wikidata
- Wikipedia / Wikivoyage
- Wikimedia Commons

### Explorer
Le bouton de réglages en haut de l'écran Explorer ouvre le Laboratoire IA.
La liste des modèles gratuits OpenRouter est rafraîchie dynamiquement au lancement
lorsqu'une clé OpenRouter est configurée. Cela évite de dépendre uniquement de
modèles `:free` codés en dur.

## Compilation

```bash
flutter clean
flutter pub get
flutter analyze
flutter build windows
```

## Important

Les providers Gemini, Groq et Mistral sont préparés dans l'architecture mais leurs
clés et modèles doivent être configurés avant utilisation. La version actuelle
reste Free-First : aucun modèle payant OpenRouter n'est sélectionné automatiquement.
