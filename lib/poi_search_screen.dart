import 'package:flutter/material.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'gpx_track.dart';
import 'nominatim_helper.dart';
import 'place_search_screen.dart';
import 'overpass_screen.dart';
import 'html_poi_screen.dart';
import 'blog_poi_screen.dart';
import 'core/services/poi_import_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// poi_search_screen.dart
//
// Point d'entrée UNIQUE pour "trouver/importer des POI", quelle que soit la
// source. Avant la refonte, l'utilisateur devait choisir entre 4 boutons
// dispersés dans une grille 2×2 (Rechercher un lieu / POI OSM / Coller HTML
// / Analyser un blog), chacun ouvrant un écran indépendant avec son propre
// comportement d'import (voir MIGRATION_NOTES.md pour le détail des
// incohérences que ça produisait).
//
// Ce hub ne réécrit PAS les 4 écrans sources (trop volumineux et risqué à
// fusionner en profondeur sans compilateur disponible) : il centralise le
// point d'entrée et harmonise ce qui se passe APRÈS le choix de la source —
// import dans les couches/dossiers, message de confirmation — via
// PoiImportService, déjà utilisé en interne par ces écrans.
//
// Prochaine étape possible (voir MIGRATION_NOTES.md) : fusionner le contenu
// des 4 écrans dans des onglets d'un seul Scaffold, une fois un
// environnement de build disponible pour sécuriser la fusion.
// ─────────────────────────────────────────────────────────────────────────────

class PoiSearchScreen extends StatefulWidget {
  final List<PoiLayer> rootLayers;
  final List<PoiFolder> folders;
  final List<GpxTrack> tracks;
  final BoundingBox? hintBbox;
  final VoidCallback onImported;

  const PoiSearchScreen({
    super.key,
    required this.rootLayers,
    required this.folders,
    required this.tracks,
    required this.onImported,
    this.hintBbox,
  });

  @override
  State<PoiSearchScreen> createState() => _PoiSearchScreenState();
}

/// Onglets affichés inline dans le hub (fusion réelle, un seul écran, pas de
/// navigation) — limités à "Lieu" et "OSM/Overpass" : deux écrans homogènes
/// (recherche → liste → sélection → retour d'une couche), à faible risque à
/// combiner. "HTML → IA" et "Analyser un blog" restent des destinations
/// poussées depuis la liste ci-dessous : ce sont des pipelines plus complexes
/// (import direct, réglages IA, onglets internes) — les fusionner en
/// profondeur sans environnement de build pour valider la fusion serait trop
/// risqué de régression pour le gain ergonomique obtenu (voir
/// MIGRATION_NOTES.md).
class _PoiSearchScreenState extends State<PoiSearchScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController =
      TabController(length: 2, vsync: this);

  Future<void> _openHtmlAi() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => HtmlPoiScreen(
        rootLayers: widget.rootLayers,
        folders: widget.folders,
        tracks: widget.tracks,
        onImported: widget.onImported,
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _openBlogAi() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => BlogPoiScreen(
        rootLayers: widget.rootLayers,
        folders: widget.folders,
        tracks: widget.tracks,
        onImported: widget.onImported,
      ),
    ));
    if (mounted) setState(() {});
  }

  /// Comportement d'import commun aux sources "Lieu"/"OSM", qui retournent
  /// une couche via `Navigator.pop` (interne aux écrans embarqués).
  void _handleReturnedLayer(PoiLayer? layer, {required String successNoun}) {
    if (layer == null || !mounted) return;
    PoiImportService.fileInto(
      layer: layer, rootLayers: widget.rootLayers, folders: widget.folders,
    );
    widget.onImported();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${layer.points.length} $successNoun ajouté(s) — "${layer.label}"'),
      backgroundColor: Colors.green,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rechercher / importer des POI'),
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.amber,
          tabs: const [
            Tab(icon: Icon(Icons.location_searching, size: 18), text: 'Lieu'),
            Tab(icon: Icon(Icons.explore, size: 18), text: 'OSM / Overpass'),
          ],
        ),
      ),
      body: Column(children: [
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              // Onglet "Lieu" — PlaceSearchScreen embarqué (mode inline,
              // retourne sa sélection via un callback plutôt qu'un pop de
              // route puisqu'il n'est plus poussé séparément).
              PlaceSearchScreen(
                embedded: true,
                onResult: (layer) => _handleReturnedLayer(layer, successNoun: 'lieu(x)'),
              ),
              // Onglet "OSM / Overpass" — OverpassScreen embarqué, idem.
              OverpassScreen(
                hintBbox: widget.hintBbox,
                embedded: true,
                onResult: (layer) => _handleReturnedLayer(layer, successNoun: 'POI'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Sources IA — restent des destinations dédiées (voir note ci-dessus)
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: _openHtmlAi,
              icon: const Icon(Icons.auto_awesome, size: 16, color: Colors.purple),
              label: const Text('Coller une page web → IA', style: TextStyle(fontSize: 11)),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              onPressed: _openBlogAi,
              icon: const Icon(Icons.travel_explore, size: 16, color: Colors.deepOrange),
              label: const Text('Analyser un blog', style: TextStyle(fontSize: 11)),
            )),
          ]),
        ),
      ]),
    );
  }
}
