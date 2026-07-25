import 'dart:math';
import 'package:flutter/material.dart';

/// Un point de calage : position pixel sur l'image + coordonnées GPS réelles
class CalibrationPoint {
  final Offset pixel;   // position sur l'image (px)
  final double lat;
  final double lon;
  final String cityName;

  const CalibrationPoint({
    required this.pixel,
    required this.lat,
    required this.lon,
    required this.cityName,
  });
}

/// Transformation affine 2D : pixel → coordonnées GPS
/// Calculée à partir d'au moins 2 points de calage
class GeoTransform {
  // Coefficients : lat = a*px + b*py + c
  //                lon = d*px + e*py + f
  final double a, b, c, d, e, f;
  final int pointCount;

  const GeoTransform({
    required this.a, required this.b, required this.c,
    required this.d, required this.e, required this.f,
    required this.pointCount,
  });

  /// Convertit un pixel en coordonnées GPS
  (double lat, double lon) pixelToLatLon(Offset pixel) {
    final lat = a * pixel.dx + b * pixel.dy + c;
    final lon = d * pixel.dx + e * pixel.dy + f;
    return (lat, lon);
  }

  /// Convertit des coordonnées GPS en pixel (inverse)
  Offset latLonToPixel(double lat, double lon, Size imageSize) {
    // Résolution du système inverse par moindres carrés approchés
    // Pour 2 points : solution exacte
    final det = a * e - b * d;
    if (det.abs() < 1e-12) {
      // Dégénéré : projection simple
      return Offset(
        (lon - f) / (e.abs() > 1e-12 ? e : 1),
        (lat - c) / (a.abs() > 1e-12 ? a : 1),
      );
    }
    final px = (e * (lat - c) - b * (lon - f)) / det;
    final py = (a * (lon - f) - d * (lat - c)) / det;
    return Offset(px, py);
  }

  /// Erreur RMS sur les points de calage (en pixels)
  double rmsError(List<CalibrationPoint> pts, Size imageSize) {
    if (pts.isEmpty) return 0;
    double sum = 0;
    for (final p in pts) {
      final reprojected = latLonToPixel(p.lat, p.lon, imageSize);
      final dx = reprojected.dx - p.pixel.dx;
      final dy = reprojected.dy - p.pixel.dy;
      sum += dx * dx + dy * dy;
    }
    return sqrt(sum / pts.length);
  }
}

class GeoRefEngine {
  /// Calcule la transformation affine à partir de 2+ points de calage
  /// Avec 2 points : translation + échelle (transformation de similarité)
  /// Avec 3+ points : transformation affine complète (moindres carrés)
  static GeoTransform? compute(List<CalibrationPoint> pts) {
    if (pts.length < 2) return null;

    if (pts.length == 2) {
      return _compute2Points(pts[0], pts[1]);
    } else {
      return _computeLeastSquares(pts);
    }
  }

  /// Transformation avec 2 points (translation + échelle uniforme)
  static GeoTransform _compute2Points(CalibrationPoint p1, CalibrationPoint p2) {
    final dpx = p2.pixel.dx - p1.pixel.dx;
    final dpy = p2.pixel.dy - p1.pixel.dy;
    final dlat = p2.lat - p1.lat;
    final dlon = p2.lon - p1.lon;

    final pixDist = sqrt(dpx * dpx + dpy * dpy);
    if (pixDist < 1e-6) return _fallbackTransform(p1);

    // Échelle
    final scaleX = dlon / (dpx.abs() > 1e-6 ? dpx : 1e-6);
    final scaleY = -dlat / (dpy.abs() > 1e-6 ? dpy : 1e-6); // Y inversé

    final a = -scaleY;
    final e = scaleX;
    final b = 0.0;
    final d = 0.0;
    final c = p1.lat - a * p1.pixel.dx - b * p1.pixel.dy;
    final f = p1.lon - d * p1.pixel.dx - e * p1.pixel.dy;

    return GeoTransform(a: a, b: b, c: c, d: d, e: e, f: f, pointCount: 2);
  }

  /// Moindres carrés pour 3+ points
  static GeoTransform _computeLeastSquares(List<CalibrationPoint> pts) {
    // Résout : [lat] = [px py 1] * [a b c]^T
    //          [lon] = [px py 1] * [d e f]^T
    final n = pts.length;

    // Matrice A (n x 3)
    List<List<double>> A = pts.map((p) =>
        [p.pixel.dx, p.pixel.dy, 1.0]).toList();
    List<double> bLat = pts.map((p) => p.lat).toList();
    List<double> bLon = pts.map((p) => p.lon).toList();

    // A^T * A
    final ata = _matMul3x3(_transpose(A), A);
    final atbLat = _matVecMul(_transpose(A), bLat);
    final atbLon = _matVecMul(_transpose(A), bLon);

    // Résolution par inversement 3x3
    final ataInv = _invert3x3(ata);
    if (ataInv == null) return _fallbackTransform(pts.first);

    final coeffLat = _matVecMul(ataInv, atbLat);
    final coeffLon = _matVecMul(ataInv, atbLon);

    return GeoTransform(
      a: coeffLat[0], b: coeffLat[1], c: coeffLat[2],
      d: coeffLon[0], e: coeffLon[1], f: coeffLon[2],
      pointCount: n,
    );
  }

  static GeoTransform _fallbackTransform(CalibrationPoint p) {
    return GeoTransform(
      a: -0.0001, b: 0, c: p.lat,
      d: 0, e: 0.0001, f: p.lon,
      pointCount: 1,
    );
  }

  // ── Algèbre linéaire 3x3 ──────────────────────────────────────────────────
  static List<List<double>> _transpose(List<List<double>> m) {
    final rows = m.length, cols = m[0].length;
    return List.generate(cols, (i) => List.generate(rows, (j) => m[j][i]));
  }

  static List<List<double>> _matMul3x3(
      List<List<double>> A, List<List<double>> B) {
    return List.generate(3, (i) => List.generate(3, (j) =>
        A[i][0]*B[0][j] + A[i][1]*B[1][j] + A[i][2]*B[2][j]));
  }

  static List<double> _matVecMul(List<List<double>> A, List<double> v) {
    return List.generate(A.length, (i) =>
        A[i].asMap().entries.fold(0.0, (s, e) => s + e.value * v[e.key]));
  }

  static List<List<double>>? _invert3x3(List<List<double>> m) {
    final det = m[0][0]*(m[1][1]*m[2][2]-m[1][2]*m[2][1])
               -m[0][1]*(m[1][0]*m[2][2]-m[1][2]*m[2][0])
               +m[0][2]*(m[1][0]*m[2][1]-m[1][1]*m[2][0]);
    if (det.abs() < 1e-12) return null;
    final inv = [
      [(m[1][1]*m[2][2]-m[1][2]*m[2][1])/det, (m[0][2]*m[2][1]-m[0][1]*m[2][2])/det, (m[0][1]*m[1][2]-m[0][2]*m[1][1])/det],
      [(m[1][2]*m[2][0]-m[1][0]*m[2][2])/det, (m[0][0]*m[2][2]-m[0][2]*m[2][0])/det, (m[0][2]*m[1][0]-m[0][0]*m[1][2])/det],
      [(m[1][0]*m[2][1]-m[1][1]*m[2][0])/det, (m[0][1]*m[2][0]-m[0][0]*m[2][1])/det, (m[0][0]*m[1][1]-m[0][1]*m[1][0])/det],
    ];
    return inv;
  }
}
