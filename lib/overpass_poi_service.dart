import 'package:flutter/material.dart';
import 'poi_layer.dart';
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
];

class OverpassPoiResult {
  final String   name;
  final double   lat;
  final double   lon;
  final String   categoryId;
  final String   emoji;
  final Map<String, String> tags;

  OverpassPoiResult({
    required this.name,
    required this.lat,
    required this.lon,
    required this.categoryId,
    required this.emoji,
    required this.tags,
  });

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
  /// Recherche les POI dans la bbox visible pour les catégories sélectionnées
  static Future<List<OverpassPoiResult>> search({
    required double minLat, required double maxLat,
    required double minLon, required double maxLon,
    required List<PoiCategory> categories,
    int limit = 200,
  }) async {
    final selected = categories.where((c) => c.selected).toList();
    if (selected.isEmpty) return [];

    // Construire la requête Overpass QL
    final bbox = '$minLat,$minLon,$maxLat,$maxLon';
    final unions = selected.map((c) =>
      'node${c.overpassFilter}($bbox);\n'
      'way${c.overpassFilter}($bbox);\n'
      'relation${c.overpassFilter}($bbox);'
    ).join('\n');

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
      // Coordonnées (node = direct, way/relation = center)
      final lat = (el['lat'] ?? el['center']?['lat']) as num?;
      final lon = (el['lon'] ?? el['center']?['lon']) as num?;
      if (lat == null || lon == null) continue;

      final tags = Map<String, String>.from(
          (el['tags'] as Map? ?? {}).map((k, v) => MapEntry(k.toString(), v.toString())));

      // Nom
      final name = tags['name'] ?? tags['name:fr'] ?? tags['alt_name'] ?? '';
      if (name.isEmpty) continue;

      // Identifier la catégorie
      PoiCategory? cat;
      for (final c in selected) {
        if (_matchesCategory(tags, c)) { cat = c; break; }
      }
      if (cat == null) continue;

      results.add(OverpassPoiResult(
        name:       name,
        lat:        lat.toDouble(),
        lon:        lon.toDouble(),
        categoryId: cat.id,
        emoji:      cat.emoji,
        tags:       tags,
      ));
    }

    return results;
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
      default:           return false;
    }
  }
}
