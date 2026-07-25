import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/material.dart';
import 'gpx_track.dart';
import 'poi_layer.dart';
import 'nominatim_helper.dart';

class GpxOverlayPainter extends CustomPainter {
  final List<GpxTrack>  tracks;
  final BoundingBox     mapBbox;
  final ui.Image?       screenshotImage;
  final Offset          offset;
  final List<PoiLayer>  poiLayers;

  GpxOverlayPainter({
    required this.tracks,
    required this.mapBbox,
    this.screenshotImage,
    this.offset    = Offset.zero,
    this.poiLayers = const [],
  });

  Offset _toPixel(double lat, double lon, Size size) {
    final x = (lon - mapBbox.minLon) / (mapBbox.maxLon - mapBbox.minLon) * size.width;
    final y = (1 - (lat - mapBbox.minLat) / (mapBbox.maxLat - mapBbox.minLat)) * size.height;
    return Offset(x + offset.dx, y + offset.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Fond screenshot
    if (screenshotImage != null) {
      final src = Rect.fromLTWH(0, 0,
          screenshotImage!.width.toDouble(), screenshotImage!.height.toDouble());
      canvas.drawImageRect(screenshotImage!, src,
          Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    }

    // Tracés GPX
    for (final track in tracks) {
      if (!track.visible || track.data.trackPoints.isEmpty) continue;
      _paintTrack(canvas, size, track);
    }

    // Couches POI avec surlignage
    for (final layer in poiLayers) {
      if (!layer.visible) continue;
      for (final poi in layer.points) {
        _paintPoi(canvas, size, poi, layer.color);
      }
    }
  }

  void _paintTrack(Canvas canvas, Size size, GpxTrack track) {
    final pts = track.data.trackPoints;
    final shadowPaint = Paint()
      ..color = Colors.black.withOpacity(0.25)
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final trackPaint = Paint()
      ..color = track.color.withOpacity(0.88)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final path = Path(), shadowPath = Path();
    for (int i = 0; i < pts.length; i++) {
      final px = _toPixel(pts[i].lat, pts[i].lon, size);
      if (i == 0) { path.moveTo(px.dx, px.dy); shadowPath.moveTo(px.dx, px.dy); }
      else        { path.lineTo(px.dx, px.dy); shadowPath.lineTo(px.dx, px.dy); }
    }
    canvas.drawPath(shadowPath, shadowPaint);
    canvas.drawPath(path, trackPaint);

    _drawTrackMarker(canvas, _toPixel(pts.first.lat, pts.first.lon, size), Colors.green, 'Depart');
    if (pts.length > 1)
      _drawTrackMarker(canvas, _toPixel(pts.last.lat, pts.last.lon, size), Colors.red, 'Arrivee');
    for (final wp in track.data.waypoints)
      _drawTrackMarker(canvas, _toPixel(wp.lat, wp.lon, size), Colors.orange, wp.name ?? '');
  }

  void _drawTrackMarker(Canvas canvas, Offset pos, Color color, String label) {
    canvas.drawCircle(pos, 9, Paint()..color = Colors.white);
    canvas.drawCircle(pos, 7, Paint()..color = color);
    if (label.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(
          color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold,
          shadows: const [Shadow(color: Colors.black, blurRadius: 3)])),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pos.dx + 11, pos.dy - tp.height / 2));
    }
  }

  /// POI avec surlignage coloré bien visible sur la carte
  void _paintPoi(Canvas canvas, Size size, PoiPoint poi, Color color) {
    final pos = _toPixel(poi.lat, poi.lon, size);

    // Halo de surlignage (cercle semi-transparent)
    canvas.drawCircle(pos, 18,
        Paint()..color = color.withOpacity(0.25));
    canvas.drawCircle(pos, 18,
        Paint()
          ..color = color.withOpacity(0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0);

    // Icone centrale
    canvas.drawCircle(pos, 8, Paint()..color = Colors.white);
    canvas.drawCircle(pos, 7, Paint()..color = color);

    // Petite etoile au centre pour les POI
    _drawStar(canvas, pos, 4, color == Colors.white ? Colors.grey : Colors.white);

    // Etiquette avec fond surligné
    final label = poi.name.length > 20 ? poi.name.substring(0, 18) + '..' : poi.name;
    final tp = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(
        color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();

    // Fond de l'etiquette
    final labelRect = Rect.fromLTWH(
      pos.dx + 12, pos.dy - tp.height / 2 - 3,
      tp.width + 8, tp.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(4)),
      Paint()..color = color.withOpacity(0.85),
    );
    // Ombre portee
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect.translate(1, 1), const Radius.circular(4)),
      Paint()..color = Colors.black.withOpacity(0.2),
    );
    tp.paint(canvas, Offset(pos.dx + 16, pos.dy - tp.height / 2));

    // Ligne de liaison etiquette -> point
    canvas.drawLine(
      Offset(pos.dx + 9, pos.dy),
      Offset(pos.dx + 12, pos.dy),
      Paint()..color = color..strokeWidth = 1.5,
    );
  }

  void _drawStar(Canvas canvas, Offset center, double r, Color color) {
    final paint = Paint()..color = color..strokeWidth = 1.2..style = PaintingStyle.stroke;
    for (int i = 0; i < 4; i++) {
      final angle = i * pi / 4;
      canvas.drawLine(
        Offset(center.dx + cos(angle) * r, center.dy + sin(angle) * r),
        Offset(center.dx - cos(angle) * r, center.dy - sin(angle) * r),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(GpxOverlayPainter old) =>
      old.tracks != tracks || old.mapBbox != mapBbox ||
      old.screenshotImage != screenshotImage || old.offset != offset ||
      old.poiLayers != poiLayers;
}


/// Painter de debug : affiche les POI avec leur position calculee + bbox
class PoiDebugPainter extends CustomPainter {
  final List<PoiLayer> poiLayers;
  final BoundingBox    mapBbox;
  final ui.Image?      screenshotImage;

  PoiDebugPainter({
    required this.poiLayers,
    required this.mapBbox,
    this.screenshotImage,
  });

  Offset _toPixel(double lat, double lon, Size size) {
    final x = (lon - mapBbox.minLon) / (mapBbox.maxLon - mapBbox.minLon) * size.width;
    final y = (1 - (lat - mapBbox.minLat) / (mapBbox.maxLat - mapBbox.minLat)) * size.height;
    return Offset(x, y);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Fond screenshot assombri
    if (screenshotImage != null) {
      canvas.drawImageRect(
        screenshotImage!,
        Rect.fromLTWH(0, 0, screenshotImage!.width.toDouble(), screenshotImage!.height.toDouble()),
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = Colors.white.withOpacity(0.6),
      );
    }

    // Grille
    final gridPaint = Paint()
      ..color = Colors.blue.withOpacity(0.25)
      ..strokeWidth = 0.5;
    for (int i = 0; i <= 5; i++) {
      canvas.drawLine(Offset(size.width * i / 5, 0),
          Offset(size.width * i / 5, size.height), gridPaint);
      canvas.drawLine(Offset(0, size.height * i / 5),
          Offset(size.width, size.height * i / 5), gridPaint);
    }

    // Info bbox
    _drawLabel(canvas,
      'BBOX: ${mapBbox.minLat.toStringAsFixed(3)},${mapBbox.minLon.toStringAsFixed(3)}'
      ' > ${mapBbox.maxLat.toStringAsFixed(3)},${mapBbox.maxLon.toStringAsFixed(3)}',
      const Offset(4, 4), Colors.blue);

    // POI
    for (final layer in poiLayers) {
      if (!layer.visible) continue;
      int idx = 0;
      for (final poi in layer.points) {
        final pos = _toPixel(poi.lat, poi.lon, size);
        final inBounds = pos.dx >= 0 && pos.dx <= size.width &&
                         pos.dy >= 0 && pos.dy <= size.height;
        final dotColor = inBounds ? Colors.green.shade700 : Colors.red.shade700;

        // Halo
        canvas.drawCircle(pos, 14,
            Paint()..color = dotColor.withOpacity(0.25));
        // Contour
        canvas.drawCircle(pos, 14,
            Paint()
              ..color = dotColor
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0);
        // Numéro
        _drawLabel(canvas, '${idx + 1}', Offset(pos.dx - 4, pos.dy - 6),
            dotColor, fontSize: 10);
        // Nom + coords
        final poiLabel = poi.name + '  ' + (inBounds ? 'OK' : 'HORS ZONE')
            + '\n' + poi.lat.toStringAsFixed(4) + ', ' + poi.lon.toStringAsFixed(4);
        _drawLabel(canvas, poiLabel,
          Offset(pos.dx + 16, pos.dy - 10),
          inBounds ? Colors.green.shade900 : Colors.red.shade900,
          fontSize: 9,
        );
        idx++;
      }
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset pos, Color color,
      {double fontSize = 10}) {
    final tp = TextPainter(
      text: TextSpan(text: text,
          style: TextStyle(color: color, fontSize: fontSize,
              fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    // Fond blanc
    canvas.drawRect(
      Rect.fromLTWH(pos.dx - 1, pos.dy - 1, tp.width + 4, tp.height + 2),
      Paint()..color = Colors.white.withOpacity(0.85),
    );
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(_) => true;
}
