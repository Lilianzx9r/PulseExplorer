import 'dart:io';
import 'package:xml/xml.dart';

/// Parse une valeur d'altitude GPX en rejetant NaN/Infinity — `double.tryParse`
/// accepte littéralement les textes "NaN"/"Infinity" et les convertit en
/// valeurs non-finies, ce qui plante ensuite tout calcul (.toInt(), min/max...)
/// en aval. Un fichier GPX corrompu ou mal généré peut contenir de telles
/// valeurs ; on les traite comme une altitude absente.
double? _parseFiniteEle(String? text) {
  if (text == null || text.isEmpty) return null;
  final v = double.tryParse(text);
  if (v == null || !v.isFinite) return null;
  return v;
}

class GpxPoint {
  final double lat;
  final double lon;
  final double? ele;
  final String? name;

  GpxPoint({required this.lat, required this.lon, this.ele, this.name});
}

class GpxData {
  final List<GpxPoint> trackPoints;
  final List<GpxPoint> waypoints;
  final String? name;

  double get minLat =>
      trackPoints.map((p) => p.lat).reduce((a, b) => a < b ? a : b);
  double get maxLat =>
      trackPoints.map((p) => p.lat).reduce((a, b) => a > b ? a : b);
  double get minLon =>
      trackPoints.map((p) => p.lon).reduce((a, b) => a < b ? a : b);
  double get maxLon =>
      trackPoints.map((p) => p.lon).reduce((a, b) => a > b ? a : b);

  double get centerLat => (minLat + maxLat) / 2;
  double get centerLon => (minLon + maxLon) / 2;

  GpxData({
    required this.trackPoints,
    required this.waypoints,
    this.name,
  });
}

class GpxParser {
  static GpxData parse(String xmlContent) {
    final document = XmlDocument.parse(xmlContent);
    final root = document.rootElement;

    String? trackName;
    final trackPoints = <GpxPoint>[];
    final waypoints = <GpxPoint>[];

    final metaName = root.findAllElements('name').firstOrNull;
    trackName = metaName?.innerText;

    for (final wpt in root.findAllElements('wpt')) {
      final lat = double.tryParse(wpt.getAttribute('lat') ?? '');
      final lon = double.tryParse(wpt.getAttribute('lon') ?? '');
      if (lat != null && lon != null) {
        waypoints.add(GpxPoint(
          lat: lat,
          lon: lon,
          ele: _parseFiniteEle(wpt.findElements('ele').firstOrNull?.innerText),
          name: wpt.findElements('name').firstOrNull?.innerText,
        ));
      }
    }

    for (final trk in root.findAllElements('trk')) {
      trackName ??= trk.findElements('name').firstOrNull?.innerText;
      for (final trkseg in trk.findAllElements('trkseg')) {
        for (final trkpt in trkseg.findAllElements('trkpt')) {
          final lat = double.tryParse(trkpt.getAttribute('lat') ?? '');
          final lon = double.tryParse(trkpt.getAttribute('lon') ?? '');
          if (lat != null && lon != null) {
            trackPoints.add(GpxPoint(
              lat: lat,
              lon: lon,
              ele: _parseFiniteEle(trkpt.findElements('ele').firstOrNull?.innerText),
            ));
          }
        }
      }
    }

    // Fallback: route points
    if (trackPoints.isEmpty) {
      for (final rte in root.findAllElements('rte')) {
        for (final rtept in rte.findAllElements('rtept')) {
          final lat = double.tryParse(rtept.getAttribute('lat') ?? '');
          final lon = double.tryParse(rtept.getAttribute('lon') ?? '');
          if (lat != null && lon != null) {
            trackPoints.add(GpxPoint(lat: lat, lon: lon));
          }
        }
      }
    }

    if (trackPoints.isEmpty) {
      throw Exception('Aucun point de tracé trouvé dans le fichier GPX');
    }

    return GpxData(
        trackPoints: trackPoints, waypoints: waypoints, name: trackName);
  }

  static Future<GpxData> parseFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) throw Exception('Fichier introuvable: $filePath');
    return parse(await file.readAsString());
  }
}
