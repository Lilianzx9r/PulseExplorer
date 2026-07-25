import 'dart:convert';
import 'dart:io';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'navigation_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// offline_route_cache.dart
//
// Met en cache les routes OSRM calculées sur disque, associées à :
//   - position de départ (arrondie ≈11m)
//   - position d'arrivée (idem)
//   - profil de transport (walking/cycling/driving)
// Durée de vie du cache : 7 jours
// ─────────────────────────────────────────────────────────────────────────────

class OfflineRouteCache {
  static const _maxAgeHours = 7 * 24;
  static const _snap = 4;

  static String _key(LatLng from, LatLng to, String profile) {
    double r(double v) => (v * _pow10(_snap)).roundToDouble() / _pow10(_snap);
    return '${profile}_${r(from.latitude)},${r(from.longitude)}'
           '_${r(to.latitude)},${r(to.longitude)}';
  }

  static double _pow10(int n) {
    double v = 1;
    for (int i = 0; i < n; i++) v *= 10;
    return v;
  }

  static Future<Directory> _cacheDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/PulseGpx/route_cache');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _cacheFile(String key) async {
    final dir = await _cacheDir();
    return File('${dir.path}/$key.json');
  }

  static Future<NavRoute?> get(LatLng from, LatLng to, String profile) async {
    try {
      final file = await _cacheFile(_key(from, to, profile));
      if (!file.existsSync()) return null;

      final modified = file.lastModifiedSync();
      if (DateTime.now().difference(modified).inHours > _maxAgeHours) {
        await file.delete();
        return null;
      }

      final data = json.decode(await file.readAsString()) as Map<String, dynamic>;
      return _fromJson(data);
    } catch (_) {
      return null;
    }
  }

  static Future<void> put(
      LatLng from, LatLng to, String profile, NavRoute route) async {
    try {
      if (route.isOffline) return;
      final file = await _cacheFile(_key(from, to, profile));
      await file.writeAsString(json.encode(_toJson(route)));
    } catch (_) {}
  }

  static Future<double> cacheSizeMb() async {
    final dir = await _cacheDir();
    if (!dir.existsSync()) return 0;
    double total = 0;
    await for (final f in dir.list()) {
      if (f is File) total += await f.length();
    }
    return total / 1024 / 1024;
  }

  static Future<void> clearExpired() async {
    final dir = await _cacheDir();
    if (!dir.existsSync()) return;
    await for (final f in dir.list()) {
      if (f is File) {
        final age = DateTime.now().difference(f.statSync().modified).inHours;
        if (age > _maxAgeHours) await f.delete();
      }
    }
  }

  static Future<void> clearAll() async {
    final dir = await _cacheDir();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  static Map<String, dynamic> _toJson(NavRoute r) => {
    'totalDistanceM': r.totalDistanceM,
    'totalDurationS': r.totalDurationS,
    'isOffline':      r.isOffline,
    'geometry': r.geometry.map((p) => [p.latitude, p.longitude]).toList(),
    'steps': r.steps.map((s) => {
      'instruction': s.instruction,
      'distanceM':   s.distanceM,
      'durationS':   s.durationS,
      'maneuver':    s.maneuver,
      'lat':         s.location.latitude,
      'lon':         s.location.longitude,
    }).toList(),
  };

  static NavRoute _fromJson(Map<String, dynamic> d) => NavRoute(
    totalDistanceM: (d['totalDistanceM'] as num).toDouble(),
    totalDurationS: (d['totalDurationS'] as num).toDouble(),
    isOffline:      d['isOffline'] as bool? ?? false,
    geometry: (d['geometry'] as List).map((p) =>
        LatLng((p as List)[0].toDouble(), p[1].toDouble())).toList(),
    steps: (d['steps'] as List).map((s) => NavStep(
      instruction: s['instruction'] as String,
      distanceM:   (s['distanceM'] as num).toDouble(),
      durationS:   (s['durationS'] as num).toDouble(),
      maneuver:    s['maneuver'] as String?,
      location:    LatLng((s['lat'] as num).toDouble(),
                          (s['lon'] as num).toDouble()),
    )).toList(),
  );
}
