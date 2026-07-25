// ─────────────────────────────────────────────────────────────────────────────
// poi_ai_common.dart
//
// Prompt et schéma JSON COMMUNS pour l'extraction de POI touristiques.
// Ce prompt est utilisé :
//   - par l'IA interne (appels OpenRouter dans html_poi_extractor.dart et
//     blog_poi_service.dart)
//   - par un agent externe (ChatGPT, Claude, Gemini, etc.) via copier-coller :
//     l'utilisateur copie ce prompt + son texte, le colle dans l'IA de son
//     choix, récupère le JSON produit, puis l'importe dans PulseGPX via
//     "Importer un JSON structuré" (onglet Analyser un blog).
//
// Le JSON produit doit toujours respecter le format :
//   { "destination": {...optionnel...}, "pois": [ {...}, {...} ] }
// ou directement un tableau [ {...}, {...} ].
//
// Champs reconnus par PulseGPX pour chaque POI (tous optionnels sauf name/nom
// et les coordonnées) :
//   name | nom            : nom exact du lieu (OBLIGATOIRE)
//   type                  : catégorie (voir liste ci-dessous)
//   description           : description courte (2-3 phrases)
//   lat | latitude        : latitude décimale (OBLIGATOIRE)
//   lon | longitude | lng : longitude décimale (OBLIGATOIRE)
//   precision             : "exacte" | "zone"
//   tips | conseils       : conseil pratique
//   opening_hours | horaires.ouverture : horaires
//   price_free | tarifs.gratuit        : true/false/null
//   price_adult | tarifs.adulte        : tarif adulte (nombre)
//   visit_duration_min | visite.duree_minutes : durée en minutes
//   best_time | visite.meilleur_moment : matin|après-midi|soirée|...
//   interest_score | interet.global    : score 0-10
//   interest_level | interet.niveau    : exceptionnel|incontournable|...
//   tags                  : tableau de mots-clés
//   day                   : numéro de jour dans l'itinéraire
//   image_query | image.query : requête de recherche d'image (PAS une URL)
// ─────────────────────────────────────────────────────────────────────────────

/// Prompt commun — utilisé par l'IA interne ET copiable pour un agent externe.
const String kCommonPoiPrompt = '''
Tu es un agent expert en extraction et enrichissement de données touristiques.
Analyse le texte fourni (article de blog, guide de voyage, itinéraire, récit...)
et extrais TOUS les points d'intérêt (POI) utiles à un voyageur : monuments,
musées, places, marchés, parcs, jardins, palais, quartiers, stades, sites
religieux, sites historiques ou naturels, villages, ports, plages, ponts,
rues remarquables, points de vue, spots photo, boutiques, restaurants, cafés,
bars, spectacles, expériences, et tout autre lieu géolocalisable mentionné.

Réponds UNIQUEMENT avec un JSON valide au format suivant, sans aucun texte ni
markdown autour :

{
  "destination": { "ville": "", "pays": "" },
  "pois": [
    {
      "name": "Nom exact du lieu",
      "type": "monument|musee|place|parc|jardin|palais|marche|quartier|stade|monument_religieux|site_historique|site_naturel|site_archeologique|village|port|plage|pont|rue_pittoresque|point_de_vue|spot_photo|shopping|restaurant|cafe|bar|spectacle|experience|autre",
      "description": "Description basée sur le texte (2-3 phrases)",
      "lat": 0.0,
      "lon": 0.0,
      "precision": "exacte ou zone",
      "tips": "Conseil pratique (réserver, venir tôt, meilleur moment...)",
      "opening_hours": "Horaires si connus, sinon null",
      "price_free": true,
      "price_adult": 0,
      "visit_duration_min": 60,
      "best_time": "matin|après-midi|soirée|coucher_de_soleil|lever_de_soleil|nuit",
      "interest_score": 8.5,
      "interest_level": "exceptionnel|incontournable|recommandé|complémentaire|optionnel",
      "tags": ["sunset", "photo_spot"],
      "day": 1,
      "image_query": "Requête de recherche d'image (PAS une URL)"
    }
  ]
}

RÈGLES CRITIQUES :
1. Le champ "name" doit être le NOM RÉEL du lieu tel qu'il apparaît dans le
   texte (ou son nom usuel connu). Ne jamais mettre "Coordonnées", "Point",
   "POI" ou toute valeur générique.
2. Les coordonnées "lat"/"lon" sont OBLIGATOIRES pour chaque POI. Cherche-les
   dans le texte d'abord ; si absentes, utilise ta connaissance géographique
   du lieu (ex: "Tour Eiffel" → lat: 48.8584, lon: 2.2945).
3. Ne JAMAIS omettre un lieu simplement parce que ses coordonnées ne sont pas
   écrites dans le texte — utilise ta connaissance.
4. Les quartiers et zones larges (plages, grands parcs) ont "precision":"zone";
   les lieux ponctuels (monuments, restaurants...) ont "precision":"exacte".
5. Score d'intérêt : bonus "incontournable" +3, "coup de cœur" +4,
   "à ne pas manquer" +3, "emblématique" +2, "exceptionnel" +2.
6. "image_query" est une REQUÊTE TEXTE pour chercher une image (ex: "Temple
   Debod sunset Madrid"), jamais une URL.
7. Si le texte décrit un itinéraire multi-jours, renseigne le champ "day"
   (1, 2, 3...) pour chaque POI correspondant.

Texte à analyser :
''';
