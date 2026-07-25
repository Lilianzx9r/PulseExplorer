import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'overpass_poi_service.dart';
import 'poi_layer.dart';
import 'poi_detail_screen.dart';

/// Overlay de POI touristiques Overpass affiché sur la carte OSM.
/// Double-tap sur un résultat → l'ajoute dans une couche POI.
class TouristPoiOverlay extends StatefulWidget {
  final MapController                          mapController;
  final List<PoiLayer>                         poiLayers;
  final List<PoiCategory>                      categories;
  final void Function(PoiLayer)                onLayerAdded;
  final VoidCallback                           onClose;
  final void Function(List<OverpassPoiResult>) onResultsChanged;

  const TouristPoiOverlay({
    super.key,
    required this.mapController,
    required this.poiLayers,
    required this.categories,
    required this.onLayerAdded,
    required this.onClose,
    required this.onResultsChanged,
  });

  @override
  State<TouristPoiOverlay> createState() => _TouristPoiOverlayState();
}

class _TouristPoiOverlayState extends State<TouristPoiOverlay> {

  @override
  void initState() {
    super.initState();
    _loadCategoryPrefs();
  }

  Future<void> _loadCategoryPrefs() async {
    try {
      final dir  = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/poi_categories.json');
      if (!await file.exists()) return;
      final saved = json.decode(await file.readAsString()) as List;
      final ids   = saved.cast<String>().toSet();
      if (mounted) setState(() {
        for (final c in widget.categories) {
          c.selected = ids.contains(c.id);
        }
      });
    } catch (_) {}
  }

  Future<void> _saveCategoryPrefs() async {
    try {
      final dir  = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/poi_categories.json');
      final ids  = widget.categories.where((c) => c.selected).map((c) => c.id).toList();
      await file.writeAsString(json.encode(ids));
    } catch (_) {}
  }

  List<OverpassPoiResult> _results     = [];
  bool                    _loading     = false;
  String?                 _error;
  bool                    _showFilters = false;
  bool                    _collapsed   = false; // replie tout le panneau (hors barre de contrôle)
  final Set<int>          _added       = {}; // index déjà ajouté

  // ── Recherche ─────────────────────────────────────────────────────────────
  Future<void> _search() async {
    final cam = widget.mapController.camera;
    final bounds = cam.visibleBounds;

    setState(() { _loading = true; _error = null; _results = []; _added.clear(); });

    try {
      final r = await OverpassPoiService.search(
        minLat: bounds.south, maxLat: bounds.north,
        minLon: bounds.west,  maxLon: bounds.east,
        categories: widget.categories,
        limit: 300,
      );
      setState(() => _results = r);
      widget.onResultsChanged(_results);
      if (r.isEmpty) setState(() => _error = 'Aucun POI trouvé dans cette zone');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
    }
  }

  // ── Ajout d'un POI au double-tap ──────────────────────────────────────────
  Future<void> _addPoi(int idx) async {
    final r     = _results[idx];
    final color = widget.categories
        .firstWhere((c) => c.id == r.categoryId,
            orElse: () => widget.categories.first)
        .color;

    // Optionnel : ouvrir l'édition avant d'ajouter
    final poi = r.toPoiPoint();
    final edited = await Navigator.push<PoiPoint>(context,
      MaterialPageRoute(builder: (_) =>
          PoiDetailScreen(poi: poi, color: color)));

    final finalPoi = edited ?? poi;

    // Chercher ou créer une couche pour cette catégorie
    final cat      = widget.categories.firstWhere(
        (c) => c.id == r.categoryId, orElse: () => widget.categories.first);
    final layerLbl = '${cat.emoji} ${cat.label}';
    PoiLayer? layer = widget.poiLayers
        .where((l) => l.label == layerLbl).firstOrNull;

    if (layer == null) {
      layer = PoiLayer(
        label:  layerLbl,
        points: [],
        color:  color,
      );
      widget.poiLayers.add(layer);
      widget.onLayerAdded(layer);
    }

    layer.points.add(finalPoi);
    setState(() => _added.add(idx));
    widget.onResultsChanged(_results);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${finalPoi.name} ajouté dans "$layerLbl"'),
        backgroundColor: color,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    // mainAxisSize.min : le panneau s'adapte à son contenu réel plutôt que
    // d'occuper systématiquement toute la hauteur max allouée par le
    // parent (420px) — c'est ce qui empêchait la carte de s'agrandir même
    // quand le panneau n'avait pas besoin de tout cet espace.
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // ── Barre de contrôle ─────────────────────────────────────────────────
      Container(
        color: Colors.teal.shade700,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(children: [
          const Icon(Icons.travel_explore, color: Colors.white, size: 18),
          const SizedBox(width: 6),
          const Expanded(child: Text('POI touristiques',
              style: TextStyle(color: Colors.white,
                  fontWeight: FontWeight.bold, fontSize: 13))),
          // Plier/déplier tout le panneau — pour agrandir la vue de la
          // carte sans perdre la recherche en cours (résultats conservés).
          IconButton(
            icon: Icon(_collapsed ? Icons.expand_less : Icons.expand_more,
                color: Colors.white, size: 20),
            tooltip: _collapsed ? 'Déplier' : 'Replier (agrandir la carte)',
            onPressed: () => setState(() => _collapsed = !_collapsed),
            padding: EdgeInsets.zero, constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 4),
          // Filtres
          IconButton(
            icon: Icon(_showFilters ? Icons.filter_list_off : Icons.filter_list,
                color: Colors.white, size: 20),
            tooltip: 'Filtres catégories',
            onPressed: () => setState(() => _showFilters = !_showFilters),
            padding: EdgeInsets.zero, constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
          // Rechercher
          FilledButton.icon(
            onPressed: _loading ? null : _search,
            icon: _loading
                ? const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2,
                        color: Colors.white))
                : const Icon(Icons.search, size: 16),
            label: const Text('Zone visible',
                style: TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.teal.shade900,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 20),
            onPressed: widget.onClose,
            padding: EdgeInsets.zero, constraints: const BoxConstraints(),
          ),
        ]),
      ),

      // ── Filtres catégories ────────────────────────────────────────────────
      if (!_collapsed && _showFilters)
        Container(
          color: Colors.teal.shade50,
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 6, runSpacing: 6,
            children: widget.categories.map((cat) => FilterChip(
              label: Text('${cat.emoji} ${cat.label}',
                  style: const TextStyle(fontSize: 11)),
              selected: cat.selected,
              selectedColor: Color(cat.color.value).withOpacity(0.25),
              checkmarkColor: cat.color,
              onSelected: (v) {
                setState(() => cat.selected = v);
                _saveCategoryPrefs();
              },
            )).toList(),
          ),
        ),

      // ── Erreur / vide ─────────────────────────────────────────────────────
      if (!_collapsed && _error != null)
        Container(
          padding: const EdgeInsets.all(12),
          color: Colors.orange.shade50,
          child: Row(children: [
            const Icon(Icons.warning, color: Colors.orange, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(_error!,
                style: const TextStyle(fontSize: 12))),
          ]),
        ),

      // ── Résultats (liste + marqueurs sur carte via parent) ────────────────
      if (!_collapsed && _results.isNotEmpty)
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _results.length,
            itemBuilder: (ctx, i) {
              final r       = _results[i];
              final added   = _added.contains(i);
              final cat     = widget.categories
                  .firstWhere((c) => c.id == r.categoryId,
                      orElse: () => widget.categories.first);
              return GestureDetector(
                onDoubleTap: added ? null : () => _addPoi(i),
                child: ListTile(
                  dense: true,
                  leading: Text(r.emoji,
                      style: const TextStyle(fontSize: 20)),
                  title: Text(r.name,
                      style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: added ? Colors.grey : Colors.black)),
                  subtitle: Text(cat.label,
                      style: TextStyle(fontSize: 10, color: cat.color)),
                  trailing: added
                      ? const Icon(Icons.check_circle,
                          color: Colors.green, size: 18)
                      : const Icon(Icons.touch_app,
                          color: Colors.teal, size: 16),
                  onTap: () => widget.mapController.move(
                    LatLng(r.lat, r.lon),
                    widget.mapController.camera.zoom,
                  ),
                ),
              );
            },
          ),
        ),

      // Hint si aucune recherche
      if (!_collapsed && _results.isEmpty && !_loading && _error == null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.travel_explore, size: 36, color: Colors.teal.shade200),
            const SizedBox(height: 8),
            const Text(
              'Naviguez sur la carte, puis appuyez sur\n"Zone visible" pour rechercher les POI.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 6),
            const Text('Double-tap sur un résultat pour l\'ajouter.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.teal)),
          ]),
        ),
    ]);
  }


}
