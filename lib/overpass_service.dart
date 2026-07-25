import 'poi_layer.dart';
import 'core/services/overpass_http_client.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Catégories POI road trip moto
// ─────────────────────────────────────────────────────────────────────────────
class PoiCategory {
  final String id;
  final String label;
  final String emoji;
  final List<String> filters; // lignes de filtre Overpass QL
  final String colorHex;

  const PoiCategory({
    required this.id,
    required this.label,
    required this.emoji,
    required this.filters,
    required this.colorHex,
  });
}

const kPoiCategories = [
  // ── Panoramas & nature ──────────────────────────────────────────────────
  PoiCategory(id: 'viewpoint',  label: 'Points de vue',    emoji: '🔭',
    filters: ['node["tourism"="viewpoint"]', 'node["information"="viewpoint"]'],
    colorHex: '#FF6B35'),
  PoiCategory(id: 'peak',       label: 'Sommets & cols',   emoji: '⛰️',
    filters: ['node["natural"="peak"]', 'node["mountain_pass"="yes"]',
               'node["natural"="saddle"]'],
    colorHex: '#8B4513'),
  PoiCategory(id: 'cliff',      label: 'Falaises & gorges',emoji: '🏔️',
    filters: ['node["natural"="cliff"]', 'node["natural"="gorge"]',
               'node["natural"="valley"]', 'node["geological"~".*"]'],
    colorHex: '#5D4037'),
  PoiCategory(id: 'waterfall',  label: 'Cascades',         emoji: '💧',
    filters: ['node["waterway"="waterfall"]'],
    colorHex: '#00BCD4'),
  PoiCategory(id: 'lake',       label: 'Lacs & réservoirs',emoji: '🏞️',
    filters: ['node["natural"="water"]', 'node["landuse"="reservoir"]'],
    colorHex: '#2196F3'),
  // ── Sites & monuments ───────────────────────────────────────────────────
  PoiCategory(id: 'attraction', label: 'Sites remarquables',emoji: '🎠',
    filters: ['node["tourism"="attraction"]', 'node["tourism"="artwork"]'],
    colorHex: '#E91E63'),
  PoiCategory(id: 'monument',   label: 'Monuments & ruines',emoji: '🏛️',
    filters: ['node["historic"="monument"]', 'node["historic"="ruins"]',
               'node["historic"="castle"]', 'node["historic"="fort"]',
               'node["historic"="archaeological_site"]'],
    colorHex: '#9C27B0'),
  PoiCategory(id: 'museum',     label: 'Musées',            emoji: '🖼️',
    filters: ['node["tourism"="museum"]', 'node["tourism"="gallery"]'],
    colorHex: '#673AB7'),
  // ── Petits villages ─────────────────────────────────────────────────────
  PoiCategory(id: 'village',    label: 'Petits villages',   emoji: '🏘️',
    filters: ['node["place"~"village|hamlet"]["population"~"^[0-9]{1,3}\$"]',
               'node["place"="village"]'],
    colorHex: '#795548'),
  // ── Routes & passes ─────────────────────────────────────────────────────
  PoiCategory(id: 'scenic',     label: 'Routes panoramiques',emoji: '🛣️',
    filters: ['way["scenic"="yes"]', 'way["route"="road"]["network"~"scenic"]',
               'node["tourism"="information"]["information"="guidepost"]'],
    colorHex: '#FF9800'),
  // ── Pratique moto ───────────────────────────────────────────────────────
  PoiCategory(id: 'fuel',       label: 'Stations essence',  emoji: '⛽',
    filters: ['node["amenity"="fuel"]'],
    colorHex: '#F44336'),
  PoiCategory(id: 'parking',    label: 'Parkings & aires',  emoji: '🅿️',
    filters: ['node["amenity"="parking"]', 'node["tourism"="picnic_site"]',
               'node["leisure"="picnic_table"]'],
    colorHex: '#607D8B'),
  PoiCategory(id: 'hotel',      label: 'Hébergements',      emoji: '🏨',
    filters: ['node["tourism"~"hotel|hostel|guest_house|camp_site|chalet"]'],
    colorHex: '#009688'),
  PoiCategory(id: 'restaurant', label: 'Restaurants & cafés',emoji: '🍽️',
    filters: ['node["amenity"~"restaurant|cafe|bar"]'],
    colorHex: '#FF5722'),
  // ── Religieux & culturel ────────────────────────────────────────────────
  PoiCategory(id: 'chapel',     label: 'Chapelles & ermitages',emoji: '⛪',
    filters: ['node["amenity"="place_of_worship"]',
               'node["building"~"chapel|church|monastery"]',
               'node["historic"="wayside_shrine"]'],
    colorHex: '#8D6E63'),
];

// ─────────────────────────────────────────────────────────────────────────────
// Service Overpass — FIX 406 : pas de header Accept, requête GET avec param
// ─────────────────────────────────────────────────────────────────────────────
class OverpassService {

  // Instances de l'API Overpass (rotation si l'une est surchargée)
  static const _endpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  ];

  static Future<List<PoiPoint>> fetchPois({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
    required List<String> categoryIds,
    int maxResults = 150,
  }) async {
    final cats = kPoiCategories
        .where((c) => categoryIds.contains(c.id))
        .toList();
    if (cats.isEmpty) return [];

    // Construire la requête Overpass QL
    // [out:json] dans la requête = pas besoin de header Accept
    final bbox = '$minLat,$minLon,$maxLat,$maxLon';
    final filters = cats
        .expand((c) => c.filters)
        .map((f) {
          // Ajouter la bbox à chaque filtre
          if (f.startsWith('way[')) {
            return '  $f($bbox);\n  >;'; // way → nodes
          }
          return '  $f($bbox);';
        })
        .join('\n');

    final query =
        '[out:json][timeout:30];\n'
        '(\n$filters\n);\n'
        'out center $maxResults;';

    // Exécution réseau (rotation d'endpoints, gestion 429/503) déléguée au
    // client Overpass unique — voir core/services/overpass_http_client.dart.
    final data = await OverpassHttpClient.query(
      query,
      endpoints: _endpoints,
      userAgent: 'PulseExplorer/1.0 (road trip moto)',
    );
    return _parse(data, cats);
  }

  static List<PoiPoint> _parse(Map<String, dynamic> data, List<PoiCategory> cats) {
    final elements = data['elements'] as List? ?? [];
    final results  = <PoiPoint>[];

    for (final el in elements) {
      double? lat, lon;

      // Node direct
      if (el['type'] == 'node') {
        lat = (el['lat'] as num?)?.toDouble();
        lon = (el['lon'] as num?)?.toDouble();
      }
      // Way → utiliser le centre calculé par "out center"
      if (el['type'] == 'way' && el['center'] != null) {
        lat = (el['center']['lat'] as num?)?.toDouble();
        lon = (el['center']['lon'] as num?)?.toDouble();
      }
      if (lat == null || lon == null) continue;

      final tags = el['tags'] as Map<String, dynamic>? ?? {};
      final name = _name(tags);
      if (name == null) continue;

      results.add(PoiPoint(
        name:        name,
        lat:         lat,
        lon:         lon,
        description: _desc(tags),
        type:        _type(tags),
      ));
    }
    return results;
  }

  static String? _name(Map<String, dynamic> tags) {
    for (final k in ['name', 'name:fr', 'name:en', 'alt_name', 'loc_name']) {
      if (tags[k] != null && (tags[k] as String).isNotEmpty) {
        return tags[k] as String;
      }
    }
    return null;
  }

  static String _desc(Map<String, dynamic> tags) {
    final parts = <String>[];
    if (tags['ele']         != null) parts.add('Alt: ${tags["ele"]}m');
    if (tags['description'] != null) parts.add(tags['description'] as String);
    if (tags['opening_hours'] != null) parts.add('Horaires: ${tags["opening_hours"]}');
    if (tags['website']     != null) parts.add(tags['website'] as String);
    if (tags['wikipedia']   != null) parts.add('Wiki: ${tags["wikipedia"]}');
    return parts.take(2).join(' • ');
  }

  static String _type(Map<String, dynamic> tags) {
    if (tags['tourism']  == 'viewpoint')   return 'viewpoint';
    if (tags['natural']  == 'peak')        return 'peak';
    if (tags['natural']  == 'cliff')       return 'cliff';
    if (tags['natural']  == 'gorge')       return 'gorge';
    if (tags['waterway'] == 'waterfall')   return 'waterfall';
    if (tags['tourism']  == 'museum')      return 'museum';
    if (tags['tourism']  == 'attraction')  return 'attraction';
    if (tags['amenity']  == 'fuel')        return 'fuel';
    if (tags['amenity']  == 'parking')     return 'parking';
    if (tags['place']    != null)          return 'village';
    if (tags['historic'] != null)          return 'monument';
    if (tags['tourism']  != null &&
        (tags['tourism'] as String).contains('hotel')) return 'hotel';
    if (tags['amenity']  == 'restaurant' ||
        tags['amenity']  == 'cafe')        return 'restaurant';
    return 'poi';
  }
}
