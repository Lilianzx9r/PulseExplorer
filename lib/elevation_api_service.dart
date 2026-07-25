import 'dart:convert';
import 'package:http/http.dart' as http;
import 'gpx_parser.dart';

// ─────────────────────────────────────────────────────────────────────────────
// elevation_api_service.dart
//
// Récupère l'altitude de points GPS via l'API publique gratuite OpenTopoData
// (https://api.opentopodata.org), basée sur des modèles numériques de terrain
// (SRTM 30m). Aucune clé requise.
//
// Limites de l'API publique (à respecter strictement pour rester "gentil") :
//   - Max 100 points par requête
//   - Max 1 requête par seconde
//   - Max 1000 requêtes par jour
//
// Un tracé GPX peut contenir des milliers de points : on échantillonne un
// sous-ensemble (par défaut 200 points, soit 2 requêtes), puis on interpole
// linéairement l'altitude des points intermédiaires le long du tracé.
// ─────────────────────────────────────────────────────────────────────────────

class ElevationApiService {
  ElevationApiService._();

  static const _base = 'https://api.opentopodata.org/v1/srtm30m';
  static const _maxPerRequest = 100;
  static const _minDelayMs = 1100; // > 1s pour respecter la limite de débit

  /// Récupère l'altitude d'une liste de points (lat, lon) — un seul appel si
  /// ≤100 points, sinon plusieurs requêtes espacées d'au moins 1,1 s.
  /// Retourne une liste de même longueur, avec `null` pour les points en échec.
  static Future<List<double?>> fetchElevations(
      List<(double lat, double lon)> points, {
      void Function(String status)? onStatus,
  }) async {
    final results = <double?>[];
    for (int i = 0; i < points.length; i += _maxPerRequest) {
      final batch = points.skip(i).take(_maxPerRequest).toList();
      onStatus?.call(
          'Récupération altitude ${i + batch.length}/${points.length}…');
      final batchResults = await _fetchBatch(batch);
      results.addAll(batchResults);
      if (i + _maxPerRequest < points.length) {
        await Future.delayed(const Duration(milliseconds: _minDelayMs));
      }
    }
    return results;
  }

  static Future<List<double?>> _fetchBatch(
      List<(double lat, double lon)> batch) async {
    try {
      final locations = batch.map((p) => '${p.$1},${p.$2}').join('|');
      final resp = await http.get(
        Uri.parse('$_base?locations=$locations'),
        headers: {'User-Agent': 'PulseGpx/1.0 (educational)'},
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        return List.filled(batch.length, null);
      }
      final data = json.decode(resp.body) as Map;
      if (data['status'] != 'OK') {
        return List.filled(batch.length, null);
      }
      final results = data['results'] as List;
      return results.map((r) {
        final ele = (r as Map)['elevation'];
        return ele == null ? null : (ele as num).toDouble();
      }).toList();
    } catch (_) {
      return List.filled(batch.length, null);
    }
  }

  // ── Enrichissement d'un tracé GPX complet ──────────────────────────────────

  /// Enrichit les points d'un tracé sans altitude en interrogeant l'API sur
  /// un échantillon (par défaut 200 points répartis uniformément), puis
  /// interpole linéairement l'altitude des points intermédiaires.
  /// Retourne un nouveau GpxData — ne modifie pas l'original.
  static Future<GpxData> enrichTrackElevation(
    GpxData data, {
    int maxSamples = 200,
    void Function(String status)? onStatus,
  }) async {
    final points = data.trackPoints;
    if (points.isEmpty) return data;

    // Indices échantillonnés uniformément (toujours inclure premier/dernier)
    final n = points.length;
    final sampleCount = n <= maxSamples ? n : maxSamples;
    final sampleIndices = <int>[];
    if (sampleCount <= 1) {
      sampleIndices.add(0);
    } else {
      for (int i = 0; i < sampleCount; i++) {
        sampleIndices.add((i * (n - 1) / (sampleCount - 1)).round());
      }
    }
    final uniqueIndices = sampleIndices.toSet().toList()..sort();

    onStatus?.call('Interrogation de ${uniqueIndices.length} points…');
    final coords = uniqueIndices.map((i) => (points[i].lat, points[i].lon)).toList();
    final elevations = await fetchElevations(coords, onStatus: onStatus);

    // Construire la table éparse index -> altitude (ignorer les échecs)
    final sparse = <int, double>{};
    for (int k = 0; k < uniqueIndices.length; k++) {
      final e = elevations[k];
      if (e != null) sparse[uniqueIndices[k]] = e;
    }

    if (sparse.isEmpty) {
      onStatus?.call('❌ Aucune altitude récupérée');
      return data; // échec complet, on garde les données d'origine
    }

    // Interpolation linéaire entre les indices connus
    final knownIndices = sparse.keys.toList()..sort();
    final newPoints = <GpxPoint>[];
    for (int i = 0; i < n; i++) {
      final p = points[i];
      double? ele = sparse[i];
      if (ele == null) {
        // Chercher les voisins connus les plus proches (avant/après)
        int? before, after;
        for (final k in knownIndices) {
          if (k <= i) before = k;
          if (k >= i && after == null) after = k;
        }
        if (before != null && after != null && before != after) {
          final t = (i - before) / (after - before);
          ele = sparse[before]! + (sparse[after]! - sparse[before]!) * t;
        } else if (before != null) {
          ele = sparse[before];
        } else if (after != null) {
          ele = sparse[after];
        }
      }
      newPoints.add(GpxPoint(lat: p.lat, lon: p.lon, ele: ele, name: p.name));
    }

    onStatus?.call('✅ Altitudes récupérées');
    return GpxData(trackPoints: newPoints, waypoints: data.waypoints, name: data.name);
  }
}
