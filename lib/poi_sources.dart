import 'dart:convert';
import 'package:http/http.dart' as http;
import 'poi_layer.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Catégories style Google Maps (groupées)
// ─────────────────────────────────────────────────────────────────────────────
class PoiCategoryGroup {
  final String id;
  final String label;
  final String emoji;
  final List<PoiCategoryItem> items;

  const PoiCategoryGroup({
    required this.id,
    required this.label,
    required this.emoji,
    required this.items,
  });
}

class PoiCategoryItem {
  final String id;
  final String label;
  final String emoji;
  final List<String> overpassFilters;
  final String? wikidataClass;    // classe Wikidata Q...
  final String? otmCategory;      // catégorie OpenTripMap

  const PoiCategoryItem({
    required this.id,
    required this.label,
    required this.emoji,
    required this.overpassFilters,
    this.wikidataClass,
    this.otmCategory,
  });
}

const kPoiCategoryGroups = [
  PoiCategoryGroup(id: 'nature', label: 'Nature & Paysages', emoji: '🌿', items: [
    PoiCategoryItem(id: 'viewpoint',  label: 'Points de vue',      emoji: '🔭',
      overpassFilters: ['node["tourism"="viewpoint"]', 'node["information"="viewpoint"]'],
      wikidataClass: 'Q1785071', otmCategory: 'natural'),
    PoiCategoryItem(id: 'peak',       label: 'Sommets & cols',      emoji: '⛰️',
      overpassFilters: ['node["natural"="peak"]', 'node["natural"="saddle"]',
                        'node["mountain_pass"="yes"]'],
      wikidataClass: 'Q8502', otmCategory: 'natural'),
    PoiCategoryItem(id: 'cliff',      label: 'Falaises & gorges',   emoji: '🏔️',
      overpassFilters: ['node["natural"="cliff"]', 'node["natural"="gorge"]',
                        'node["natural"="valley"]'],
      otmCategory: 'natural'),
    PoiCategoryItem(id: 'waterfall',  label: 'Cascades',            emoji: '💧',
      overpassFilters: ['node["waterway"="waterfall"]'],
      wikidataClass: 'Q瀑布', otmCategory: 'natural'),
    PoiCategoryItem(id: 'cave',       label: 'Grottes',             emoji: '🦇',
      overpassFilters: ['node["natural"="cave_entrance"]', 'node["tourism"="attraction"]["name"~"grotte|cueva|cave",i]'],
      wikidataClass: 'Q35509', otmCategory: 'natural'),
    PoiCategoryItem(id: 'lake',       label: 'Lacs & réservoirs',   emoji: '🏞️',
      overpassFilters: ['node["natural"="water"]', 'node["landuse"="reservoir"]'],
      otmCategory: 'natural'),
    PoiCategoryItem(id: 'forest',     label: 'Forêts & parcs naturels', emoji: '🌲',
      overpassFilters: ['node["leisure"="nature_reserve"]', 'node["boundary"="national_park"]'],
      otmCategory: 'natural'),
  ]),
  PoiCategoryGroup(id: 'culture', label: 'Culture & Histoire', emoji: '🏛️', items: [
    PoiCategoryItem(id: 'monument',   label: 'Monuments',           emoji: '🗿',
      overpassFilters: ['node["historic"="monument"]', 'node["historic"="memorial"]'],
      wikidataClass: 'Q4989906', otmCategory: 'cultural'),
    PoiCategoryItem(id: 'castle',     label: 'Châteaux & forts',    emoji: '🏰',
      overpassFilters: ['node["historic"="castle"]', 'node["historic"="fort"]',
                        'node["historic"="ruins"]'],
      wikidataClass: 'Q23413', otmCategory: 'cultural'),
    PoiCategoryItem(id: 'museum',     label: 'Musées & galeries',   emoji: '🖼️',
      overpassFilters: ['node["tourism"="museum"]', 'node["tourism"="gallery"]'],
      wikidataClass: 'Q33506', otmCategory: 'cultural'),
    PoiCategoryItem(id: 'chapel',     label: 'Églises & chapelles', emoji: '⛪',
      overpassFilters: ['node["amenity"="place_of_worship"]',
                        'node["historic"="wayside_shrine"]',
                        'node["building"~"chapel|church|monastery"]'],
      wikidataClass: 'Q16970', otmCategory: 'cultural'),
    PoiCategoryItem(id: 'heritage',   label: 'Sites archéologiques',emoji: '🏺',
      overpassFilters: ['node["historic"="archaeological_site"]',
                        'node["historic"="tomb"]'],
      wikidataClass: 'Q839954', otmCategory: 'cultural'),
    PoiCategoryItem(id: 'artwork',    label: 'Art & sculptures',    emoji: '🗽',
      overpassFilters: ['node["tourism"="artwork"]'],
      otmCategory: 'cultural'),
  ]),
  PoiCategoryGroup(id: 'village', label: 'Villages & Villes', emoji: '🏘️', items: [
    PoiCategoryItem(id: 'village',    label: 'Villages pittoresques',emoji: '🏘️',
      overpassFilters: ['node["place"="village"]', 'node["place"="hamlet"]'],
      otmCategory: 'interesting_places'),
    PoiCategoryItem(id: 'old_town',   label: 'Vieux quartiers',     emoji: '🏯',
      overpassFilters: ['node["historic"="district"]', 'node["place"="quarter"]'],
      otmCategory: 'cultural'),
    PoiCategoryItem(id: 'market',     label: 'Marchés',             emoji: '🛒',
      overpassFilters: ['node["amenity"="marketplace"]'],
      otmCategory: 'amusements'),
  ]),
  PoiCategoryGroup(id: 'sport', label: 'Sport & Activités', emoji: '🏄', items: [
    PoiCategoryItem(id: 'hiking',     label: 'Randonnée & sentiers', emoji: '🥾',
      overpassFilters: ['node["tourism"="information"]["information"="guidepost"]',
                        'node["hiking"="yes"]'],
      otmCategory: 'sport'),
    PoiCategoryItem(id: 'climbing',   label: 'Escalade',            emoji: '🧗',
      overpassFilters: ['node["sport"="climbing"]', 'node["climbing"~".+"]'],
      otmCategory: 'sport'),
    PoiCategoryItem(id: 'cycling',    label: 'Vélo & VTT',          emoji: '🚵',
      overpassFilters: ['node["sport"="cycling"]', 'node["bicycle"="yes"]'],
      otmCategory: 'sport'),
    PoiCategoryItem(id: 'swimming',   label: 'Baignade',            emoji: '🏊',
      overpassFilters: ['node["natural"="swimming_area"]', 'node["leisure"="swimming_area"]'],
      otmCategory: 'sport'),
  ]),
  PoiCategoryGroup(id: 'food', label: 'Gastronomie', emoji: '🍽️', items: [
    PoiCategoryItem(id: 'restaurant', label: 'Restaurants',         emoji: '🍽️',
      overpassFilters: ['node["amenity"="restaurant"]'],
      otmCategory: 'foods'),
    PoiCategoryItem(id: 'cafe',       label: 'Cafés & bars',        emoji: '☕',
      overpassFilters: ['node["amenity"~"cafe|bar"]'],
      otmCategory: 'foods'),
    PoiCategoryItem(id: 'winery',     label: 'Vignobles & caves',   emoji: '🍷',
      overpassFilters: ['node["craft"="winery"]', 'node["tourism"="winery"]'],
      otmCategory: 'foods'),
    PoiCategoryItem(id: 'local_food', label: 'Produits locaux',     emoji: '🧀',
      overpassFilters: ['node["shop"~"farm|dairy|cheese|butcher"]'],
      otmCategory: 'foods'),
  ]),
  PoiCategoryGroup(id: 'stay', label: 'Hébergement', emoji: '🏨', items: [
    PoiCategoryItem(id: 'hotel',      label: 'Hôtels',              emoji: '🏨',
      overpassFilters: ['node["tourism"="hotel"]'],
      otmCategory: 'accomodations'),
    PoiCategoryItem(id: 'hostel',     label: 'Auberges & gîtes',    emoji: '🛖',
      overpassFilters: ['node["tourism"~"hostel|guest_house|chalet"]'],
      otmCategory: 'accomodations'),
    PoiCategoryItem(id: 'camping',    label: 'Campings',            emoji: '⛺',
      overpassFilters: ['node["tourism"="camp_site"]'],
      otmCategory: 'accomodations'),
  ]),
  PoiCategoryGroup(id: 'moto', label: 'Pratique Moto', emoji: '🏍️', items: [
    PoiCategoryItem(id: 'fuel',       label: 'Stations essence',    emoji: '⛽',
      overpassFilters: ['node["amenity"="fuel"]']),
    PoiCategoryItem(id: 'parking',    label: 'Parkings & aires',    emoji: '🅿️',
      overpassFilters: ['node["amenity"="parking"]', 'node["tourism"="picnic_site"]']),
    PoiCategoryItem(id: 'mechanic',   label: 'Garages & mécaniciens',emoji: '🔧',
      overpassFilters: ['node["amenity"="car_repair"]', 'node["shop"="motorcycle"]']),
    PoiCategoryItem(id: 'scenic',     label: 'Routes panoramiques', emoji: '🛣️',
      overpassFilters: ['way["scenic"="yes"]']),
  ]),
];

// Index plat par id
final Map<String, PoiCategoryItem> kPoiCategoryById = {
  for (final g in kPoiCategoryGroups)
    for (final item in g.items)
      item.id: item,
};

// ─────────────────────────────────────────────────────────────────────────────
// Sources de POI disponibles
// ─────────────────────────────────────────────────────────────────────────────
enum PoiSource { osm, wikidata, opentripmap }

class PoiSourceInfo {
  final PoiSource source;
  final String   label;
  final String   description;
  final String   emoji;
  final bool     needsApiKey;

  const PoiSourceInfo({
    required this.source,
    required this.label,
    required this.description,
    required this.emoji,
    this.needsApiKey = false,
  });
}

const kPoiSources = [
  PoiSourceInfo(
    source: PoiSource.osm,
    label: 'OpenStreetMap (Overpass)',
    description: 'Données collaboratives mondiales — très complet',
    emoji: '🗺️',
    needsApiKey: false,
  ),
  PoiSourceInfo(
    source: PoiSource.wikidata,
    label: 'Wikidata',
    description: 'Lieux notables avec importance encyclopédique',
    emoji: '📖',
    needsApiKey: false,
  ),
  PoiSourceInfo(
    source: PoiSource.opentripmap,
    label: 'OpenTripMap',
    description: 'POI touristiques avec notes et photos (clé API gratuite)',
    emoji: '✈️',
    needsApiKey: true,
  ),
];

// ─────────────────────────────────────────────────────────────────────────────
// Fetcher Wikidata (SPARQL)
// ─────────────────────────────────────────────────────────────────────────────
class WikidataFetcher {
  static const _endpoint = 'https://query.wikidata.org/sparql';

  static Future<List<PoiPoint>> fetch({
    required double minLat, required double maxLat,
    required double minLon, required double maxLon,
    required List<String> categoryIds,
    int maxResults = 100,
  }) async {
    // Construire la requête SPARQL pour les catégories sélectionnées
    final items = categoryIds
        .map((id) => kPoiCategoryById[id])
        .where((item) => item?.wikidataClass != null)
        .toList();
    if (items.isEmpty) return [];

    final classFilters = items
        .map((item) => 'wd:${item!.wikidataClass}')
        .join(' ');

    final query = '''
SELECT ?item ?itemLabel ?lat ?lon ?desc WHERE {
  ?item wdt:P31/wdt:P279* ?class.
  VALUES ?class { $classFilters }
  ?item p:P625 ?coord.
  ?coord psv:P625 ?coordNode.
  ?coordNode wikibase:geoLatitude ?lat.
  ?coordNode wikibase:geoLongitude ?lon.
  FILTER(?lat >= $minLat && ?lat <= $maxLat && ?lon >= $minLon && ?lon <= $maxLon)
  OPTIONAL { ?item schema:description ?desc. FILTER(LANG(?desc) = "fr") }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "fr,en". }
}
LIMIT $maxResults
''';

    try {
      final uri = Uri.parse(_endpoint).replace(
          queryParameters: {'query': query, 'format': 'json'});
      final resp = await http.get(uri, headers: {
        'User-Agent': 'GPXOverlayApp/1.0',
        'Accept': 'application/sparql-results+json',
      }).timeout(const Duration(seconds: 20));

      if (resp.statusCode != 200) return [];
      final data = json.decode(resp.body);
      final bindings = data['results']['bindings'] as List;
      final results = <PoiPoint>[];

      for (final b in bindings) {
        final lat  = double.tryParse(b['lat']?['value'] ?? '');
        final lon  = double.tryParse(b['lon']?['value'] ?? '');
        final name = b['itemLabel']?['value'] as String?;
        if (lat == null || lon == null || name == null) continue;
        if (name.startsWith('Q')) continue; // pas de label trouvé
        results.add(PoiPoint(
          name:        name,
          lat:         lat,
          lon:         lon,
          description: b['desc']?['value'] as String?,
          type:        'wikidata',
        ));
      }
      return results;
    } catch (_) {
      return [];
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fetcher OpenTripMap
// ─────────────────────────────────────────────────────────────────────────────
class OpenTripMapFetcher {
  static const _base = 'https://api.opentripmap.com/0.1/fr/places';
  static String apiKey = '';

  static Future<List<PoiPoint>> fetch({
    required double minLat, required double maxLat,
    required double minLon, required double maxLon,
    required List<String> categoryIds,
    int maxResults = 100,
  }) async {
    if (apiKey.isEmpty) throw Exception('Clé API OpenTripMap manquante');

    final kinds = categoryIds
        .map((id) => kPoiCategoryById[id]?.otmCategory)
        .where((k) => k != null)
        .toSet()
        .join(',');
    if (kinds.isEmpty) return [];

    final uri = Uri.parse('$_base/bbox').replace(queryParameters: {
      'lon_min': '$minLon', 'lon_max': '$maxLon',
      'lat_min': '$minLat', 'lat_max': '$maxLat',
      'kinds':   kinds,
      'limit':   '$maxResults',
      'format':  'json',
      'apikey':  apiKey,
    });

    final resp = await http.get(uri,
        headers: {'User-Agent': 'GPXOverlayApp/1.0'})
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('Erreur OpenTripMap ${resp.statusCode}');
    }

    final data = json.decode(resp.body);
    final features = data['features'] as List? ?? [];
    final results  = <PoiPoint>[];

    for (final f in features) {
      final props = f['properties'] as Map<String, dynamic>? ?? {};
      final name  = props['name'] as String?;
      if (name == null || name.isEmpty) continue;
      final coords = f['geometry']?['coordinates'] as List?;
      if (coords == null || coords.length < 2) continue;
      results.add(PoiPoint(
        name:        name,
        lat:         (coords[1] as num).toDouble(),
        lon:         (coords[0] as num).toDouble(),
        description: props['kinds']?.toString(),
        type:        'opentripmap',
      ));
    }
    return results;
  }
}
