import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'session_store.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'gpx_track.dart';

/// Format de sauvegarde complète PulseGpx (.pgpx = zip renommé)
/// Contient :
///   manifest.json    — version, date, métadonnées
///   sessions.json    — toutes les sessions
///   poi_layers.json  — toutes les couches POI (couches racine)
///   poi_folders.json — dossiers POI
///   tracks.json      — tracés GPX avec points complets (sérialisés)
///   photos/          — copies des photos locales (jpg/png...)
class BackupData {
  final List<VisuSession> sessions;
  final List<PoiLayer>    poiLayers;
  final List<PoiFolder>   poiFolders;
  final List<GpxTrack>    tracks;
  final DateTime          savedAt;
  final String            version;

  BackupData({
    required this.sessions,
    required this.poiLayers,
    required this.poiFolders,
    required this.tracks,
    required this.savedAt,
    this.version = '1.0',
  });
}

class BackupService {
  static const _backupVersion = '1.1'; // bumped: tracks + photos inclus

  // ── Sauvegarder ────────────────────────────────────────────────────────────
  static Future<String?> save({
    required BuildContext context,
    required List<VisuSession> sessions,
    required List<PoiLayer>    poiLayers,
    required List<PoiFolder>   poiFolders,
    required List<GpxTrack>    tracks,
  }) async {
    try {
      final archive = Archive();

      // ── Collecter toutes les photos locales (couches racine + dossiers) ───
      final allPoiPoints = <PoiPoint>[
        ...poiLayers.expand((l) => l.points),
        ...poiFolders.expand((f) => f.layers.expand((l) => l.points)),
      ];
      // Map : chemin original → nom dans le zip (photos/<basename>)
      final photoMap = <String, String>{};
      for (final poi in allPoiPoints) {
        for (final path in poi.localPhotos) {
          if (!photoMap.containsKey(path)) {
            final baseName = path.split('/').last.split('\\').last;
            // En cas de collision de nom, préfixer avec un index
            var zipName = 'photos/$baseName';
            int idx = 0;
            while (photoMap.values.contains(zipName)) {
              idx++;
              final ext = baseName.contains('.')
                  ? '.${baseName.split('.').last}' : '';
              final stem = baseName.contains('.')
                  ? baseName.substring(0, baseName.lastIndexOf('.')) : baseName;
              zipName = 'photos/${stem}_$idx$ext';
            }
            photoMap[path] = zipName;
          }
        }
      }

      // Réécrire les poi avec les noms zip au lieu des chemins absolus
      List<PoiLayer> rewrittenLayers = _rewritePhotoPaths(poiLayers, photoMap);
      List<PoiFolder> rewrittenFolders = _rewriteFolderPhotoPaths(poiFolders, photoMap);

      // manifest.json
      final manifest = jsonEncode({
        'version':    _backupVersion,
        'app':        'PulseGpx',
        'savedAt':    DateTime.now().toIso8601String(),
        'sessions':   sessions.length,
        'poiLayers':  poiLayers.length,
        'poiFolders': poiFolders.length,
        'tracks':     tracks.length,
        'photos':     photoMap.length,
      });
      _addJson(archive, 'manifest.json', manifest);

      // sessions.json
      _addJson(archive, 'sessions.json',
          jsonEncode(sessions.map((s) => s.toJson()).toList()));

      // poi_layers.json (chemins photos réécrits)
      _addJson(archive, 'poi_layers.json',
          jsonEncode(rewrittenLayers.map((l) => l.toJson()).toList()));

      // poi_folders.json (chemins photos réécrits)
      _addJson(archive, 'poi_folders.json',
          jsonEncode(rewrittenFolders.map((f) => f.toJson()).toList()));

      // tracks.json — points GPX complets via SessionStore.serializeTracks
      final tracksData = SessionStore.serializeTracks(tracks);
      _addJson(archive, 'tracks.json', jsonEncode(tracksData));

      // photos/ — copie des fichiers images locaux
      for (final entry in photoMap.entries) {
        try {
          final f = File(entry.key);
          if (await f.exists()) {
            final imgBytes = await f.readAsBytes();
            archive.addFile(ArchiveFile(
                entry.value, imgBytes.length, imgBytes));
          }
        } catch (_) {
          // Photo inaccessible — on continue sans elle
        }
      }

      // Encoder en ZIP
      final zipBytes = ZipEncoder().encode(archive)!;
      final uint8 = Uint8List.fromList(zipBytes);

      final dir  = await _getOutputDir();
      final date = DateTime.now();
      final name = 'PulseGpx_${date.year}${_pad(date.month)}${_pad(date.day)}'
                   '_${_pad(date.hour)}${_pad(date.minute)}.pgpx';
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(uint8);

      return file.path;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur sauvegarde : $e'),
          backgroundColor: Colors.red,
        ));
      }
      return null;
    }
  }

  // ── Importer ───────────────────────────────────────────────────────────────
  static Future<BackupData?> load(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return null;

      final file = result.files.first;
      final name = file.name.toLowerCase();

      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) return null;

      // Accepter .pgpx, .zip, ou magic bytes ZIP (PK\x03\x04)
      final isZipByMagic = bytes.length >= 4 &&
          bytes[0] == 0x50 && bytes[1] == 0x4B &&
          bytes[2] == 0x03 && bytes[3] == 0x04;

      if (!name.endsWith('.pgpx') && !name.endsWith('.zip') && !isZipByMagic) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Format non reconnu — choisissez un fichier .pgpx'),
            backgroundColor: Colors.orange,
          ));
        }
        return null;
      }

      // Extraire les photos dans le dossier interne avant de parser
      final photosDir = await _getPhotosDir();
      return await _parseBackup(bytes, photosDir);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur import : $e'),
          backgroundColor: Colors.red,
        ));
      }
      return null;
    }
  }

  // ── Importer une ancienne base (sessions.json standalone) ─────────────────
  static Future<List<VisuSession>?> loadLegacySessions(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return null;

      final file  = result.files.first;
      final bytes = file.bytes ??
          (file.path != null ? await File(file.path!).readAsBytes() : null);
      if (bytes == null) return null;

      final content = utf8.decode(bytes);
      final fname   = file.name.toLowerCase();

      if (fname.endsWith('.json')) {
        final data = jsonDecode(content);
        if (data is List) {
          return data
              .map((e) => VisuSession.fromJson(e as Map<String, dynamic>))
              .toList();
        }
        if (data is Map && data.containsKey('sessions')) {
          return (data['sessions'] as List)
              .map((e) => VisuSession.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Format non reconnu — attendu .json ou .pgpx'),
          backgroundColor: Colors.orange,
        ));
      }
      return null;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur lecture : $e'),
          backgroundColor: Colors.red,
        ));
      }
      return null;
    }
  }

  // ── Parse un .pgpx (ZIP) ──────────────────────────────────────────────────
  /// Méthode publique pour parser un ZIP .pgpx depuis des bytes
  /// (utilisée par SessionStore.importFromFile)
  static Future<BackupData> parseBackupBytes(
      Uint8List bytes, Directory photosDir) =>
      _parseBackup(bytes, photosDir);

  static Future<BackupData> _parseBackup(
      Uint8List bytes, Directory photosDir) async {
    final archive = ZipDecoder().decodeBytes(bytes);

    List<VisuSession> sessions   = [];
    List<PoiLayer>    poiLayers  = [];
    List<PoiFolder>   poiFolders = [];
    List<GpxTrack>    tracks     = [];
    DateTime          savedAt    = DateTime.now();
    String            version    = '?';

    // Map zipName → chemin local extrait  (photos/foo.jpg → /data/.../foo.jpg)
    final extractedPhotos = <String, String>{};

    // Passe 1 : extraire les photos
    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (!entry.name.startsWith('photos/')) continue;
      try {
        final rawBytes = Uint8List.fromList(entry.content as List<int>);
        final baseName = entry.name.split('/').last;
        final dest = File('${photosDir.path}/$baseName');
        await dest.writeAsBytes(rawBytes);
        extractedPhotos[entry.name] = dest.path;
      } catch (_) {}
    }

    // Passe 2 : parser les JSON
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final entryName = entry.name.split('/').last;
      // Ignorer les photos (déjà traitées)
      if (entry.name.startsWith('photos/')) continue;

      final Uint8List rawBytes = Uint8List.fromList(entry.content as List<int>);
      String content;
      try {
        content = utf8.decode(rawBytes);
      } catch (_) {
        continue;
      }

      switch (entryName) {
        case 'manifest.json':
          final m = jsonDecode(content) as Map;
          version = m['version']?.toString() ?? '?';
          savedAt = DateTime.tryParse(m['savedAt']?.toString() ?? '')
              ?? DateTime.now();
          break;

        case 'sessions.json':
          final decoded = jsonDecode(content);
          final list = decoded is List
              ? decoded
              : (decoded is Map && decoded.containsKey('sessions')
                  ? decoded['sessions'] as List : <dynamic>[]);
          sessions = list
              .map((e) => VisuSession.fromJson(e as Map<String, dynamic>))
              .toList();
          break;

        case 'poi_layers.json':
          final decoded = jsonDecode(content);
          final list = decoded is List ? decoded : <dynamic>[];
          poiLayers = list
              .map((e) => PoiLayer.fromJson(e as Map<String, dynamic>))
              .toList();
          // Réécrire les chemins photos zip → chemins locaux
          poiLayers = _restorePhotoPaths(poiLayers, extractedPhotos);
          break;

        case 'poi_folders.json':
          final decoded = jsonDecode(content);
          final list = decoded is List ? decoded : <dynamic>[];
          poiFolders = list
              .map((e) => PoiFolder.fromJson(e as Map<String, dynamic>))
              .toList();
          poiFolders = _restoreFolderPhotoPaths(poiFolders, extractedPhotos);
          break;

        case 'tracks.json':
          // Format v1.1+ : points complets
          final decoded = jsonDecode(content);
          final list = decoded is List ? decoded : <dynamic>[];
          tracks = SessionStore.deserializeTracks(
              list.cast<Map<String, dynamic>>());
          break;

        case 'index.json':
          // Format v1.0 legacy : seulement les métadonnées, pas de points
          // On ignore — les tracés ne peuvent pas être reconstruits sans points
          break;
      }
    }

    return BackupData(
      sessions:   sessions,
      poiLayers:  poiLayers,
      poiFolders: poiFolders,
      tracks:     tracks,
      savedAt:    savedAt,
      version:    version,
    );
  }

  // ── Réécriture des chemins photos (sauvegarde) ────────────────────────────
  /// Remplace les chemins absolus locaux par les noms zip relatifs (photos/xxx)
  static List<PoiLayer> _rewritePhotoPaths(
      List<PoiLayer> layers, Map<String, String> photoMap) {
    return layers.map((l) => PoiLayer(
      id:      l.id,
      label:   l.label,
      color:   l.color,
      visible: l.visible,
      points:  l.points.map((p) => p.copyWith(
        localPhotos: p.localPhotos
            .map((path) => photoMap[path] ?? path)
            .toList(),
      )).toList(),
    )).toList();
  }

  static List<PoiFolder> _rewriteFolderPhotoPaths(
      List<PoiFolder> folders, Map<String, String> photoMap) {
    return folders.map((f) => PoiFolder(
      id:       f.id,
      label:    f.label,
      visible:  f.visible,
      expanded: f.expanded,
      layers:   _rewritePhotoPaths(f.layers, photoMap),
    )).toList();
  }

  // ── Restauration des chemins photos (import) ──────────────────────────────
  /// Remplace les noms zip relatifs par les chemins locaux extraits
  static List<PoiLayer> _restorePhotoPaths(
      List<PoiLayer> layers, Map<String, String> extractedPhotos) {
    return layers.map((l) => PoiLayer(
      id:      l.id,
      label:   l.label,
      color:   l.color,
      visible: l.visible,
      points:  l.points.map((p) => p.copyWith(
        localPhotos: p.localPhotos.map((zipPath) {
          final resolved = extractedPhotos[zipPath];
          return resolved ?? zipPath;
        }).toList(),
      )).toList(),
    )).toList();
  }

  static List<PoiFolder> _restoreFolderPhotoPaths(
      List<PoiFolder> folders, Map<String, String> extractedPhotos) {
    return folders.map((f) => PoiFolder(
      id:       f.id,
      label:    f.label,
      visible:  f.visible,
      expanded: f.expanded,
      layers:   _restorePhotoPaths(f.layers, extractedPhotos),
    )).toList();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  static void _addJson(Archive archive, String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  static Future<Directory> _getOutputDir() async {
    try {
      final base = Directory('/storage/emulated/0/Documents/PulseGpx');
      if (!await base.exists()) await base.create(recursive: true);
      return base;
    } catch (_) {
      return await getApplicationDocumentsDirectory();
    }
  }

  /// Dossier interne pour stocker les photos extraites des backups
  static Future<Directory> _getPhotosDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/imported_photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');
}
