import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'gpx_parser.dart';
import 'app_dirs.dart';
import 'gpx_track.dart';

const int kMaxZipBytes = 50 * 1024 * 1024;

class GpxLoader {

  // ── Choisir des fichiers GPX ou ZIP ───────────────────────────────────────
  static Future<List<GpxTrack>?> pickFiles(
    BuildContext context, {
    int maxZipBytes = kMaxZipBytes,
  }) async {
    await _requestPermissions();

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: true,   // bytes en mémoire (SAF Android)
      );
    } catch (e) {
      throw Exception("Impossible d'ouvrir le sélecteur : $e");
    }
    if (result == null || result.files.isEmpty) return null;

    final tracks = <GpxTrack>[];
    for (final f in result.files) {
      final name = f.name.toLowerCase();

      // Lire les bytes : priorité bytes (SAF), fallback path
      Uint8List? bytes;
      if (f.bytes != null && f.bytes!.isNotEmpty) {
        bytes = f.bytes!;
      } else if (f.path != null) {
        try { bytes = await File(f.path!).readAsBytes(); } catch (_) {}
      }
      if (bytes == null || bytes.isEmpty) {
        debugPrint('GpxLoader: cannot read ${f.name}');
        continue;
      }

      if (name.endsWith('.gpx')) {
        final t = _parseGpxBytes(bytes, f.name, tracks.length);
        if (t != null) tracks.add(t);
      } else if (name.endsWith('.zip')) {
        if (bytes.length > maxZipBytes) {
          if (context.mounted) _showSizeWarning(context, f.name, bytes.length, maxZipBytes);
          continue;
        }
        tracks.addAll(_extractGpxFromZip(bytes, tracks.length));
      } else {
        // Essayer de parser quand même comme GPX (certains fichiers n'ont pas l'extension)
        final t = _parseGpxBytes(bytes, f.name, tracks.length);
        if (t != null) tracks.add(t);
      }
    }

    if (tracks.isEmpty && result.files.isNotEmpty) {
      throw Exception(
        'Aucun tracé GPX valide trouvé dans les ${result.files.length} fichier(s) sélectionné(s).\n'
        'Vérifiez que les fichiers sont bien au format .gpx'
      );
    }
    return tracks.isEmpty ? null : tracks;
  }

  // ── Choisir un dossier ────────────────────────────────────────────────────
  static Future<List<GpxTrack>?> pickFolder(
    BuildContext context, {
    int maxZipBytes = kMaxZipBytes,
  }) async {
    await _requestPermissions();

    // Essai 1 : getDirectoryPath (chemin réel)
    String? dirPath;
    try { dirPath = await FilePicker.platform.getDirectoryPath(); } catch (_) {}

    if (dirPath != null && !dirPath.startsWith('content://')) {
      AppDirs.setLastImportDir(dirPath);
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        final tracks = await _scanDirectory(context, dir, maxZipBytes: maxZipBytes);
        return tracks.isEmpty ? null : tracks;
      }
    }

    // Fallback SAF : sélection multiple
    if (context.mounted) {
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Sélection de dossier'),
          content: const Text(
            'Sélectionnez tous les fichiers GPX/ZIP du dossier.\n\n'
            'Astuce : appuyer longuement → mode sélection multiple.'
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
    }
    return pickFiles(context, maxZipBytes: maxZipBytes);
  }

  // ── Scanner récursivement ─────────────────────────────────────────────────
  static Future<List<GpxTrack>> _scanDirectory(
    BuildContext context, Directory dir, {
    required int maxZipBytes, int depth = 0,
  }) async {
    if (depth > 5) return [];
    final tracks = <GpxTrack>[];
    try {
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last.toLowerCase();
        try {
          if (name.endsWith('.gpx')) {
            final bytes = await entity.readAsBytes();
            final t = _parseGpxBytes(bytes, entity.uri.pathSegments.last, tracks.length);
            if (t != null) tracks.add(t);
          } else if (name.endsWith('.zip')) {
            final bytes = await entity.readAsBytes();
            if (bytes.length > maxZipBytes) {
              if (context.mounted) _showSizeWarning(context, name, bytes.length, maxZipBytes);
              continue;
            }
            tracks.addAll(_extractGpxFromZip(bytes, tracks.length));
          }
        } catch (e) {
          debugPrint('Scan file error ($name): $e');
        }
      }
    } catch (e) {
      debugPrint('Scan dir error: $e');
    }
    return tracks;
  }

  // ── Extraire GPX d'un ZIP ─────────────────────────────────────────────────
  static List<GpxTrack> _extractGpxFromZip(Uint8List zipBytes, int offset) {
    final tracks = <GpxTrack>[];
    try {
      final archive = ZipDecoder().decodeBytes(zipBytes);
      for (final file in archive) {
        if (!file.isFile) continue;
        final name = file.name.split('/').last.split('\\').last;
        if (!name.toLowerCase().endsWith('.gpx')) continue;
        final bytes = Uint8List.fromList(file.content as List<int>);
        final t = _parseGpxBytes(bytes, name, offset + tracks.length);
        if (t != null) tracks.add(t);
      }
    } catch (e) { debugPrint('ZIP error: $e'); }
    return tracks;
  }

  // ── Parser GPX bytes ──────────────────────────────────────────────────────
  static GpxTrack? _parseGpxBytes(Uint8List bytes, String fileName, int colorIndex) {
    try {
      // Essayer UTF-8, puis latin-1 comme fallback
      String content;
      try {
        content = String.fromCharCodes(bytes);
      } catch (_) {
        content = String.fromCharCodes(bytes.map((b) => b & 0xFF));
      }
      final data = GpxParser.parse(content);
      if (data.trackPoints.isEmpty && data.waypoints.isEmpty) {
        debugPrint('GPX vide: $fileName');
        return null;
      }
      return GpxTrack(
        data:     data,
        fileName: fileName,
        color:    trackColorForIndex(colorIndex),
      );
    } catch (e) {
      debugPrint('GPX parse error ($fileName): $e');
      return null;
    }
  }

  // ── Image PNG/JPG ─────────────────────────────────────────────────────────
  static Future<Uint8List?> pickImageBytes(BuildContext context) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
    } catch (e) {
      throw Exception("Impossible d'ouvrir la galerie : $e");
    }
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    if (file.bytes != null && file.bytes!.isNotEmpty) return file.bytes!;
    if (file.path != null) return await File(file.path!).readAsBytes();
    return null;
  }

  // ── Permissions ───────────────────────────────────────────────────────────
  static Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) return;
    final sdk = await _androidSdk();
    if (sdk < 33) {
      // Android < 13 : demander READ_EXTERNAL_STORAGE
      final status = await Permission.storage.status;
      if (!status.isGranted) {
        final result = await Permission.storage.request();
        if (!result.isGranted) {
          debugPrint('Storage permission denied (sdk=$sdk)');
        }
      }
    }
    // Android >= 13 : READ_MEDIA_* gérés automatiquement par file_picker v8
  }

  static Future<int> _androidSdk() async {
    try {
      final s = await File('/system/build.prop').readAsString();
      final m = RegExp(r'ro\.build\.version\.sdk=(\d+)').firstMatch(s);
      if (m != null) return int.parse(m.group(1)!);
    } catch (_) {}
    return 34; // Défaut : Android 14
  }

  static void _showSizeWarning(BuildContext context, String name, int size, int max) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('ZIP "$name" ignoré : ${(size/1024/1024).toStringAsFixed(1)}Mo > ${(max/1024/1024).toStringAsFixed(0)}Mo'),
      backgroundColor: Colors.orange,
      duration: const Duration(seconds: 4),
    ));
  }
}
