import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'overpass_poi_service.dart';
import 'poi_layer.dart';
import 'poi_detail_screen.dart';
import 'poi_natural_query.dart';
import 'poi_search_filters.dart';
import 'agents/poi_keyword_ai_resolver.dart';

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
  final TextEditingController _nameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCategoryPrefs();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
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

  List<OverpassPoiResult> _results        = [];
  bool                    _loading        = false;
  String?                 _error;
  bool                    _showFilters    = false;
  bool                    _collapsed      = false; // replie tout le panneau (hors barre de contrôle)
  bool                    _sortByDistance = true;  // tri par proximité au centre de la carte
  PoiSearchRadius         _radius         = PoiSearchRadius.zoneVisible;
  PoiSearchFilters        _filters        = const PoiSearchFilters();
  final Set<int>          _added          = {}; // index déjà ajouté

  // ── Recherche ─────────────────────────────────────────────────────────────
  Future<void> _search() async {
    final cam = widget.mapController.camera;
    final bounds = cam.visibleBounds;
    final nameQuery = _nameCtrl.text.trim();
    final radiusMeters = _radius.meters;
    // Un rayon fixe a besoin d'un point central : on utilise le centre de la
    // carte, et dans ce cas le tri par distance est implicite (le rayon n'a
    // de sens qu'avec une origine connue).
    final origin = (_sortByDistance || radiusMeters != null) ? cam.center : null;

    setState(() { _loading = true; _error = null; _results = []; _added.clear(); });

    try {
      List<OverpassPoiResult> r;

      if (nameQuery.isEmpty) {
        // Pas de saisie → recherche classique par catégories cochées.
        r = await OverpassPoiService.search(
          minLat: bounds.south, maxLat: bounds.north,
          minLon: bounds.west,  maxLon: bounds.east,
          categories: widget.categories,
          limit: 300,
          sortOrigin: origin,
          radiusMeters: radiusMeters,
          filters: _filters,
        );
      } else {
        // 1) Dictionnaire local (instantané, hors-ligne) : "restaurant
        // italien", "boulangerie", "essence"... → catégories connues.
        final parsed = PoiNaturalQueryParser.parse(nameQuery);
        var categoryIds = parsed.categoryIds;
        var cuisine = parsed.cuisineFilter;

        // 2) Si le dictionnaire ne reconnaît rien, tente une interprétation
        // IA (seulement si un provider est configuré et joignable — sinon
        // repli silencieux et rapide grâce au timeout court).
        if (categoryIds.isEmpty) {
          final aiIds = await PoiKeywordAiResolver.resolveCategoryIds(nameQuery);
          if (aiIds != null && aiIds.isNotEmpty) categoryIds = aiIds;
        }

        if (categoryIds.isNotEmpty) {
          final matched = kPoiCategories
              .where((c) => categoryIds.contains(c.id))
              .map((c) => PoiCategory(
                    id: c.id, label: c.label, emoji: c.emoji,
                    overpassFilter: c.overpassFilter, color: c.color,
                    selected: true,
                  ))
              .toList();
          r = await OverpassPoiService.search(
            minLat: bounds.south, maxLat: bounds.north,
            minLon: bounds.west,  maxLon: bounds.east,
            categories: matched,
            limit: 300,
            sortOrigin: origin,
            cuisineFilter: cuisine,
            radiusMeters: radiusMeters,
            filters: _filters,
          );
        } else {
          // 3) Rien reconnu : recherche brute par nom (comportement
          // précédent, toujours utile pour un nom propre — "Le Bistrot").
          r = await OverpassPoiService.searchByName(
            minLat: bounds.south, maxLat: bounds.north,
            minLon: bounds.west,  maxLon: bounds.east,
            query: nameQuery,
            limit: 100,
            sortOrigin: origin,
            radiusMeters: radiusMeters,
            filters: _filters,
          );
        }
      }

      setState(() => _results = r);
      widget.onResultsChanged(_results);
      if (r.isEmpty) setState(() => _error = 'Aucun POI trouvé dans cette zone');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
    }
  }

  // ── Résout la catégorie d'un résultat, y compris "Autre" (recherche par
  // nom) qui ne fait pas partie de widget.categories.
  PoiCategory _categoryFor(String categoryId) {
    if (categoryId == OverpassPoiService.kOtherCategory.id) {
      return OverpassPoiService.kOtherCategory;
    }
    return widget.categories.firstWhere(
        (c) => c.id == categoryId, orElse: () => widget.categories.first);
  }

  // ── Ajout d'un POI au double-tap ──────────────────────────────────────────
  Future<void> _addPoi(int idx) async {
    final r     = _results[idx];
    final color = _categoryFor(r.categoryId).color;

    // Optionnel : ouvrir l'édition avant d'ajouter
    final poi = r.toPoiPoint();
    final edited = await Navigator.push<PoiPoint>(context,
      MaterialPageRoute(builder: (_) =>
          PoiDetailScreen(poi: poi, color: color)));

    final finalPoi = edited ?? poi;

    // Chercher ou créer une couche pour cette catégorie
    final cat      = _categoryFor(r.categoryId);
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
          // Tri par proximité (centre de la carte)
          IconButton(
            icon: Icon(
                _sortByDistance ? Icons.social_distance : Icons.sort_by_alpha,
                color: Colors.white, size: 20),
            tooltip: _sortByDistance
                ? 'Trié par proximité (appuyer pour désactiver)'
                : 'Ordre par défaut (appuyer pour trier par proximité)',
            onPressed: () {
              setState(() => _sortByDistance = !_sortByDistance);
              if (_results.isNotEmpty) _search();
            },
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
            label: Text(_radius.meters == null ? 'Zone visible' : _radius.label,
                style: const TextStyle(fontSize: 12)),
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

      // ── Recherche par nom ────────────────────────────────────────────────
      if (!_collapsed)
        Container(
          color: Colors.teal.shade50,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: TextField(
            controller: _nameCtrl,
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Rechercher par nom (ex : Carrefour, Le Bistrot…)',
              hintStyle: const TextStyle(fontSize: 11),
              prefixIcon: const Icon(Icons.text_fields, size: 16),
              suffixIcon: _nameCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        setState(() => _nameCtrl.clear());
                        _search();
                      },
                    ),
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none),
            ),
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}), // pour afficher/masquer le bouton clear
            onSubmitted: (_) => _search(),
          ),
        ),

      // ── Filtres catégories + rayon + filtres avancés ───────────────────────
      if (!_collapsed && _showFilters)
        Container(
          color: Colors.teal.shade50,
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(
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
            const Divider(height: 16),
            const Text('Rayon de recherche',
                style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: PoiSearchRadius.options.map((opt) => ChoiceChip(
                label: Text(opt.label, style: const TextStyle(fontSize: 11)),
                selected: _radius.label == opt.label,
                onSelected: (_) => setState(() => _radius = opt),
              )).toList(),
            ),
            const SizedBox(height: 8),
            const Text('Filtres avancés',
                style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6, runSpacing: 6,
              children: [
                FilterChip(
                  label: const Text('🕐 Ouvert maintenant', style: TextStyle(fontSize: 11)),
                  selected: _filters.openNowOnly,
                  onSelected: (v) => setState(() => _filters = _filters.copyWith(openNowOnly: v)),
                ),
                FilterChip(
                  label: const Text('🚐 Camping-car', style: TextStyle(fontSize: 11)),
                  selected: _filters.motorhomeOnly,
                  onSelected: (v) => setState(() => _filters = _filters.copyWith(motorhomeOnly: v)),
                ),
                FilterChip(
                  label: const Text('🅿️ Avec parking', style: TextStyle(fontSize: 11)),
                  selected: _filters.parkingOnly,
                  onSelected: (v) => setState(() => _filters = _filters.copyWith(parkingOnly: v)),
                ),
                FilterChip(
                  label: const Text('🆓 Gratuit', style: TextStyle(fontSize: 11)),
                  selected: _filters.freeOnly,
                  onSelected: (v) => setState(() => _filters = _filters.copyWith(freeOnly: v)),
                ),
              ],
            ),
          ]),
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
              final cat     = _categoryFor(r.categoryId);
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
                  subtitle: Text(
                      r.distanceLabel != null
                          ? '${cat.label} · ${r.distanceLabel}'
                          : cat.label,
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
              'Naviguez sur la carte, puis appuyez sur\n"Zone visible" pour rechercher les POI\n(par catégories ou par nom).',
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
