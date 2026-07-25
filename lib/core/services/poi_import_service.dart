import 'package:flutter/material.dart';
import '../../poi_layer.dart';
import '../../poi_folder.dart';

// ─────────────────────────────────────────────────────────────────────────────
// poi_import_service.dart
//
// Logique UNIQUE "créer une couche POI à partir d'une sélection, la ranger
// dans un dossier (existant ou nouveau), notifier l'appelant". Avant la
// refonte, cette même logique était réécrite 3 fois avec des variantes
// mineures et incohérentes :
//   - html_poi_screen.dart  : couche ajoutée directement à la racine, jamais
//     dans un dossier, nom de couche daté par jour ("IA — JJ/MM")
//   - blog_poi_service.dart : couche rangée dans un dossier "Blog — JJ/MM"
//     retrouvé ou créé automatiquement
//   - overpass_screen.dart  : ni couche ni dossier créés ici — la couche est
//     retournée à l'appelant (main.dart) qui l'ajoute lui-même à la racine
//
// Cette dispersion faisait qu'un POI importé depuis Overpass n'atterrissait
// jamais dans un dossier alors qu'un POI importé depuis un blog si, sans
// raison fonctionnelle — pur hasard d'implémentation. PoiImportService
// uniformise ce comportement : toute source PEUT ranger dans un dossier daté
// si on le souhaite, via le même appel.
// ─────────────────────────────────────────────────────────────────────────────

class PoiImportService {
  PoiImportService._();

  /// Construit une couche POI à partir d'une sélection.
  static PoiLayer buildLayer(
    List<PoiPoint> selected, {
    required String label,
    Color color = Colors.deepOrange,
  }) {
    return PoiLayer(label: label, points: selected, color: color);
  }

  /// Range [layer] dans le dossier nommé [folderLabel] (recherché par nom,
  /// insensible à la casse ; créé s'il n'existe pas), ou l'ajoute à la racine
  /// ([rootLayers]) si [folderLabel] est null.
  static void fileInto({
    required PoiLayer layer,
    required List<PoiLayer> rootLayers,
    required List<PoiFolder> folders,
    String? folderLabel,
  }) {
    if (folderLabel == null) {
      rootLayers.add(layer);
      return;
    }
    PoiFolder? folder;
    for (final f in folders) {
      if (f.label.trim().toLowerCase() == folderLabel.toLowerCase()) {
        folder = f;
        break;
      }
    }
    if (folder == null) {
      folder = PoiFolder(label: folderLabel, layers: []);
      folders.add(folder);
    }
    folder.layers.add(layer);
  }

  /// Nom de dossier "daté" standard (ex: "Blog — 10/07"), pour que toutes
  /// les sources d'import puissent proposer le même rangement automatique
  /// par jour si elles le souhaitent.
  static String datedFolderLabel(String sourcePrefix, [DateTime? now]) {
    final n = now ?? DateTime.now();
    return '$sourcePrefix — ${n.day.toString().padLeft(2, "0")}/'
        '${n.month.toString().padLeft(2, "0")}';
  }
}
