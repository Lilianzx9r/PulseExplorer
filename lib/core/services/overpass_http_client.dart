import 'dart:convert';
import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────────────────────────
// overpass_http_client.dart
//
// Exécuteur HTTP UNIQUE pour l'API Overpass (OSM). Avant la refonte, cette
// mécanique réseau (rotation d'endpoints, absence volontaire du header
// Accept pour éviter les erreurs 406, gestion des 429/503) était dupliquée
// entre overpass_service.dart et overpass_poi_service.dart.
//
// Contrairement au géocodage, les DEUX écrans qui consomment Overpass ont
// des taxonomies de catégories POI différentes et des modèles de résultat
// différents (PoiPoint vs OverpassPoiResult) — ce n'est pas une duplication
// mais deux besoins produit distincts (recherche "road trip moto" vs
// recherche "tourisme générique"). On ne fusionne donc PAS les catégories,
// seulement la mécanique réseau commune.
// ─────────────────────────────────────────────────────────────────────────────

class OverpassHttpClient {
  OverpassHttpClient._();

  static const List<String> defaultEndpoints = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.kumi.systems/api/interpreter',
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
  ];

  /// Variante POST (form-urlencoded `data=`) — nécessaire pour les requêtes
  /// longues avec crochets/guillemets, que le GET peut tronquer ou mal
  /// encoder selon les serveurs Overpass. Bénéficie aussi de la rotation
  /// d'endpoints (le pipeline "POI touristiques" n'en avait pas avant la
  /// refonte : un seul endpoint fixe, point de défaillance unique).
  static Future<Map<String, dynamic>> queryPost(
    String overpassQl, {
    List<String> endpoints = defaultEndpoints,
    Duration timeout = const Duration(seconds: 20),
    String userAgent = 'PulseExplorer/1.0 (contact: app@pulsegps.local)',
  }) async {
    Exception? lastError;
    for (final endpoint in endpoints) {
      try {
        final resp = await http.post(
          Uri.parse(endpoint),
          headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
            'Accept': 'application/json',
            'User-Agent': userAgent,
          },
          body: 'data=${Uri.encodeComponent(overpassQl)}',
        ).timeout(timeout);

        if (resp.statusCode == 200) {
          return json.decode(resp.body) as Map<String, dynamic>;
        }
        if (resp.statusCode == 429 || resp.statusCode == 503) {
          lastError = Exception('Serveur surchargé (${resp.statusCode})');
          continue;
        }
        final preview =
            resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body;
        throw Exception('Overpass HTTP ${resp.statusCode} — $preview');
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        continue;
      }
    }
    throw lastError ?? Exception('Tous les serveurs Overpass sont indisponibles');
  }

  /// Exécute une requête Overpass QL en essayant chaque endpoint tour à
  /// tour, et retourne le JSON décodé (`elements` etc).
  ///
  /// FIX 406 : requête en GET avec le paramètre `data=`, sans header
  /// `Accept` — Overpass renvoie 406 si un Accept trop restrictif est envoyé.
  static Future<Map<String, dynamic>> query(
    String overpassQl, {
    List<String> endpoints = defaultEndpoints,
    Duration timeout = const Duration(seconds: 30),
    String userAgent = 'PulseExplorer/1.0 (contact: app@pulsegps.local)',
  }) async {
    Exception? lastError;

    for (final endpoint in endpoints) {
      try {
        final uri = Uri.parse(endpoint).replace(
          queryParameters: {'data': overpassQl},
        );
        final resp = await http.get(
          uri,
          headers: {'User-Agent': userAgent},
        ).timeout(timeout);

        if (resp.statusCode == 200) {
          return json.decode(resp.body) as Map<String, dynamic>;
        }
        if (resp.statusCode == 429 || resp.statusCode == 503) {
          lastError = Exception('Serveur surchargé (${resp.statusCode})');
          continue;
        }
        throw Exception(
            'Erreur Overpass ${resp.statusCode}: ${resp.body.substring(0, resp.body.length.clamp(0, 200))}');
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        continue;
      }
    }
    throw lastError ?? Exception('Tous les serveurs Overpass sont indisponibles');
  }
}
