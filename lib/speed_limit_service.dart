import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'navigation_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// speed_limit_service.dart
//
// Limitations de vitesse OSM (tag maxspeed) :
//   - Affichage statique sur la carte (segments colorés/étiquetés)
//   - Indicateur dynamique : limite du segment où se trouve l'utilisateur
// ─────────────────────────────────────────────────────────────────────────────

class SpeedLimitSegment {
  final List<LatLng> points; // géométrie du segment (way OSM)
  final int? maxSpeedKmh;    // null si non renseigné dans OSM
  final String? roadName;
  const SpeedLimitSegment({required this.points, this.maxSpeedKmh, this.roadName});
}

class SpeedLimitService {
  SpeedLimitService._();

  /// Télécharge les segments avec limitation de vitesse pour une bbox
  static Future<List<SpeedLimitSegment>> fetchInBbox(
      double minLat, double maxLat, double minLon, double maxLon) async {
    final bbox = '$minLat,$minLon,$maxLat,$maxLon';
    final query = '[out:json][timeout:30];'
        'way["highway"]["maxspeed"]($bbox);'
        'out geom;';
    try {
      final resp = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        body: {'data': query},
        headers: {'User-Agent': 'PulseGpx/1.0'},
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return [];
      final data = json.decode(resp.body) as Map;
      final elements = (data['elements'] as List?) ?? [];
      final segments = <SpeedLimitSegment>[];
      for (final el in elements) {
        if (el['type'] != 'way') continue;
        final geom = el['geometry'] as List?;
        if (geom == null || geom.length < 2) continue;
        final tags = (el['tags'] as Map?) ?? {};
        final maxspeedRaw = tags['maxspeed']?.toString();
        final parsed = _parseMaxSpeed(maxspeedRaw);
        segments.add(SpeedLimitSegment(
          points: geom.map((g) => LatLng(
              (g['lat'] as num).toDouble(), (g['lon'] as num).toDouble())).toList(),
          maxSpeedKmh: parsed,
          roadName: tags['name']?.toString(),
        ));
      }
      return segments;
    } catch (_) {
      return [];
    }
  }

  /// Parse la valeur OSM maxspeed (ex: "50", "50 mph", "FR:urban", "none")
  static int? _parseMaxSpeed(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw == 'none') return null; // pas de limite (ex: autoroute allemande)
    final numMatch = RegExp(r'(\d+)').firstMatch(raw);
    if (numMatch == null) {
      // Valeurs implicites nationales approximatives
      if (raw.contains('urban')) return 50;
      if (raw.contains('rural')) return 80;
      if (raw.contains('motorway')) return 130;
      return null;
    }
    final value = int.tryParse(numMatch.group(1)!);
    if (value == null) return null;
    if (raw.contains('mph')) return (value * 1.60934).round();
    return value;
  }

  /// Trouve la limite de vitesse du segment le plus proche d'une position,
  /// dans un rayon donné (mètres). Retourne null si aucun segment proche.
  static SpeedLimitSegment? nearestSegment(
      LatLng position, List<SpeedLimitSegment> segments, {double radiusM = 50}) {
    SpeedLimitSegment? closest;
    double closestDist = double.infinity;
    for (final seg in segments) {
      for (final p in seg.points) {
        final d = NavigationService.distanceM(position, p);
        if (d <= radiusM && d < closestDist) {
          closest = seg;
          closestDist = d;
        }
      }
    }
    return closest;
  }
}
