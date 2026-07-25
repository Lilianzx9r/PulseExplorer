import 'poi_layer.dart';
import 'core/services/geocoding_service.dart';

/// Résout les coordonnées manquantes via Nominatim
class PoiGeocoder {

  /// Géocode un seul nom → (lat, lon) ou null
  static Future<({double lat, double lon})?> search(String name) async {
    final r = await _geocode(name);
    if (r == null) return null;
    return (lat: r.$1, lon: r.$2);
  }

  /// Indique si un PoiPoint a des coordonnées valides (non nulles/zéro)
  static bool hasValidCoords(PoiPoint p) =>
      p.lat != 0.0 || p.lon != 0.0;

  /// Pour une liste de POI, résout les coordonnées manquantes via Nominatim.
  /// Retourne la liste complète — les POI non résolus ont lat=0/lon=0 ET
  /// description marquée avec ⚠️ pour signaler l'absence.
  static Future<List<PoiPoint>> geocodeMissing(
      List<PoiPoint> points, {
      void Function(int done, int total, String current)? onProgress,
  }) async {
    final result = <PoiPoint>[];
    int done = 0;

    for (final poi in points) {
      // Coordonnées déjà valides → on garde
      if (hasValidCoords(poi)) {
        result.add(poi);
        done++;
        onProgress?.call(done, points.length, '');
        continue;
      }

      // Recherche Nominatim
      onProgress?.call(done, points.length, poi.name);
      final resolved = await _geocode(poi.name);
      if (resolved != null) {
        result.add(poi.copyWith(
          lat: resolved.$1,
          lon: resolved.$2,
          description: poi.description,  // garder la description enrichie
        ));
      } else {
        // Coords introuvables → garder le POI avec marqueur d'absence
        result.add(poi.copyWith(
          lat: 0.0, lon: 0.0,
          description: '⚠️ Coordonnées introuvables${poi.description != null ? " · ${poi.description}" : ""}',
        ));
      }
      done++;
      onProgress?.call(done, points.length, '');
      await Future.delayed(const Duration(milliseconds: 1100)); // rate limit Nominatim
    }
    return result;
  }

  /// Géocode un seul nom de lieu → (lat, lon) ou null.
  /// Délègue au service de géocodage unique (GeocodingService).
  static Future<(double, double)?> _geocode(String name) =>
      GeocodingService.geocodeSingle(name, timeout: const Duration(seconds: 5));

  /// Géocode une liste de noms et retourne les PoiPoints trouvés
  static Future<List<PoiPoint>> geocodeNames(
      List<String> names, {
      void Function(int done, int total, String current)? onProgress,
  }) async {
    final result = <PoiPoint>[];
    int done = 0;

    for (final name in names) {
      onProgress?.call(done, names.length, name);
      final coords = await _geocode(name);
      if (coords != null) {
        result.add(PoiPoint(
          name: name, lat: coords.$1, lon: coords.$2, type: 'poi'));
      }
      done++;
      await Future.delayed(const Duration(milliseconds: 1100));
    }
    onProgress?.call(done, names.length, '');
    return result;
  }
}
