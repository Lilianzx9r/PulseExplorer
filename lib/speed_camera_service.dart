import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'navigation_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// speed_camera_service.dart
//
// Couche radars fixes (OSM highway=speed_camera) avec alerte de proximité
// active UNIQUEMENT dans les pays où cet usage est légal.
//
// La juridiction est déterminée par la position GPS réelle de l'utilisateur
// au moment de l'usage (reverse-geocoding), jamais par une simple case à
// cocher — l'affichage statique de la couche reste possible partout (c'est
// de l'information cartographique comme n'importe quel autre POI), seule
// l'ALERTE ACTIVE de proximité (son/popup déclenché par la géolocalisation)
// est conditionnée à la juridiction.
// ─────────────────────────────────────────────────────────────────────────────

class SpeedCamera {
  final String? id;
  final double lat, lon;
  final String? maxSpeed;
  final String? direction;
  const SpeedCamera({this.id, required this.lat, required this.lon,
      this.maxSpeed, this.direction});
}

/// Statut légal d'un pays vis-à-vis des avertisseurs de radars actifs
enum RadarAlertStatus {
  allowed,    // alerte active autorisée
  forbidden,  // alerte active interdite (même affichage info peut être sensible)
  unknown,    // pays non reconnu — par prudence, alerte désactivée
}

class SpeedCameraService {
  SpeedCameraService._();

  // ── Listes juridictionnelles ────────────────────────────────────────────
  // Sources : réglementations nationales 2026, à vérifier avant tout usage
  // transfrontalier — ces listes sont indicatives et peuvent évoluer.

  /// Pays où l'alerte active de proximité radar est autorisée
  static const _allowedCountries = {
    'FR', 'BE', 'ES', 'FI', 'GR', 'HU', 'IT', 'LT', 'LU',
    'NL', 'PL', 'PT', 'RO', 'GB', 'SE', 'CZ',
  };

  /// Pays interdisant strictement l'usage (et parfois même la possession)
  /// d'un avertisseur de radar actif
  static const _forbiddenCountries = {
    'CH', // Suisse — interdiction stricte y compris transport
    'DE', // Allemagne
    'AT', // Autriche
    'SI', // Slovénie
    'CY', // Chypre
    'TR', // Turquie
    'IE', // Irlande
    'SK', // Slovaquie
  };

  static RadarAlertStatus statusForCountry(String? isoCode) {
    if (isoCode == null) return RadarAlertStatus.unknown;
    final code = isoCode.toUpperCase();
    if (_forbiddenCountries.contains(code)) return RadarAlertStatus.forbidden;
    if (_allowedCountries.contains(code))    return RadarAlertStatus.allowed;
    return RadarAlertStatus.unknown; // pays non listé → prudence par défaut
  }

  // ── Détection du pays courant via la position GPS réelle ──────────────────
  /// Reverse-geocoding Nominatim — détermine le pays à partir de la position
  /// GPS actuelle. Ne dépend jamais d'une sélection manuelle de l'utilisateur.
  static Future<String?> detectCountryCode(LatLng position) async {
    try {
      final resp = await http.get(
        Uri.parse('https://nominatim.openstreetmap.org/reverse'
            '?lat=${position.latitude}&lon=${position.longitude}'
            '&format=json&zoom=3&addressdetails=1'),
        headers: {'User-Agent': 'PulseGpx/1.0 (educational)'},
      ).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final data = json.decode(resp.body) as Map;
      final code = data['address']?['country_code']?.toString();
      return code?.toUpperCase();
    } catch (_) {
      return null;
    }
  }

  // ── Téléchargement des radars OSM pour une zone ────────────────────────────
  static Future<List<SpeedCamera>> fetchInBbox(
      double minLat, double maxLat, double minLon, double maxLon) async {
    final bbox = '$minLat,$minLon,$maxLat,$maxLon';
    final query = '[out:json][timeout:30];'
        '(node["highway"="speed_camera"]($bbox);'
        ' node["enforcement"="maxspeed"]($bbox););'
        'out body;';
    try {
      final resp = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        body: {'data': query},
        headers: {'User-Agent': 'PulseGpx/1.0'},
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return [];
      final data = json.decode(resp.body) as Map;
      final elements = (data['elements'] as List?) ?? [];
      return elements.where((e) => e['type'] == 'node').map((e) {
        final tags = (e['tags'] as Map?) ?? {};
        return SpeedCamera(
          id: e['id']?.toString(),
          lat: (e['lat'] as num).toDouble(),
          lon: (e['lon'] as num).toDouble(),
          maxSpeed: tags['maxspeed']?.toString(),
          direction: tags['direction']?.toString(),
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // ── Détection de proximité ─────────────────────────────────────────────────
  /// Retourne le radar le plus proche dans un rayon donné (mètres), ou null
  static SpeedCamera? nearestWithin(
      LatLng position, List<SpeedCamera> cameras, double radiusM) {
    SpeedCamera? closest;
    double closestDist = double.infinity;
    for (final cam in cameras) {
      final d = NavigationService.distanceM(
          position, LatLng(cam.lat, cam.lon));
      if (d <= radiusM && d < closestDist) {
        closest = cam;
        closestDist = d;
      }
    }
    return closest;
  }
}
