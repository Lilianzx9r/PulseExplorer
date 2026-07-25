import 'dart:convert';
import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────────────────────────
// geocoding_service.dart
//
// Service UNIQUE de géocodage via Nominatim (OpenStreetMap).
//
// Avant la refonte, cette même requête HTTP Nominatim était réimplémentée
// indépendamment dans 6 fichiers (nominatim_helper.dart, poi_geocoder.dart,
// poi_field_search.dart, place_search_field.dart, blog_poi_service.dart,
// html_poi_extractor.dart), chacun avec son propre User-Agent, son propre
// timeout et sa propre gestion d'erreur.
//
// Tous ces fichiers délèguent maintenant à GeocodingService. Leurs API
// publiques (noms de classes/méthodes) sont conservées à l'identique pour
// ne pas casser les ~50 points d'appel existants dans le reste de l'app —
// seule l'implémentation interne a été unifiée.
// ─────────────────────────────────────────────────────────────────────────────

/// Résultat brut d'une recherche Nominatim.
class GeocodeResult {
  final String displayName;
  final double lat;
  final double lon;
  final String type;
  final List<double>? boundingBox; // [minLat, maxLat, minLon, maxLon]

  const GeocodeResult({
    required this.displayName,
    required this.lat,
    required this.lon,
    required this.type,
    this.boundingBox,
  });
}

class GeocodingService {
  GeocodingService._();

  static const String _baseUrl = 'https://nominatim.openstreetmap.org/search';

  /// User-Agent commun à toutes les requêtes PulseExplorer vers Nominatim.
  /// Nominatim exige un User-Agent identifiable (politique d'usage OSM) —
  /// avant la fusion, chaque copie du code utilisait une valeur différente
  /// ("PulseGpx/1.0", "GPXOverlayApp/1.0 (educational)",
  /// "BookingGPXOverlay/1.0"...), ce qui n'avait aucune justification
  /// fonctionnelle.
  static const String _userAgent = 'PulseExplorer/1.0 (contact: app@pulsegps.local)';

  /// Recherche brute — jusqu'à [limit] résultats, avec bounding box si
  /// [addressDetails] est activé.
  static Future<List<GeocodeResult>> search(
    String query, {
    int limit = 5,
    bool addressDetails = false,
    String acceptLanguage = 'fr,en',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'q': query,
      'format': 'json',
      'limit': '$limit',
      if (addressDetails) 'addressdetails': '1',
    });

    final response = await http.get(uri, headers: {
      'User-Agent': _userAgent,
      'Accept-Language': acceptLanguage,
    }).timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception('Erreur Nominatim: ${response.statusCode}');
    }

    final data = json.decode(response.body) as List;
    return data.map((item) {
      final bbox = item['boundingbox'] as List?;
      return GeocodeResult(
        displayName: item['display_name']?.toString() ?? '',
        lat: double.tryParse(item['lat'].toString()) ?? 0,
        lon: double.tryParse(item['lon'].toString()) ?? 0,
        type: item['type']?.toString() ?? '',
        boundingBox: bbox == null
            ? null
            : bbox.map((v) => double.tryParse(v.toString()) ?? 0).toList(),
      );
    }).toList();
  }

  /// Géocode un nom de lieu unique → (lat, lon) ou null si introuvable.
  /// Ne lève jamais d'exception : retourne null en cas d'erreur réseau.
  static Future<(double, double)?> geocodeSingle(
    String query, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final results = await search(query, limit: 1, timeout: timeout);
      if (results.isEmpty) return null;
      return (results.first.lat, results.first.lon);
    } catch (_) {
      return null;
    }
  }

  /// Délai à respecter entre deux appels pour honorer la politique d'usage
  /// Nominatim (1 requête/seconde max côté serveur public).
  static const Duration rateLimitDelay = Duration(milliseconds: 1100);
}
