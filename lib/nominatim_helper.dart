import 'core/services/geocoding_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// nominatim_helper.dart
// Wrapper conservé pour compatibilité (utilisé pour les recherches de ville
// avec bounding box, ex: intégration Booking.com). La requête HTTP réelle
// est désormais centralisée dans GeocodingService — voir core/services/.
// ─────────────────────────────────────────────────────────────────────────────

class BoundingBox {
  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;
  final String displayName;

  BoundingBox({
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
    required this.displayName,
  });

  double get centerLat => (minLat + maxLat) / 2;
  double get centerLon => (minLon + maxLon) / 2;

  int get zoomLevel {
    double latSpan = maxLat - minLat;
    double lonSpan = maxLon - minLon;
    double span = latSpan > lonSpan ? latSpan : lonSpan;
    if (span < 0.05) return 14;
    if (span < 0.2) return 12;
    if (span < 0.5) return 11;
    if (span < 1.0) return 10;
    if (span < 3.0) return 8;
    return 7;
  }
}

class NominatimHelper {
  static Future<List<BoundingBox>> searchCity(String cityName) async {
    final results = await GeocodingService.search(
      cityName,
      limit: 5,
      addressDetails: true,
    );
    if (results.isEmpty) throw Exception('Ville "$cityName" introuvable');

    return results.where((r) => r.boundingBox != null).map((r) {
      final bbox = r.boundingBox!;
      return BoundingBox(
        minLat: bbox[0],
        maxLat: bbox[1],
        minLon: bbox[2],
        maxLon: bbox[3],
        displayName: r.displayName.isNotEmpty ? r.displayName : cityName,
      );
    }).toList();
  }

  static String buildBookingUrl({
    required BoundingBox bbox,
    required String checkIn,
    required String checkOut,
    int adults = 2,
    int rooms = 1,
  }) {
    final lat = bbox.centerLat.toStringAsFixed(6);
    final lon = bbox.centerLon.toStringAsFixed(6);
    final zoom = bbox.zoomLevel;
    final cityName = bbox.displayName.split(',').first;

    return 'https://www.booking.com/searchresults.fr.html'
        '?ss=${Uri.encodeComponent(cityName)}'
        '&checkin=$checkIn'
        '&checkout=$checkOut'
        '&group_adults=$adults'
        '&no_rooms=$rooms'
        '&map=1'
        '&map_lat=$lat'
        '&map_lon=$lon'
        '&map_zoom=$zoom'
        '&selected_currency=EUR';
  }
}
