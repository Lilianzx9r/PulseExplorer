// ─────────────────────────────────────────────────────────────────────────────
// library_folder.dart
//
// Modèle de dossier GÉNÉRIQUE, destiné à remplacer à terme le système de
// dossiers qui n'existait avant la refonte que pour les POI (poi_folder.dart)
// et pas pour les traces GPX.
//
// LibraryFolder<T> porte la structure commune (id, label, visible, expanded)
// et délègue la sérialisation de son contenu à l'appelant via toJsonItem /
// fromJsonItem, pour rester agnostique du type d'item stocké (POI, GPX, ou
// demain autre chose).
//
// Étape de migration : poi_folder.dart (PoiFolder) reste inchangé pour ne
// pas casser l'existant (poi_folder_manager.dart, session_store.dart,
// layers_panel.dart en dépendent). GpxFolder, ci-dessous, suit exactement
// le même schéma pour les traces GPX — jusqu'ici absent de l'app. Voir
// MIGRATION_NOTES.md pour le plan de bascule complet de PoiFolder vers
// LibraryFolder<PoiLayer>.
// ─────────────────────────────────────────────────────────────────────────────

abstract class LibraryFolder<T> {
  String label;
  final String id;
  bool visible;
  bool expanded;
  List<T> items;

  LibraryFolder({
    required this.label,
    required this.items,
    this.visible = true,
    this.expanded = true,
    String? id,
  }) : id = id ?? DateTime.now().microsecondsSinceEpoch.toString();

  Map<String, dynamic> toJson(Map<String, dynamic> Function(T) itemToJson) => {
        'id': id,
        'label': label,
        'visible': visible,
        'expanded': expanded,
        'items': items.map(itemToJson).toList(),
      };
}

/// Dossier de traces GPX — pendant de PoiFolder pour les GPX.
/// Permet de regrouper plusieurs traces (ex: "Road trip Pyrénées 2026")
/// exactement comme un dossier POI regroupe plusieurs couches de POI.
class GpxFolder {
  String label;
  final String id;
  bool visible;
  bool expanded;

  /// Références aux traces GPX du dossier, par identifiant de trace
  /// (GpxTrack.fileName). On ne stocke pas les GpxTrack eux-mêmes ici pour
  /// éviter la duplication avec la sérialisation déjà gérée par
  /// SessionStore.serializeTracks/deserializeTracks (voir session_store.dart)
  /// — un dossier GPX est une simple organisation logique par-dessus les
  /// traces déjà chargées dans la session.
  List<String> trackFileNames;

  GpxFolder({
    required this.label,
    List<String>? trackFileNames,
    this.visible = true,
    this.expanded = true,
    String? id,
  })  : trackFileNames = trackFileNames ?? [],
        id = id ?? DateTime.now().microsecondsSinceEpoch.toString();

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'visible': visible,
        'expanded': expanded,
        'trackFileNames': trackFileNames,
      };

  factory GpxFolder.fromJson(Map<String, dynamic> j) => GpxFolder(
        id: j['id'] ?? '',
        label: j['label'] ?? 'Dossier',
        visible: j['visible'] ?? true,
        expanded: j['expanded'] ?? true,
        trackFileNames:
            (j['trackFileNames'] as List? ?? []).map((e) => e.toString()).toList(),
      );
}

/// Bibliothèque mixte : un même dossier logique (ex: un voyage) peut
/// contenir à la fois des dossiers de POI et des dossiers de GPX.
/// Utilisée par le futur panneau latéral unifié (cf. maquette "Nouveau
/// parcours" fournie par l'utilisateur).
class TripLibraryItem {
  final String label;
  final String? poiFolderId;
  final String? gpxFolderId;

  const TripLibraryItem({required this.label, this.poiFolderId, this.gpxFolderId});
}
