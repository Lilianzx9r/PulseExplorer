import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'app_dirs.dart';
import 'backup_service.dart';
import 'gpx_track.dart';
import 'gpx_parser.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'core/models/library_folder.dart';

/// Un contexte de visualisation sauvegardé
class VisuSession {
  String         label;
  final String   id;
  // Config carte
  String         mapSource;
  String         cityName;
  String         checkIn;
  String         checkOut;
  // Bbox
  double?        bboxMinLat, bboxMaxLat, bboxMinLon, bboxMaxLon;
  String?        bboxLabel;
  // Tracés GPX (sérialisés comme chemins ou bytes base64)
  List<Map<String, dynamic>> gpxTracksData;
  // Couches POI
  List<Map<String, dynamic>> poiLayersData;
  // Dossiers POI
  List<Map<String, dynamic>> poiFoldersData;
  // Dossiers GPX (nouveau — jusqu'ici seuls les POI avaient des dossiers)
  List<Map<String, dynamic>> gpxFoldersData;
  // Timestamp
  final DateTime createdAt;
  DateTime       updatedAt;

  VisuSession({
    required this.label,
    required this.mapSource,
    required this.cityName,
    required this.checkIn,
    required this.checkOut,
    this.bboxMinLat, this.bboxMaxLat,
    this.bboxMinLon, this.bboxMaxLon,
    this.bboxLabel,
    List<Map<String, dynamic>>? gpxTracksData,
    List<Map<String, dynamic>>? poiLayersData,
    List<Map<String, dynamic>>? poiFoldersData,
    List<Map<String, dynamic>>? gpxFoldersData,
    String? id,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id        = id ?? DateTime.now().millisecondsSinceEpoch.toString(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now(),
       gpxTracksData = gpxTracksData ?? [],
       poiLayersData  = poiLayersData  ?? [],
       poiFoldersData = poiFoldersData ?? [],
       gpxFoldersData = gpxFoldersData ?? [];

  Map<String, dynamic> toJson() => {
    'id': id, 'label': label,
    'mapSource': mapSource, 'cityName': cityName,
    'checkIn': checkIn, 'checkOut': checkOut,
    'bboxMinLat': bboxMinLat, 'bboxMaxLat': bboxMaxLat,
    'bboxMinLon': bboxMinLon, 'bboxMaxLon': bboxMaxLon,
    'bboxLabel': bboxLabel,
    'gpxTracksData': gpxTracksData,
    'poiLayersData':  poiLayersData,
    'poiFoldersData': poiFoldersData,
    'gpxFoldersData': gpxFoldersData,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory VisuSession.fromJson(Map<String, dynamic> j) => VisuSession(
    id:         j['id'],
    label:      j['label'] ?? 'Session',
    mapSource:  j['mapSource'] ?? 'webview',
    cityName:   j['cityName'] ?? '',
    checkIn:    j['checkIn']  ?? '',
    checkOut:   j['checkOut'] ?? '',
    bboxMinLat: j['bboxMinLat'] != null ? (j['bboxMinLat'] as num).toDouble() : null,
    bboxMaxLat: j['bboxMaxLat'] != null ? (j['bboxMaxLat'] as num).toDouble() : null,
    bboxMinLon: j['bboxMinLon'] != null ? (j['bboxMinLon'] as num).toDouble() : null,
    bboxMaxLon: j['bboxMaxLon'] != null ? (j['bboxMaxLon'] as num).toDouble() : null,
    bboxLabel:  j['bboxLabel'],
    gpxTracksData: (j['gpxTracksData'] as List?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [],
    poiLayersData: (j['poiLayersData'] as List?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [],
    poiFoldersData: (j['poiFoldersData'] as List?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [],
    gpxFoldersData: (j['gpxFoldersData'] as List?)
        ?.map((e) => e as Map<String, dynamic>).toList() ?? [],
    createdAt: j['createdAt'] != null ? DateTime.parse(j['createdAt']) : DateTime.now(),
    updatedAt: j['updatedAt'] != null ? DateTime.parse(j['updatedAt']) : DateTime.now(),
  );
}

/// Gestionnaire de sessions — lecture/écriture sur disque
class SessionStore {
  static const _fileName = 'gpx_sessions.json';

  static Future<File> _file() async {
    // Stockage interne app — toujours accessible, jamais perdu
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Exporter les sessions vers un fichier choisi par l'utilisateur
  static Future<String?> exportToFile(List<VisuSession> sessions) async {
    // Écrire d'abord dans le fichier interne
    await saveAll(sessions);
    final srcFile = await _file();
    // Laisser l'utilisateur choisir où copier
    final destDir = await FilePicker.platform.getDirectoryPath();
    if (destDir == null) return null;
    AppDirs.setLastExportDir(destDir);
    final dest = File('$destDir/$_fileName');
    await srcFile.copy(dest.path);
    return dest.path;
  }

  /// Importer les sessions depuis un fichier choisi par l'utilisateur
  /// Importe depuis un fichier :
  /// - `.pgpx` / ZIP : délègue à BackupService._parseBackup, retourne les sessions
  /// - `.json`       : ancien format sessions JSON
  static Future<List<VisuSession>?> importFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final f = result.files.first;

    Uint8List bytes;
    if (f.bytes != null) {
      bytes = f.bytes!;
    } else if (f.path != null) {
      bytes = await File(f.path!).readAsBytes();
    } else {
      return null;
    }

    // Détecter ZIP par magic bytes PK\x03\x04
    final isZip = bytes.length >= 4 &&
        bytes[0] == 0x50 && bytes[1] == 0x4B &&
        bytes[2] == 0x03 && bytes[3] == 0x04;

    try {
      if (isZip) {
        // Fichier .pgpx — parser via BackupService
        final backup = await BackupService.parseBackupBytes(
            bytes, await _photosDir());
        return backup.sessions;
      } else {
        // Ancien format JSON
        final content = utf8.decode(bytes);
        final decoded = json.decode(content);
        final list = decoded is List
            ? decoded
            : (decoded is Map && decoded.containsKey('sessions')
                ? decoded['sessions'] as List
                : <dynamic>[]);
        return list
            .map((e) => VisuSession.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      }
    } catch (e) {
      throw Exception('Fichier de sessions invalide : $e');
    }
  }

  static Future<Directory> _photosDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir    = Directory('${appDir.path}/imported_photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<List<VisuSession>> loadAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final raw  = await f.readAsString();
      final list = json.decode(raw) as List;
      return list.map((e) => VisuSession.fromJson(e as Map<String, dynamic>)).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAll(List<VisuSession> sessions) async {
    final f    = await _file();
    final data = json.encode(sessions.map((s) => s.toJson()).toList());
    await f.writeAsString(data);
  }

  static Future<void> upsert(VisuSession session) async {
    final sessions = await loadAll();
    final idx = sessions.indexWhere((s) => s.id == session.id);
    session.updatedAt = DateTime.now();
    if (idx >= 0) sessions[idx] = session;
    else sessions.insert(0, session);
    await saveAll(sessions);
  }

  static Future<void> delete(String id) async {
    final sessions = await loadAll();
    sessions.removeWhere((s) => s.id == id);
    await saveAll(sessions);
  }

  /// Sérialise les GpxTracks pour la session (stocke le XML GPX brut)
  static List<Map<String, dynamic>> serializeTracks(List<GpxTrack> tracks) {
    return tracks.map((t) => {
      'fileName': t.fileName,
      'displayName': t.displayName,
      'color': t.color.value,
      'visible': t.visible,
      // On stocke les points directement (pas le XML original)
      'points': t.data.trackPoints.map((p) => {
        'lat': p.lat, 'lon': p.lon,
        if (p.ele != null) 'ele': p.ele,
      }).toList(),
      'waypoints': t.data.waypoints.map((w) => {
        'lat': w.lat, 'lon': w.lon,
        if (w.name != null) 'name': w.name,
      }).toList(),
      'name': t.data.name,
    }).toList();
  }

  /// Sérialise les dossiers POI
  static List<Map<String, dynamic>> serializeFolders(List<PoiFolder> folders) =>
      folders.map((f) => f.toJson()).toList();

  /// Désérialise les dossiers POI
  static List<PoiFolder> deserializeFolders(List<Map<String, dynamic>> data) {
    try {
      return data.map((d) => PoiFolder.fromJson(d)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Sérialise les dossiers GPX (nouveau — voir core/models/library_folder.dart)
  static List<Map<String, dynamic>> serializeGpxFolders(List<GpxFolder> folders) =>
      folders.map((f) => f.toJson()).toList();

  /// Désérialise les dossiers GPX
  static List<GpxFolder> deserializeGpxFolders(List<Map<String, dynamic>> data) {
    try {
      return data.map((d) => GpxFolder.fromJson(d)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Désérialise les GpxTracks depuis la session
  static List<GpxTrack> deserializeTracks(List<Map<String, dynamic>> data) {
    final tracks = <GpxTrack>[];
    for (final d in data) {
      try {
        final pts = (d['points'] as List).map((p) => GpxPoint(
          lat: (p['lat'] as num).toDouble(),
          lon: (p['lon'] as num).toDouble(),
          ele: p['ele'] != null ? (p['ele'] as num).toDouble() : null,
        )).toList();
        final wpts = (d['waypoints'] as List? ?? []).map((w) => GpxPoint(
          lat:  (w['lat']  as num).toDouble(),
          lon:  (w['lon']  as num).toDouble(),
          name: w['name'],
        )).toList();
        final gpxData = GpxData(
          trackPoints: pts,
          waypoints:   wpts,
          name: d['name'],
        );
        tracks.add(GpxTrack(
          data:     gpxData,
          fileName: d['fileName'] ?? '',
          color:    Color(d['color'] as int),
          visible:  d['visible'] ?? true,
        ));
      } catch (_) {}
    }
    return tracks;
  }
}
