# PulseExplorer — v0.5.4 — Sprint 1 / Commit 1

## Objectif
Stabilisation de la gestion des clés API : jusqu'ici, seule la clé OpenRouter
était configurable (via l'onglet "Analyser un blog", `HtmlPoiExtractor.apiKey`).
Gemini, Groq et Mistral étaient déjà déclarés dans `ProviderCatalog` mais sans
aucun moyen de saisir une clé : le Laboratoire IA les affichait en dur comme
"à configurer".

## Fichiers modifiés
- `lib/ai_lab_screen.dart`
  - L'onglet "Providers" affiche désormais un état réel (clé présente ou non)
    pour chaque provider du `ProviderCatalog`, pas seulement OpenRouter.
  - Chaque carte provider est cliquable et ouvre `ProviderKeyDialog`.
  - Après enregistrement d'une clé OpenRouter, synchronisation automatique
    avec `HtmlPoiExtractor.setApiKey(...)` pour ne rien casser dans les
    écrans existants (analyse de blog, extraction HTML) qui dépendent encore
    de cette clé statique.

## Nouveaux fichiers
- `lib/agents/provider_key_store.dart`
  Stockage générique multi-providers des clés API (SharedPreferences, JSON
  `{providerId: clé}`). Remplace le pattern "une seule clé globale".
- `lib/agents/provider_test_service.dart`
  Service de test de connexion à la demande. Construit un `AiProvider`
  (OpenRouter / Gemini / Groq / Mistral via `OpenAiCompatibleProvider`) et
  effectue un appel minimal ("réponds OK") avec timeout 30s. Ne s'exécute
  **jamais automatiquement** : uniquement sur action explicite de
  l'utilisateur.
- `lib/widgets/provider_key_dialog.dart`
  Dialogue réutilisable : saisie de la clé (masquée/visible), champ modèle de
  test, bouton "Tester la connexion" (asynchrone, avec indicateur de
  chargement), affichage du résultat, boutons Enregistrer / Supprimer la clé
  / Annuler.

## Fichiers supprimés
Aucun.

## Explication technique — correction du bug remonté
Le bug "erreur affichée immédiatement à la saisie" venait de l'absence totale
de dialogue de clé pour Gemini/Groq/Mistral : il n'y avait tout simplement
aucun champ dédié pour ces providers, donc toute tentative de configuration
passait par un chemin non prévu. La nouvelle implémentation :
- ne valide/teste **jamais** au fil de la frappe (`onChanged`) : le test est
  déclenché uniquement par le bouton "Tester la connexion" ;
- affiche un message d'erreur clair et ciblé (401/403 = clé refusée,
  429 = quota, timeout = pas de réponse) plutôt qu'une exception brute ;
- permet d'enregistrer une clé sans forcément la tester au préalable (le test
  reste recommandé mais optionnel).

## Compatibilité / non-régression
- `HtmlPoiExtractor.apiKey` reste la source de vérité utilisée par les écrans
  existants (`html_poi_screen.dart`, `blog_poi_service.dart`, etc.) : cette
  livraison ne les modifie pas. Le nouveau flux se contente de le maintenir
  synchronisé quand la clé OpenRouter est modifiée depuis le Laboratoire IA.
- `AgentManager`, `AgentDefinition`, `ProviderCatalog`, `OpenRouterProvider`,
  `GeminiProvider`, `OpenAiCompatibleProvider` : aucune modification, aucune
  signature changée.

## Tests à réaliser
1. Ouvrir le Laboratoire IA → onglet Providers.
2. Vérifier que les 4 providers (OpenRouter, Gemini, Mistral, Groq)
   apparaissent avec le bon statut initial (probablement "À configurer" pour
   tous sauf OpenRouter si une clé a déjà été saisie précédemment).
3. Toucher "Google Gemini" → saisir une clé Gemini valide → "Tester la
   connexion" → vérifier l'affichage "Connexion réussie (xx ms)".
4. Saisir une clé volontairement invalide → tester → vérifier le message
   "Clé API refusée (401/403)" plutôt qu'une exception brute.
5. Enregistrer → revenir sur l'onglet Providers → vérifier que "Google
   Gemini" passe à "Configuré".
6. Rouvrir le dialogue → "Supprimer la clé" → vérifier le retour à "À
   configurer".
7. Vérifier qu'OpenRouter continue de fonctionner comme avant dans l'écran
   "Analyser un blog" après avoir modifié sa clé depuis le Laboratoire IA.

## Commandes Flutter
```bash
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build windows
```

## Limite connue de cette livraison
`AiProvider` reste une interface minimale (`complete()` uniquement). L'ajout
de `connect()/test()/chat()/models()/supportsX()` prévu dans la cible
d'architecture sera traité dans une livraison Sprint 1 ultérieure, une fois
la gestion des clés validée en conditions réelles.
