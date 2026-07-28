import 'dart:convert';
import 'package:http/http.dart' as http;

import 'poi_source.dart';

/// Source Wikidata : recherche de lieux via l'API SPARQL publique, et
/// récupération des descriptions/sites officiels via l'API wbgetentities.
///
/// Aucune clé API n'est nécessaire (service public Wikimedia).
class WikidataSource implements PoiSource {
  final String sparqlEndpoint;
  final String entityEndpoint;

  const WikidataSource({
    this.sparqlEndpoint = 'https://query.wikidata.org/sparql',
    this.entityEndpoint = 'https://www.wikidata.org/w/api.php',
  });

  @override
  String get id => 'wikidata';

  @override
  String get name => 'Wikidata';

  @override
  List<String> categories() => const [
        'monument',
        'site_naturel',
        'village',
        'patrimoine',
        'point_de_vue',
      ];

  @override
  Future<List<PoiSourceResult>> search({
    required String query,
    double? lat,
    double? lon,
    double? radiusMeters,
    int limit = 20,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    // Recherche géographique autour d'un point si des coordonnées sont
    // fournies, sinon recherche textuelle simple via l'API wbsearchentities.
    if (lat != null && lon != null) {
      return _searchNearby(lat: lat, lon: lon, radiusMeters: radiusMeters ?? 20000, limit: limit);
    }
    return _searchByLabel(query: trimmed, limit: limit);
  }

  Future<List<PoiSourceResult>> _searchByLabel({
    required String query,
    required int limit,
  }) async {
    final uri = Uri.parse(entityEndpoint).replace(queryParameters: {
      'action': 'wbsearchentities',
      'search': query,
      'language': 'fr',
      'format': 'json',
      'limit': '$limit',
      'type': 'item',
    });

    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Wikidata ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final search = data['search'] as List<dynamic>? ?? const [];

    return search.map((item) {
      final m = item as Map<String, dynamic>;
      return PoiSourceResult(
        id: '${m['id']}',
        name: '${m['label'] ?? m['id']}',
        category: m['description'] as String?,
        sourceId: id,
      );
    }).toList();
  }

  Future<List<PoiSourceResult>> _searchNearby({
    required double lat,
    required double lon,
    required double radiusMeters,
    required int limit,
  }) async {
    final radiusKm = (radiusMeters / 1000).clamp(0.1, 200).toStringAsFixed(1);
    final sparql = '''
      SELECT ?item ?itemLabel ?location WHERE {
        SERVICE wikibase:around {
          ?item wdt:P625 ?location .
          bd:serviceParam wikibase:center "Point($lon $lat)"^^geo:wktLiteral .
          bd:serviceParam wikibase:radius "$radiusKm" .
        }
        SERVICE wikibase:label { bd:serviceParam wikibase:language "fr,en". }
      } LIMIT $limit
    ''';

    final uri = Uri.parse(sparqlEndpoint).replace(queryParameters: {
      'query': sparql,
      'format': 'json',
    });

    final response = await http.get(
      uri,
      headers: {'Accept': 'application/sparql-results+json'},
    ).timeout(const Duration(seconds: 25));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Wikidata SPARQL ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final bindings = (data['results']?['bindings'] as List<dynamic>?) ?? const [];

    final results = <PoiSourceResult>[];
    for (final binding in bindings) {
      final b = binding as Map<String, dynamic>;
      final itemUri = b['item']?['value'] as String?;
      if (itemUri == null) continue;
      final qid = itemUri.split('/').last;
      final label = b['itemLabel']?['value'] as String? ?? qid;
      final point = b['location']?['value'] as String?;
      final coords = _parseWktPoint(point);

      results.add(PoiSourceResult(
        id: qid,
        name: label,
        lat: coords?.$2,
        lon: coords?.$1,
        sourceId: id,
      ));
    }
    return results;
  }

  (double, double)? _parseWktPoint(String? wkt) {
    if (wkt == null) return null;
    final match = RegExp(r'Point\(([-\d.]+)\s+([-\d.]+)\)').firstMatch(wkt);
    if (match == null) return null;
    final lon = double.tryParse(match.group(1) ?? '');
    final lat = double.tryParse(match.group(2) ?? '');
    if (lon == null || lat == null) return null;
    return (lon, lat);
  }

  @override
  Future<PoiSourceDetails?> details(String id) async {
    final uri = Uri.parse(entityEndpoint).replace(queryParameters: {
      'action': 'wbgetentities',
      'ids': id,
      'languages': 'fr|en',
      'props': 'descriptions|sitelinks|claims',
      'format': 'json',
    });

    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final entity = data['entities']?[id] as Map<String, dynamic>?;
    if (entity == null) return null;

    final descriptions = entity['descriptions'] as Map<String, dynamic>? ?? {};
    final description = (descriptions['fr'] ?? descriptions['en'])?['value'] as String?;

    return PoiSourceDetails(
      id: id,
      description: description,
    );
  }

  @override
  Future<List<String>> images(String id) async {
    // L'image (P18) nécessiterait un appel supplémentaire à Wikimedia
    // Commons pour résoudre le nom de fichier en URL. Volontairement non
    // implémenté dans cette première itération : renvoie une liste vide
    // plutôt que de risquer un appel non fiable non testé.
    return const [];
  }
}
