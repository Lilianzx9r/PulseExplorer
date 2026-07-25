import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/material.dart';
import 'gpx_track.dart';
import 'poi_layer.dart';
import 'georef_engine.dart';
import 'map_calibration_screen.dart';

/// Painter utilisant la transformation affine calibrée pour aligner GPX + POI
class CalibratedOverlayPainter extends CustomPainter {
  final List<GpxTrack>      tracks;
  final List<PoiLayer>      poiLayers;
  final ui.Image?           screenshotImage;
  final CalibrationResult?  calibration;
  final Offset              manualOffset;
  final bool                showCalibPoints;

  CalibratedOverlayPainter({
    required this.tracks,
    required this.poiLayers,
    this.screenshotImage,
    this.calibration,
    this.manualOffset = Offset.zero,
    this.showCalibPoints = true,
  });

  /// Convertit lat/lon → pixel écran via la transformation calibrée
  Offset _latLonToPixel(double lat, double lon, Size size) {
    if (calibration != null) {
      final px = calibration!.transform.latLonToPixel(lat, lon, size);
      return px + manualOffset;
    }
    // Fallback : centrer
    return Offset(size.width / 2, size.height / 2) + manualOffset;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Screenshot en fond
    if (screenshotImage != null) {
      final src = Rect.fromLTWH(0, 0,
          screenshotImage!.width.toDouble(),
          screenshotImage!.height.toDouble());
      canvas.drawImageRect(screenshotImage!, src,
          Rect.fromLTWH(0, 0, size.width, size.height), Paint());
    }

    // Tracés GPX
    for (final track in tracks) {
      if (!track.visible || track.data.trackPoints.isEmpty) continue;
      _paintTrack(canvas, size, track);
    }

    // Couches POI
    for (final layer in poiLayers) {
      if (!layer.visible) continue;
      for (final poi in layer.points) {
        _paintPoi(canvas, size, poi, layer.color);
      }
    }

    // Points de calage (croix de référence)
    if (showCalibPoints && calibration != null) {
      for (final pt in calibration!.points) {
        _paintCalibMark(canvas, pt.pixel);
      }
    }
  }

  void _paintTrack(Canvas canvas, Size size, GpxTrack track) {
    final pts = track.data.trackPoints;

    final shadow = Paint()
      ..color = Colors.black.withOpacity(0.25)
      ..strokeWidth = 5.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final line = Paint()
      ..color = track.color.withOpacity(0.88)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final path = Path(), shadowPath = Path();
    for (int i = 0; i < pts.length; i++) {
      final px = _latLonToPixel(pts[i].lat, pts[i].lon, size);
      if (i == 0) { path.moveTo(px.dx, px.dy); shadowPath.moveTo(px.dx, px.dy); }
      else        { path.lineTo(px.dx, px.dy); shadowPath.lineTo(px.dx, px.dy); }
    }
    canvas.drawPath(shadowPath, shadow);
    canvas.drawPath(path, line);

    _drawMarker(canvas, _latLonToPixel(pts.first.lat, pts.first.lon, size),
        Colors.green, 'Depart');
    if (pts.length > 1)
      _drawMarker(canvas, _latLonToPixel(pts.last.lat, pts.last.lon, size),
          Colors.red, 'Arrivee');
    for (final wp in track.data.waypoints)
      _drawMarker(canvas, _latLonToPixel(wp.lat, wp.lon, size),
          Colors.orange, wp.name ?? '');
  }

  void _drawMarker(Canvas canvas, Offset pos, Color color, String label) {
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

  void _paintPoi(Canvas canvas, Size size, PoiPoint poi, Color color) {
    final pos = _latLonToPixel(poi.lat, poi.lon, size);
    canvas.drawCircle(pos, 18, Paint()..color = color.withOpacity(0.22));
    canvas.drawCircle(pos, 18, Paint()
      ..color = color.withOpacity(0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0);
    canvas.drawCircle(pos, 8, Paint()..color = Colors.white);
    canvas.drawCircle(pos, 7, Paint()..color = color);

    final label = poi.name.length > 20 ? poi.name.substring(0, 18) + '..' : poi.name;
    final tp = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(
          color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromLTWH(pos.dx + 12, pos.dy - tp.height / 2 - 3,
        tp.width + 8, tp.height + 6);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        Paint()..color = color.withOpacity(0.85));
    tp.paint(canvas, Offset(pos.dx + 16, pos.dy - tp.height / 2));
  }

  /// Petite croix aux points de calage (repère de qualité)
  void _paintCalibMark(Canvas canvas, Offset pos) {
    final p = Paint()
      ..color = Colors.cyan.withOpacity(0.8)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(pos.dx - 6, pos.dy), Offset(pos.dx + 6, pos.dy), p);
    canvas.drawLine(Offset(pos.dx, pos.dy - 6), Offset(pos.dx, pos.dy + 6), p);
    canvas.drawCircle(pos, 5, Paint()
      ..color = Colors.cyan.withOpacity(0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0);
  }

  @override
  bool shouldRepaint(CalibratedOverlayPainter old) =>
      old.tracks != tracks || old.calibration != calibration ||
      old.screenshotImage != screenshotImage ||
      old.manualOffset != manualOffset || old.poiLayers != poiLayers;
}
