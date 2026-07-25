import 'dart:convert';
import 'package:flutter/services.dart';
import 'session_store.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';

class MigrationResult {
  final List<VisuSession> sessions;
  final List<PoiLayer>    poiLayers;
  final List<PoiFolder>   poiFolders;

  MigrationResult({
    required this.sessions,
    required this.poiLayers,
    required this.poiFolders,
  });

  bool get isEmpty =>
      sessions.isEmpty && poiLayers.isEmpty && poiFolders.isEmpty;

  String get summary {
    final parts = <String>[];
    if (sessions.isNotEmpty)
      parts.add('${sessions.length} session${sessions.length > 1 ? "s" : ""}');
    if (poiLayers.isNotEmpty)
      parts.add('${poiLayers.length} couche${poiLayers.length > 1 ? "s" : ""} POI');
    if (poiFolders.isNotEmpty)
      parts.add('${poiFolders.length} dossier${poiFolders.length > 1 ? "s" : ""}');
    return parts.join(', ');
  }
}

class MigrationService {
  static const _channel = MethodChannel('booking_gpx/capture');

  static Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isMigrationAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<MigrationResult?> readAll() async {
    try {
      final raw = await _channel.invokeMethod('migrateFromOldApp');
      if (raw == null) return null;

      // raw est une Map<String, String?> venant de Kotlin
      final map = Map<String, dynamic>.from(raw as Map);

      final sessions = _parseSessions(map['sessions']);
      final poiLayers = _parsePoiLayers(map['poiLayers']);
      final poiFolders = _parsePoiFolders(map['poiFolders']);

      final result = MigrationResult(
        sessions: sessions,
        poiLayers: poiLayers,
        poiFolders: poiFolders,
      );
      return result.isEmpty ? null : result;
    } catch (_) {
      return null;
    }
  }

  static List<VisuSession> _parseSessions(dynamic json) {
    if (json == null) return [];
    try {
      final list = jsonDecode(json.toString()) as List;
      return list
          .map((e) => VisuSession.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static List<PoiLayer> _parsePoiLayers(dynamic json) {
    if (json == null) return [];
    try {
      final list = jsonDecode(json.toString()) as List;
      return list
          .map((e) => PoiLayer.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static List<PoiFolder> _parsePoiFolders(dynamic json) {
    if (json == null) return [];
    try {
      final list = jsonDecode(json.toString()) as List;
      return list
          .map((e) => PoiFolder.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
