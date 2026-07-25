import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'gpx_parser.dart';

class GpxPicker {
  /// Sélectionne et parse un fichier GPX
  static Future<({GpxData data, String fileName})?> pick(BuildContext context) async {
    final granted = await _requestPermissions();
    if (!granted) {
      if (context.mounted) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Permission refusée'),
            content: const Text(
              'L\'accès aux fichiers est nécessaire pour importer un GPX.\n\n'
              'Allez dans Paramètres → Applications → PulseGpx → Autorisations '
              'et activez "Fichiers et médias".',
            ),
            actions: [
              TextButton(
                onPressed: () { Navigator.pop(context); openAppSettings(); },
                child: const Text('Ouvrir les paramètres'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Annuler'),
              ),
            ],
          ),
        );
      }
      return null;
    }

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
    } catch (e) {
      throw Exception('Impossible d\'ouvrir le sélecteur de fichier : $e');
    }

    if (result == null || result.files.isEmpty) return null;

    final file = result.files.first;
    final name = file.name;

    if (!name.toLowerCase().endsWith('.gpx')) {
      throw Exception('Le fichier "$name" n\'est pas un fichier GPX (.gpx)');
    }

    String content;
    if (file.bytes != null) {
      content = String.fromCharCodes(file.bytes!);
    } else if (file.path != null) {
      content = await File(file.path!).readAsString();
    } else {
      throw Exception('Impossible de lire le fichier GPX');
    }

    final data = GpxParser.parse(content);
    return (data: data, fileName: name);
  }

  /// Sélectionne une image PNG/JPG depuis la galerie
  static Future<Uint8List?> pickImage(BuildContext context) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
    } catch (e) {
      throw Exception('Impossible d\'ouvrir la galerie : $e');
    }
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    if (file.bytes != null) return file.bytes!;
    if (file.path != null) return await File(file.path!).readAsBytes();
    throw Exception('Impossible de lire l\'image');
  }

  static Future<bool> _requestPermissions() async {
    if (Platform.isAndroid) {
      final sdkInt = await _getAndroidSdkVersion();
      if (sdkInt < 33) {
        final status = await Permission.storage.request();
        return status.isGranted || status.isLimited;
      }
      return true;
    }
    return true;
  }

  static Future<int> _getAndroidSdkVersion() async {
    try {
      final result = await File('/system/build.prop').readAsString();
      final match = RegExp(r'ro\.build\.version\.sdk=(\d+)').firstMatch(result);
      if (match != null) return int.parse(match.group(1)!);
    } catch (_) {}
    return 33;
  }
}
