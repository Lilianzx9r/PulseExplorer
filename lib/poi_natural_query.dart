// ─────────────────────────────────────────────────────────────────────────────
// poi_natural_query.dart
//
// Traduction d'une requête en langage naturel ("restaurant italien",
// "boulangerie", "station essence") vers un ensemble de catégories OSM
// connues (kPoiCategories) + un éventuel modificateur "cuisine".
//
// Approche 100% locale (dictionnaire + tolérance aux fautes de frappe),
// sans réseau — utilisée en premier. Si elle ne résout rien, l'appelant
// peut se rabattre sur PoiKeywordAiResolver (agents/poi_keyword_ai_resolver.dart)
// quand une connexion est disponible, ou sur une recherche par nom brute.
// ─────────────────────────────────────────────────────────────────────────────

/// Une entrée du dictionnaire : un terme (normalisé) associé à une
/// catégorie OSM connue.
class _KeywordEntry {
  final String term; // normalisé : minuscules, sans accents
  final String categoryId;
  const _KeywordEntry(this.term, this.categoryId);
}

/// Modificateur "cuisine" (uniquement pertinent pour restaurant/cafe).
class _CuisineEntry {
  final String term; // terme tel que tapé par l'utilisateur (normalisé)
  final String osmValue; // valeur du tag OSM `cuisine`
  const _CuisineEntry(this.term, this.osmValue);
}

/// Résultat de l'interprétation d'une requête libre.
class PoiNaturalQueryResult {
  final List<String> categoryIds;
  final String? cuisineFilter;
  final String rawQuery;

  const PoiNaturalQueryResult({
    required this.categoryIds,
    required this.rawQuery,
    this.cuisineFilter,
  });

  bool get resolved => categoryIds.isNotEmpty;
}

class PoiKeywordDictionary {
  PoiKeywordDictionary._();

  // Termes triés du plus long/spécifique au plus court : les correspondances
  // exactes sont recherchées dans cet ordre pour privilégier "station
  // essence" à "essence" seul, par exemple.
  static final List<_KeywordEntry> _entries = [
    _KeywordEntry('parking camping car', 'parking'),
    _KeywordEntry('borne de recharge', 'charging_station'),
    _KeywordEntry('borne electrique', 'charging_station'),
    _KeywordEntry('station de recharge', 'charging_station'),
    _KeywordEntry('recharge electrique', 'charging_station'),
    _KeywordEntry('station essence', 'fuel'),
    _KeywordEntry('station service', 'fuel'),
    _KeywordEntry('point de vue', 'viewpoint'),
    _KeywordEntry('site archeologique', 'ruins'),
    _KeywordEntry('chute d eau', 'waterfall'),
    _KeywordEntry('salon de the', 'cafe'),

    _KeywordEntry('hotel', 'hotel'),
    _KeywordEntry('motel', 'hotel'),
    _KeywordEntry('auberge', 'hotel'),
    _KeywordEntry('gite', 'hotel'),
    _KeywordEntry('musee', 'museum'),
    _KeywordEntry('monument', 'monument'),
    _KeywordEntry('memorial', 'monument'),
    _KeywordEntry('panorama', 'viewpoint'),
    _KeywordEntry('belvedere', 'viewpoint'),
    _KeywordEntry('camping', 'camping'),
    _KeywordEntry('attraction', 'attraction'),
    _KeywordEntry('chateau', 'castle'),
    _KeywordEntry('forteresse', 'castle'),
    _KeywordEntry('palais', 'castle'),
    _KeywordEntry('ruines', 'ruins'),
    _KeywordEntry('restaurant', 'restaurant'),
    _KeywordEntry('restau', 'restaurant'),
    _KeywordEntry('resto', 'restaurant'),
    _KeywordEntry('pizzeria', 'restaurant'),
    _KeywordEntry('creperie', 'restaurant'),
    _KeywordEntry('cafe', 'cafe'),
    _KeywordEntry('parking', 'parking'),
    _KeywordEntry('essence', 'fuel'),
    _KeywordEntry('carburant', 'fuel'),
    _KeywordEntry('gasoil', 'fuel'),
    _KeywordEntry('diesel', 'fuel'),
    _KeywordEntry('chapelle', 'chapel'),
    _KeywordEntry('eglise', 'chapel'),
    _KeywordEntry('sommet', 'peak'),
    _KeywordEntry('pic', 'peak'),
    _KeywordEntry('cascade', 'waterfall'),
    _KeywordEntry('chute', 'waterfall'),
    _KeywordEntry('lac', 'lake'),
    _KeywordEntry('etang', 'lake'),
    _KeywordEntry('grotte', 'cave'),
    _KeywordEntry('caverne', 'cave'),
    _KeywordEntry('boulangerie', 'bakery'),
    _KeywordEntry('boulanger', 'bakery'),
    _KeywordEntry('patisserie', 'bakery'),
    _KeywordEntry('pharmacie', 'pharmacy'),
    _KeywordEntry('pharma', 'pharmacy'),
    _KeywordEntry('hopital', 'hospital'),
    _KeywordEntry('clinique', 'hospital'),
    _KeywordEntry('urgences', 'hospital'),
  ];

  static final List<_CuisineEntry> _cuisines = [
    _CuisineEntry('italien', 'italian'),
    _CuisineEntry('italienne', 'italian'),
    _CuisineEntry('francais', 'french'),
    _CuisineEntry('francaise', 'french'),
    _CuisineEntry('japonais', 'japanese'),
    _CuisineEntry('chinois', 'chinese'),
    _CuisineEntry('indien', 'indian'),
    _CuisineEntry('mexicain', 'mexican'),
    _CuisineEntry('pizza', 'pizza'),
    _CuisineEntry('kebab', 'kebab'),
    _CuisineEntry('vegetarien', 'vegetarian'),
    _CuisineEntry('vegan', 'vegan'),
    _CuisineEntry('burger', 'burger'),
    _CuisineEntry('sushi', 'sushi'),
  ];

  /// Minuscules + suppression des accents/diacritiques + espaces normalisés.
  static const Map<String, String> _accentMap = {
    'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'î': 'i', 'ï': 'i', 'í': 'i', 'ì': 'i',
    'ô': 'o', 'ö': 'o', 'ó': 'o', 'ò': 'o',
    'ù': 'u', 'û': 'u', 'ü': 'u', 'ú': 'u',
    'ç': 'c', 'ñ': 'n',
  };

  static String normalize(String input) {
    var s = input.toLowerCase().trim();
    _accentMap.forEach((accented, plain) {
      s = s.replaceAll(accented, plain);
    });
    s = s.replaceAll(RegExp(r"[-'’]"), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  /// Distance de Levenshtein simple (pour tolérer 1-2 fautes de frappe).
  static int levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final prev = List<int>.generate(b.length + 1, (i) => i);
    final curr = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = [
          curr[j - 1] + 1,      // insertion
          prev[j] + 1,          // suppression
          prev[j - 1] + cost,   // substitution
        ].reduce((x, y) => x < y ? x : y);
      }
      for (var j = 0; j <= b.length; j++) prev[j] = curr[j];
    }
    return prev[b.length];
  }

  static bool _fuzzyMatch(String token, String term) {
    if (token == term) return true;
    // Préfixe : "restau" → "restaurant" (le token doit faire au moins 4
    // caractères pour éviter les faux positifs sur des mots courts).
    if (token.length >= 4 && term.startsWith(token)) return true;
    // Tolérance aux fautes de frappe, calibrée sur la longueur du terme
    // cible (plus le mot est long, plus on tolère d'erreurs).
    final maxDist = term.length <= 5 ? 1 : 2;
    return levenshtein(token, term) <= maxDist;
  }
}

class PoiNaturalQueryParser {
  PoiNaturalQueryParser._();

  static PoiNaturalQueryResult parse(String rawQuery) {
    final normalized = PoiKeywordDictionary.normalize(rawQuery);
    if (normalized.isEmpty) {
      return PoiNaturalQueryResult(categoryIds: const [], rawQuery: rawQuery);
    }

    final matchedCategories = <String>{};
    var remaining = ' $normalized ';

    // 1) Correspondances exactes (substring), du terme le plus long au plus
    // court, pour que les expressions composées ("station essence") priment
    // sur leurs sous-termes ("essence").
    final entriesByLength = [...PoiKeywordDictionary._entries]
      ..sort((a, b) => b.term.length.compareTo(a.term.length));
    for (final entry in entriesByLength) {
      if (remaining.contains(' ${entry.term} ')) {
        matchedCategories.add(entry.categoryId);
        remaining = remaining.replaceAll(' ${entry.term} ', '  ');
      }
    }

    // 2) Si rien trouvé par substring, tolérance aux fautes de frappe sur
    // chaque mot de la requête (un seul mot ne matche qu'une entrée).
    if (matchedCategories.isEmpty) {
      final tokens = normalized.split(' ').where((t) => t.isNotEmpty);
      for (final token in tokens) {
        for (final entry in PoiKeywordDictionary._entries) {
          if (!entry.term.contains(' ') &&
              PoiKeywordDictionary._fuzzyMatch(token, entry.term)) {
            matchedCategories.add(entry.categoryId);
            break;
          }
        }
      }
    }

    // 3) Modificateur cuisine (indépendant de la présence d'une catégorie —
    // "italien" seul sous-entend "restaurant").
    String? cuisine;
    for (final c in PoiKeywordDictionary._cuisines) {
      if (remaining.contains(' ${c.term} ') ||
          normalized.split(' ').any((t) => PoiKeywordDictionary._fuzzyMatch(t, c.term))) {
        cuisine = c.osmValue;
        matchedCategories.add('restaurant');
        break;
      }
    }

    return PoiNaturalQueryResult(
      categoryIds: matchedCategories.toList(),
      cuisineFilter: cuisine,
      rawQuery: rawQuery,
    );
  }
}
