import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'georef_engine.dart';

// ─────────────────────────────────────────────────────────────────────────────
// IMPORTANT : google_mlkit_text_recognition retiré du pubspec car il dépend
// de JNI qui ne compile pas sur Windows/Linux/macOS desktop.
//
// Sur mobile (Android/iOS) : l'OCR automatique n'est plus disponible.
// Alternative : calage manuel par tap sur la carte (toujours fonctionnel).
// ─────────────────────────────────────────────────────────────────────────────

class DetectedCity {
  final String name;
  final Offset pixelCenter;
  final double lat;
  final double lon;
  final double confidence;

  DetectedCity({
    required this.name,
    required this.pixelCenter,
    required this.lat,
    required this.lon,
    required this.confidence,
  });
}

class OcrGeorefResult {
  final List<DetectedCity> cities;
  final GeoTransform? transform;
  final String message;
  final bool success;

  OcrGeorefResult({
    required this.cities,
    this.transform,
    required this.message,
    required this.success,
  });
}

class OcrGeorefService {
  /// OCR géoréférencement — désactivé (ML Kit retiré pour compatibilité Windows).
  /// Utilisez le calage manuel : tap long sur 2 points de la carte.
  static Future<OcrGeorefResult> processImage(
    Uint8List imageBytes, {
    Size? imageSize,
    double? hintMinLat, double? hintMaxLat,
    double? hintMinLon, double? hintMaxLon,
  }) async {
    return OcrGeorefResult(
      cities:  [],
      message: 'OCR automatique non disponible sur cette plateforme.\n'
               'Utilisez le calage manuel : appuyez longuement sur 2 villes '
               'identifiables sur la carte.',
      success: false,
    );
  }

  static void dispose() {}
}
