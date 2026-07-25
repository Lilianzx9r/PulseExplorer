import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/material.dart';
import 'gpx_track.dart';
import 'georef_engine.dart';
import 'ocr_georef_service.dart';

/// Painter utilisant la transformation géoréférence pour aligner le GPX
class GeorefOverlayPainter extends CustomPainter {
  final List<GpxTrack>    tracks;
  final ui.Image?         screenshotImage;
  final GeoTransform?     transform;     // transformation pixel↔GPS calibrée
  final List<DetectedCity> cities;       // villes détectées (pour affichage)
  final bool              showCities;
  final bool              showGrid;
  final Offset            manualOffset;  // décalage manuel résiduel

  GeorefOverlayPainter({
    required this.tracks,
    this.screenshotImage,
    this.transform,
    this.cities = const [],
    this.showCities = true,
    this.showGrid = false,
    this.manualOffset = Offset.zero,
  });

  /// Convertit lat/lon → pixel en utilisant la transformation inverse
  Offset _latLonToPixel(double lat, double lon, Size size) {
    if (transform != null) {
      final px = transform!.latLonToPixel(lat, lon, size);
      return px + manualOffset;
    }
    // Fallback : projection simple si pas de transform
    return Offset(
      size.width  / 2 + manualOffset.dx,
      size.height / 2 + manualOffset.dy,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // ── Fond : screenshot ────────────────────────────────────────────────
    if (screenshotImage != null) {
      final src = Rect.fromLTWH(0, 0,
          screenshotImage!.width.toDouble(), screenshotImage!.height.toDouble());
      final dst = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(screenshotImage!, src, dst, Paint());
    }

    // ── Grille de coordonnées (debug) ────────────────────────────────────
    if (showGrid && transform != null) _drawGrid(canvas, size);

    // ── Tracés GPX ───────────────────────────────────────────────────────
    for (final track in tracks) {
      if (!track.visible || track.data.trackPoints.isEmpty) continue;
      _paintTrack(canvas, size, track);
    }

    // ── Villes détectées ─────────────────────────────────────────────────
    if (showCities) {
      for (final city in cities) {
        _drawCityMarker(canvas, city, size);
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

    final path       = Path();
    final shadowPath = Path();

    for (int i = 0; i < pts.length; i++) {
      final px = _latLonToPixel(pts[i].lat, pts[i].lon, size);
      if (i == 0) { path.moveTo(px.dx, px.dy); shadowPath.moveTo(px.dx, px.dy); }
      else        { path.lineTo(px.dx, px.dy); shadowPath.lineTo(px.dx, px.dy); }
    }

    canvas.drawPath(shadowPath, shadowPaint);
    canvas.drawPath(path, trackPaint);

    // Départ
    _drawMarker(canvas,
        _latLonToPixel(pts.first.lat, pts.first.lon, size),
        Colors.green, 'Départ');
    // Arrivée
    if (pts.length > 1)
      _drawMarker(canvas,
          _latLonToPixel(pts.last.lat, pts.last.lon, size),
          Colors.red, 'Arrivée');
    // Waypoints
    for (final wp in track.data.waypoints)
      _drawMarker(canvas,
          _latLonToPixel(wp.lat, wp.lon, size),
          Colors.orange, wp.name ?? '');
  }

  void _drawMarker(Canvas canvas, Offset pos, Color color, String label) {
    canvas.drawCircle(pos, 9, Paint()..color = Colors.white);
    canvas.drawCircle(pos, 7, Paint()..color = color);
    if (label.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(text: label, style: TextStyle(
          color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold,
          shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
        )),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pos.dx + 11, pos.dy - tp.height / 2));
    }
  }

  /// Marque la position des villes détectées par OCR
  void _drawCityMarker(Canvas canvas, DetectedCity city, Size size) {
    final pos = city.pixelCenter;

    // Croix de localisation
    final paint = Paint()
      ..color = Colors.amber.shade700
      ..strokeWidth = 2.0;
    const r = 8.0;
    canvas.drawLine(Offset(pos.dx - r, pos.dy), Offset(pos.dx + r, pos.dy), paint);
    canvas.drawLine(Offset(pos.dx, pos.dy - r), Offset(pos.dx, pos.dy + r), paint);
    canvas.drawCircle(pos, 4, Paint()..color = Colors.amber.shade700);
    canvas.drawCircle(pos, 4,
        Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);

    // Étiquette ville
    final tp = TextPainter(
      text: TextSpan(
        text: '📍 ${city.name}',
        style: TextStyle(
          color: Colors.amber.shade900,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.white.withOpacity(0.75),
          shadows: const [Shadow(color: Colors.white, blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx + 10, pos.dy - tp.height - 2));
  }

  void _drawGrid(Canvas canvas, Size size) {
    if (transform == null) return;
    final paint = Paint()
      ..color = Colors.blue.withOpacity(0.15)
      ..strokeWidth = 0.5;

    const steps = 6;
    for (int i = 0; i <= steps; i++) {
      final x = size.width  * i / steps;
      final y = size.height * i / steps;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(GeorefOverlayPainter old) =>
      old.tracks != tracks || old.transform != transform ||
      old.screenshotImage != screenshotImage || old.cities != cities ||
      old.manualOffset != manualOffset || old.showCities != showCities;
}
