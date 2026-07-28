import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'poi_layer.dart';
import 'poi_search_filters.dart';
import 'core/services/overpass_http_client.dart';

/// Catégorie de POI touristique avec son filtre Overpass
class PoiCategory {
  final String id;
  final String label;
  final String emoji;
  final String overpassFilter; // filtre Overpass QL
  final Color  color;
  bool selected;

  PoiCategory({
    required this.id,
    required this.label,
    required this.emoji,
    required this.overpassFilter,
    required this.color,
    this.selected = true,
  });
}

final kPoiCategories = <PoiCategory>[
  // ── Tourism ────────────────────────────────────────────────────────────────
  PoiCategory(id: 'hotel',      label: 'Hôtels',        emoji: '🏨',
    overpassFilter: '["tourism"~"hotel|motel|hostel|guest_house"]',
    color: const Color(0xFF1565C0)),
  PoiCategory(id: 'museum',     label: 'Musées',         emoji: '🖼️',
    overpassFilter: '["tourism"="museum"]',
    color: const Color(0xFF6A1B9A)),
  PoiCategory(id: 'monument',   label: 'Monuments',      emoji: '🏛️',
    overpassFilter: '["tourism"~"monument|memorial|artwork"]',
    color: const Color(0xFF4527A0)),
  PoiCategory(id: 'viewpoint',  label: 'Points de vue',  emoji: '🔭',
    overpassFilter: '["tourism"="viewpoint"]',
    color: const Color(0xFF00838F)),
  PoiCategory(id: 'camping',    label: 'Campings',       emoji: '⛺',
    overpassFilter: '["tourism"~"camp_site|caravan_site"]',
    color: const Color(0xFF2E7D32)),
  PoiCategory(id: 'attraction', label: 'Attractions',    emoji: '🎡',
    overpassFilter: '["tourism"="attraction"]',
    color: const Color(0xFFE65100)),
  PoiCategory(id: 'castle',     label: 'Châteaux',       emoji: '🏰',
    overpassFilter: '["historic"~"castle|fort|palace"]',
    color: const Color(0xFF4E342E)),
  PoiCategory(id: 'ruins',      label: 'Ruines',         emoji: '🏚️',
    overpassFilter: '["historic"~"ruins|archaeological_site"]',
    color: const Color(0xFF795548)),
  // ── Amenity ────────────────────────────────────────────────────────────────
  PoiCategory(id: 'restaurant', label: 'Restaurants',    emoji: '🍽️',
    overpassFilter: '["amenity"="restaurant"]',
    color: const Color(0xFFD84315)),
  PoiCategory(id: 'cafe',       label: 'Cafés',          emoji: '☕',
    overpassFilter: '["amenity"~"cafe|coffee_shop"]',
    color: const Color(0xFF5D4037)),
  PoiCategory(id: 'parking',    label: 'Parkings',       emoji: '🅿️',
    overpassFilter: '["amenity"="parking"]',
    color: const Color(0xFF455A64)),
  PoiCategory(id: 'fuel',       label: 'Stations',       emoji: '⛽',
    overpassFilter: '["amenity"="fuel"]',
    color: const Color(0xFF37474F)),
  PoiCategory(id: 'chapel',     label: 'Chapelles',      emoji: '⛪',
    overpassFilter: '["amenity"~"place_of_worship"]["building"~"chapel|church"]',
    color: const Color(0xFF1A237E)),
  // ── Natural ────────────────────────────────────────────────────────────────
  PoiCategory(id: 'peak',       label: 'Sommets',        emoji: '⛰️',
    overpassFilter: '["natural"="peak"]',
    color: const Color(0xFF558B2F)),
  PoiCategory(id: 'waterfall',  label: 'Cascades',       emoji: '💧',
    overpassFilter: '["waterway"="waterfall"]',
    color: const Color(0xFF0277BD)),
  PoiCategory(id: 'lake',       label: 'Lacs',           emoji: '🌊',
    overpassFilter: '["natural"~"water|lake"]["water"~"lake|reservoir"]',
    color: const Color(0xFF0288D1)),
  PoiCategory(id: 'cave',       label: 'Grottes',        emoji: '🕳️',
    overpassFilter: '["natural"="cave_entrance"]',
    color: const Color(0xFF37474F)),
  // ── Ajoutés pour la recherche multicritère ────────────────────────────────
  PoiCategory(id: 'bakery',     label: 'Boulangeries',   emoji: '🥖',
    overpassFilter: '["shop"="bakery"]',
    color: const Color(0xFFBF7B2E)),
  PoiCategory(id: 'pharmacy',   label: 'Pharmacies',     emoji: '💊',
    overpassFilter: '["amenity"="pharmacy"]',
    color: const Color(0xFF2E7D32)),
  PoiCategory(id: 'charging_station', label: 'Bornes de recharge', emoji: '⚡',
    overpassFilter: '["amenity"="charging_station"]',
    color: const Color(0xFFF9A825)),
  PoiCategory(id: 'hospital',   label: 'Hôpitaux',       emoji: '🏥',
    overpassFilter: '["amenity"~"hospital|clinic"]',
    color: const Color(0xFFC62828)),
];



/// Helpers de recherche sur les catégories.
extension PoiCategoryLookup on Iterable<PoiCategory> {
  PoiCategory? byId(String id)=>cast<PoiCategory?>().firstWhere((c)=>c!.id==id,orElse:()=>null);
  PoiCategory? byLabel(String label)=>cast<PoiCategory?>().firstWhere((c)=>c!.label==label,orElse:()=>null);
  PoiCategory? byEmoji(String emoji)=>cast<PoiCategory?>().firstWhere((c)=>c!.emoji==emoji,orElse:()=>null);
  Iterable<PoiCategory> get selected=>where((c)=>c.selected);
}

class OverpassPoiResult {
  final String   name;
  final double   lat;
  final double   lon;
  final String   categoryId;
  final String   emoji;
  final Map<String, String> tags;
  /// Distance au point de référence (centre carte ou position utilisateur),
  /// en mètres. Renseignée uniquement si `sortOrigin` a été fourni à
  /// [OverpassPoiService.search]. Null sinon (pas de calcul inutile).
  final double?  distanceMeters;

  OverpassPoiResult({
    required this.name,
    required this.lat,
    required this.lon,
    required this.categoryId,
    required this.emoji,
    required this.tags,
    this.distanceMeters,
  });

  /// Libellé lisible de la distance ("120 m" / "3,4 km").
  String? get distanceLabel {
    final d = distanceMeters;
    if (d == null) return null;
    if (d < 1000) return '${d.round()} m';
    return '${(d / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
  }

  OverpassPoiResult copyWithDistance(double meters) => OverpassPoiResult(
    name: name, lat: lat, lon: lon, categoryId: categoryId,
    emoji: emoji, tags: tags, distanceMeters: meters,
  );

  PoiPoint toPoiPoint() => PoiPoint(
    name:        name,
    lat:         lat,
    lon:         lon,
    type:        categoryId,
    description: _buildDescription(),
  );

  String _buildDescription() {
    final parts = <String>[];
    if (tags['description'] != null)     parts.add(tags['description']!);
    if (tags['opening_hours'] != null)   parts.add('Horaires : ${tags['opening_hours']}');
    if (tags['website'] != null)         parts.add(tags['website']!);
    if (tags['phone'] != null)           parts.add('📞 ${tags['phone']}');
    if (tags['ele'] != null)             parts.add('Altitude : ${tags['ele']} m');
    return parts.join('\n');
  }
}

class OverpassPoiService {
  /// Construit la clause de zone Overpass QL : rayon (`around`) si
  /// `radiusMeters` + `radiusCenter` sont fournis, sinon la bbox classique.
  static String _areaClause({
    required double minLat, required double maxLat,
    required double minLon, required double maxLon,
    double? radiusMeters,
    LatLng? radiusCenter,
  }) {
    if (radiusMeters != null && radiusCenter != null) {
      return '(around:$radiusMeters,${radiusCenter.latitude},${radiusCenter.longitude})';
    }
    return '($minLat,$minLon,$maxLat,$maxLon)';
  }

  /// Recherche les POI dans la bbox visible pour les catégories sélectionnées
  static Future<List<OverpassPoiResult>> search({
    required double minLat, required double maxLat,
    required double minLon, required double maxLon,
    required List<PoiCategory> categories,
    int limit = 200,
    /// Point de référence pour le calcul de distance et le tri par
    /// proximité (typiquement le centre de la carte ou la position GPS
    /// utilisateur). Si null, les résultats gardent l'ordre renvoyé par
    /// Overpass et `distanceMeters` reste null.
    LatLng? sortOrigin,
    /// Filtre optionnel sur le tag OSM `cuisine` (ex: "italian", "pizza"),
    /// appliqué uniquement aux catégories où ce tag a un sens (restaurant,
    /// cafe) — sur les autres catégories il est ignoré silencieusement.
    String? cuisineFilter,
    /// Rayon de recherche en mètres autour de `sortOrigin`. Si fourni (avec
    /// `sortOrigin`), remplace la bbox par une recherche `around` Overpass —
    /// sinon comportement inchangé (zone visible de la carte).
    double? radiusMeters,
    /// Filtres avancés (ouvert maintenant, camping-car, parking, gratuit),
    /// appliqués côté client sur les tags de chaque résultat.
    PoiSearchFilters? filters,
  }) async {
    final selected = categories.where((c) => c.selected).toList();
    if (selected.isEmpty) return [];

    // Construire la requête Overpass QL
    final area = _areaClause(
      minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon,
      radiusMeters: radiusMeters, radiusCenter: sortOrigin,
    );
    const cuisineCategories = {'restaurant', 'cafe'};
    final safeCuisine = cuisineFilter?.trim()
        .replaceAll('\\', r'\\').replaceAll('"', r'\"');
    final unions = selected.map((c) {
      final extra = (safeCuisine != null && safeCuisine.isNotEmpty
              && cuisineCategories.contains(c.id))
          ? '["cuisine"~"$safeCuisine",i]'
          : '';
      final filter = '${c.overpassFilter}$extra';
      return 'node$filter$area;\n'
          'way$filter$area;\n'
          'relation$filter$area;';
    }).join('\n');

    final query = '''
[out:json][timeout:15][maxsize:10000000];
(
$unions
);
out center $limit;
''';

    // Exécution réseau (POST + rotation d'endpoints) déléguée au client
    // Overpass unique — voir core/services/overpass_http_client.dart.
    final data = await OverpassHttpClient.queryPost(
      query,
      timeout: const Duration(seconds: 20),
      userAgent: 'PulseExplorer/1.0',
    );
    final elements = data['elements'] as List? ?? [];

    final results = <OverpassPoiResult>[];
    for (final el in elements) {
      final parsed = _parseElement(el, categorizer: (tags) {
        for (final c in selected) {
          if (_matchesCategory(tags, c)) return c;
        }
        return null;
      });
      if (parsed == null) continue;
      if (filters != null && filters.isActive && !filters.matches(parsed.tags)) continue;
      results.add(parsed);
    }

    return _applySort(results, sortOrigin);
  }

  /// Recherche libre par nom (indépendante des catégories cochées) : trouve
  /// tout POI dont le nom contient `query` (insensible à la casse/accents
  /// selon le moteur Overpass) dans la zone donnée. La catégorie affichée
  /// est déduite des tags OSM via [categorize] ; à défaut, [kOtherCategory].
  static Future<List<OverpassPoiResult>> searchByName({
    required double minLat, required double maxLat,
    required double minLon, required double maxLon,
    required String query,
    int limit = 100,
    LatLng? sortOrigin,
    double? radiusMeters,
    PoiSearchFilters? filters,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    final area = _areaClause(
      minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon,
      radiusMeters: radiusMeters, radiusCenter: sortOrigin,
    );
    // Échappement minimal : Overpass QL utilise une regex entre guillemets
    // doubles — on neutralise backslash et guillemet pour éviter de casser
    // la requête (l'entrée reste une saisie utilisateur libre).
    final safe = trimmed.replaceAll('\\', r'\\').replaceAll('"', r'\"');

    final overpassQuery = '''
[out:json][timeout:15][maxsize:10000000];
(
  node["name"~"$safe",i]$area;
  way["name"~"$safe",i]$area;
  relation["name"~"$safe",i]$area;
);
out center $limit;
''';

    final data = await OverpassHttpClient.queryPost(
      overpassQuery,
      timeout: const Duration(seconds: 20),
      userAgent: 'PulseExplorer/1.0',
    );
    final elements = data['elements'] as List? ?? [];

    final results = <OverpassPoiResult>[];
    for (final el in elements) {
      final parsed = _parseElement(el, categorizer: categorize, fallback: kOtherCategory);
      if (parsed == null) continue;
      if (filters != null && filters.isActive && !filters.matches(parsed.tags)) continue;
      results.add(parsed);
    }

    return _applySort(results, sortOrigin);
  }

  /// Déduit la [PoiCategory] correspondant à des tags OSM, ou null si aucune
  /// catégorie connue ne correspond (utiliser [kOtherCategory] en repli).
  static PoiCategory? categorize(Map<String, String> tags) {
    for (final c in kPoiCategories) {
      if (_matchesCategory(tags, c)) return c;
    }
    return null;
  }

  /// Catégorie de repli pour un POI trouvé par nom mais ne correspondant à
  /// aucune des catégories connues (ex : commerce, bureau, service...).
  static final PoiCategory kOtherCategory = PoiCategory(
    id: 'other',
    label: 'Autre',
    emoji: '📍',
    overpassFilter: '',
    color: Colors.grey.shade600,
  );

  static OverpassPoiResult? _parseElement(
    dynamic el, {
    required PoiCategory? Function(Map<String, String> tags) categorizer,
    PoiCategory? fallback,
  }) {
    final lat = (el['lat'] ?? el['center']?['lat']) as num?;
    final lon = (el['lon'] ?? el['center']?['lon']) as num?;
    if (lat == null || lon == null) return null;

    final tags = Map<String, String>.from(
        (el['tags'] as Map? ?? {}).map((k, v) => MapEntry(k.toString(), v.toString())));

    final name = tags['name'] ?? tags['name:fr'] ?? tags['alt_name'] ?? '';
    if (name.isEmpty) return null;

    // Recherche par catégorie : aucune catégorie sélectionnée ne correspond
    // → on ignore l'élément (comportement historique). Recherche par nom
    // (fallback fourni) → on garde sous "Autre" plutôt que de le perdre.
    final cat = categorizer(tags) ?? fallback;
    if (cat == null) return null;

    return OverpassPoiResult(
      name:       name,
      lat:        lat.toDouble(),
      lon:        lon.toDouble(),
      categoryId: cat.id,
      emoji:      cat.emoji,
      tags:       tags,
    );
  }

  static List<OverpassPoiResult> _applySort(
      List<OverpassPoiResult> results, LatLng? sortOrigin) {
    if (sortOrigin == null) return results;

    // Tri par proximité : distance calculée une seule fois par résultat
    // (Distance() de latlong2 utilise la formule de Haversine).
    const dist = Distance();
    final withDistance = results
        .map((r) => r.copyWithDistance(
              dist.as(LengthUnit.Meter, sortOrigin, LatLng(r.lat, r.lon)),
            ))
        .toList()
      ..sort((a, b) => a.distanceMeters!.compareTo(b.distanceMeters!));

    return withDistance;
  }

  static bool _matchesCategory(Map<String, String> tags, PoiCategory cat) {
    switch (cat.id) {
      case 'hotel':      return ['hotel','motel','hostel','guest_house'].contains(tags['tourism']);
      case 'museum':     return tags['tourism'] == 'museum';
      case 'monument':   return ['monument','memorial','artwork'].contains(tags['tourism']);
      case 'viewpoint':  return tags['tourism'] == 'viewpoint';
      case 'camping':    return ['camp_site','caravan_site'].contains(tags['tourism']);
      case 'attraction': return tags['tourism'] == 'attraction';
      case 'castle':     return ['castle','fort','palace'].contains(tags['historic']);
      case 'ruins':      return ['ruins','archaeological_site'].contains(tags['historic']);
      case 'restaurant': return tags['amenity'] == 'restaurant';
      case 'cafe':       return ['cafe','coffee_shop'].contains(tags['amenity']);
      case 'parking':    return tags['amenity'] == 'parking';
      case 'fuel':       return tags['amenity'] == 'fuel';
      case 'chapel':     return tags['amenity'] == 'place_of_worship';
      case 'peak':       return tags['natural'] == 'peak';
      case 'waterfall':  return tags['waterway'] == 'waterfall';
      case 'lake':       return tags['natural'] == 'water' || tags['water'] == 'lake';
      case 'cave':       return tags['natural'] == 'cave_entrance';
      case 'bakery':     return tags['shop'] == 'bakery';
      case 'pharmacy':   return tags['amenity'] == 'pharmacy';
      case 'charging_station': return tags['amenity'] == 'charging_station';
      case 'hospital':   return ['hospital','clinic'].contains(tags['amenity']);
      default:           return false;
    }
  }
}
