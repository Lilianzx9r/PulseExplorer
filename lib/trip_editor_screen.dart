import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'route_trip.dart';
import 'navigation_service.dart';
import 'core/services/map_camera_utils.dart';
import 'route_options.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'core/services/vector_map_layer.dart';
import 'place_search_field.dart';
import 'overpass_poi_service.dart';
import 'gpx_track.dart';
import 'gpx_parser.dart';
import 'elevation_api_service.dart';
import 'elevation_3d_screen.dart';
import 'route_elevation_profile.dart';

// ─────────────────────────────────────────────────────────────────────────────
// trip_editor_screen.dart
//
// Éditeur d'itinéraire multi-étapes (façon 68°) : ajout/réorganisation
// /suppression d'étapes, affichage temps & distance cumulés et entre étapes,
// 4 profils de route en un clic.
// ─────────────────────────────────────────────────────────────────────────────

/// Les 4 types de route façon 68° : autoroutes / sans autoroutes / sinueux / petites routes
enum TripRouteStyle { highways, noHighways, scenic, smallRoads }

extension TripRouteStyleX on TripRouteStyle {
  String get label => switch (this) {
    TripRouteStyle.highways    => 'Autoroutes',
    TripRouteStyle.noHighways  => 'Sans autoroute',
    TripRouteStyle.scenic      => 'Sinueux',
    TripRouteStyle.smallRoads  => 'Petites routes',
  };
  String get emoji => switch (this) {
    TripRouteStyle.highways    => '🛣️',
    TripRouteStyle.noHighways  => '🚗',
    TripRouteStyle.scenic      => '🏍️',
    TripRouteStyle.smallRoads  => '🛤️',
  };
  RouteOptions toOptions() => switch (this) {
    TripRouteStyle.highways    => const RouteOptions(),
    TripRouteStyle.noHighways  => const RouteOptions(avoidHighways: true),
    TripRouteStyle.scenic      => const RouteOptions(avoidHighways: true, preferScenic: true),
    TripRouteStyle.smallRoads  => const RouteOptions(avoidHighways: true, preferScenic: true),
  };
}

class TripEditorScreen extends StatefulWidget {
  final RouteTrip? initialTrip;
  final List<PoiLayer> rootLayers;
  final List<PoiFolder> folders;
  final List<GpxTrack> gpxTracks; // traces GPX utilisables comme étapes
  final LatLng? userPosition;
  final String profile;

  const TripEditorScreen({
    super.key, this.initialTrip,
    required this.rootLayers, required this.folders,
    this.gpxTracks = const [],
    this.userPosition, this.profile = 'driving',
  });

  @override
  State<TripEditorScreen> createState() => _TripEditorScreenState();

  /// Expose le répertoire des itinéraires sauvegardés — utilisé pour un
  /// accès rapide depuis la carte principale sans ouvrir l'éditeur complet.
  static Future<Directory> tripsDirectory() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/PulseGpx/trips');
    await dir.create(recursive: true);
    return dir;
  }
}

class _TripEditorScreenState extends State<TripEditorScreen> {
  late final MapController _mc;
  late RouteTrip _trip;
  TripRouteStyle _routeStyle = TripRouteStyle.noHighways;
  String _profile = 'driving';

  // Distances/durées calculées entre chaque paire d'étapes consécutives
  final Map<int, NavRoute?> _legRoutes = {};
  // ── Profil altimétrique 2D incrusté sur la carte de l'itinéraire ──────────
  bool _showRouteProfile = false;
  bool _stepsExpanded = true; // liste des étapes pliable (ne pas masquer la carte)
  List<GpxPoint>? _routeProfilePoints;
  bool _routeProfileLoading = false;
  LatLng? _routeProfileCursor;
  bool _calculating = false;
  String? _activeCategory;
  List<OverpassPoiResult> _quickPoiResults = [];

  @override
  void initState() {
    super.initState();
    _mc = MapController();
    _trip = widget.initialTrip ?? RouteTrip();
    _profile = widget.profile;
    if (_trip.isNotEmpty) _recalculateLegs();
  }

  @override
  void dispose() { _mc.dispose(); super.dispose(); }

  Future<void> _recalculateLegs() async {
    if (_trip.length < 2) { setState(() => _legRoutes.clear()); return; }
    _invalidateRouteProfile(); // l'itinéraire change → le profil en cache est périmé
    setState(() => _calculating = true);
    final options = _routeStyle.toOptions().copyWith(
      avoidTolls: _routeStyle == TripRouteStyle.noHighways ||
                  _routeStyle == TripRouteStyle.scenic ||
                  _routeStyle == TripRouteStyle.smallRoads,
    );
    for (int i = 0; i < _trip.length - 1; i++) {
      // smartRoute (et non osrmRoute directement) : cache local → graphe
      // hors-ligne → OSRM → repli ligne droite. Avec osrmRoute seul, un
      // simple souci réseau/serveur public OSRM rendait le tronçon
      // silencieusement `null` — la carte ET le profil altimétrique
      // "sautaient" ce tronçon (jonction rectiligne entre segments non
      // adjacents), et si tous les tronçons échouaient, le bouton profil
      // semblait ne rien faire ("Calculez d'abord un itinéraire").
      // smartRoute ne renvoie jamais null : au pire une ligne droite, mais
      // au moins un tronçon cohérent et visible.
      final route = await NavigationService.smartRoute(
        _trip.steps[i].position, _trip.steps[i + 1].position,
        profile: _profile, targetName: _trip.steps[i + 1].name, options: options);
      if (mounted) setState(() => _legRoutes[i] = route);
    }
    if (mounted) setState(() => _calculating = false);
    _fitAll();

    // Avertir si un ou plusieurs tronçons n'ont pas pu être calculés par un
    // vrai service de routage (réseau indisponible, serveur OSRM injoignable
    // depuis ce poste...) : le tracé ET le profil altimétrique de ce tronçon
    // seront alors une ligne droite entre les deux étapes, pas la vraie route.
    final straightCount = _legRoutes.values
        .where((r) => r != null && r.engine == RouteEngine.straightLine)
        .length;
    if (mounted && straightCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(straightCount == 1
            ? "1 tronçon n'a pas pu être calculé (réseau) — ligne droite affichée en repli"
            : "$straightCount tronçons n'ont pas pu être calculés (réseau) — lignes droites affichées en repli"),
        backgroundColor: Colors.orange.shade800,
        duration: const Duration(seconds: 4),
      ));
    }
  }

  /// Concatène la géométrie de tous les tronçons calculés, dans l'ordre.
  /// Partagé entre le profil 3D plein écran et le ruban 2D sur la carte.
  List<LatLng> _fullRouteGeometry() {
    final geometry = <LatLng>[];
    for (int i = 0; i < _trip.length - 1; i++) {
      final leg = _legRoutes[i];
      if (leg != null) geometry.addAll(leg.geometry);
    }
    return geometry;
  }

  /// Affiche/masque le ruban de profil altimétrique 2D sur la carte de
  /// l'itinéraire (contrairement au profil 3D plein écran, celui-ci reste
  /// visible pendant qu'on modifie les étapes). Récupère l'altitude via API
  /// une seule fois par calcul d'itinéraire (résultat mis en cache tant que
  /// les tronçons ne changent pas).
  Future<void> _toggleRouteProfile2D() async {
    if (_showRouteProfile) {
      setState(() => _showRouteProfile = false);
      return;
    }
    if (_legRoutes.isEmpty || _legRoutes.values.every((r) => r == null)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Calculez d'abord un itinéraire (au moins 2 étapes)")));
      return;
    }
    setState(() => _showRouteProfile = true);
    if (_routeProfilePoints != null) return; // déjà en cache

    final geometry = _fullRouteGeometry();
    if (geometry.length < 2) return;
    setState(() => _routeProfileLoading = true);
    try {
      final raw = GpxData(
        trackPoints: geometry.map((p) => GpxPoint(lat: p.latitude, lon: p.longitude)).toList(),
        waypoints: const [], name: 'Itinéraire',
      );
      final enriched = await ElevationApiService.enrichTrackElevation(raw);
      if (mounted) setState(() => _routeProfilePoints = enriched.trackPoints);
    } catch (_) {
      if (mounted) setState(() => _routeProfilePoints = null);
    } finally {
      if (mounted) setState(() => _routeProfileLoading = false);
    }
  }

  /// Réinitialise le profil 2D en cache — à appeler quand l'itinéraire
  /// change (nouveau tronçon, étape déplacée...) pour ne pas afficher un
  /// profil périmé ne correspondant plus au tracé affiché.
  void _invalidateRouteProfile() {
    _routeProfilePoints = null;
    _routeProfileCursor = null;
  }

  /// Affiche le profil altimétrique 3D de l'itinéraire calculé — réutilise
  /// l'écran 3D existant (Elevation3DScreen), auparavant réservé aux traces
  /// GPX importées. La géométrie de chaque tronçon (déjà calculée dans
  /// _legRoutes) est concaténée puis enrichie en altitude via
  /// ElevationApiService (les itinéraires OSRM n'incluent pas l'altitude),
  /// exactement comme pour un GPX sans altitude.
  Future<void> _open3DProfile() async {
    if (_legRoutes.isEmpty || _legRoutes.values.every((r) => r == null)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Calculez d'abord un itinéraire (au moins 2 étapes)")));
      return;
    }
    final geometry = _fullRouteGeometry();
    if (geometry.length < 2) return;

    showDialog(context: context, barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      final rawData = GpxData(
        trackPoints: geometry
            .map((p) => GpxPoint(lat: p.latitude, lon: p.longitude))
            .toList(),
        waypoints: const [],
        name: 'Itinéraire',
      );
      final enriched = await ElevationApiService.enrichTrackElevation(rawData);
      if (!mounted) return;
      Navigator.pop(context); // fermer le loader
      final track = GpxTrack(
        fileName: 'itineraire_${DateTime.now().millisecondsSinceEpoch}',
        data: enriched, color: Colors.blue,
      );
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => Elevation3DScreen(track: track)));
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Erreur profil 3D : $e')));
    }
  }

  void _fitAll() {
    final pts = <LatLng>[
      if (widget.userPosition != null) widget.userPosition!,
      ..._trip.steps.map((s) => s.position),
    ];
    if (pts.length < 2) return;
    // safeFitBounds évite le crash flutter_map sur bounding box dégénérée
    // (ex: une seule étape saisie, ou étapes très proches) — voir
    // core/services/map_camera_utils.dart.
    safeFitBounds(_mc, pts, padding: const EdgeInsets.all(48));
  }

  double get _totalDuration {
    double total = 0;
    for (final r in _legRoutes.values) {
      if (r != null) total += r.totalDurationS;
    }
    return total;
  }

  double get _totalDistance {
    double total = 0;
    for (final r in _legRoutes.values) {
      if (r != null) total += r.totalDistanceM;
    }
    return total;
  }

  Future<void> _addStepFromSearch() async {
    final picked = await PlaceSearchDialog.show(context,
        title: 'Rechercher une étape', hint: 'Ville, adresse, lieu-dit…');
    if (picked == null) return;
    setState(() => _trip.addStep(TripStep.fromPoint(picked.name, picked.position)));
    _recalculateLegs();
  }

  Future<void> _addStepFromMap() async {
    final picked = await Navigator.push<LatLng>(context, MaterialPageRoute(
      builder: (_) => _MapPickerScreen(
        initialCenter: _mc.camera.center,
        rootLayers: widget.rootLayers,
        folders: widget.folders,
        gpxTracks: widget.gpxTracks,
      ),
    ));
    if (picked == null) return;
    final nameCtrl = TextEditingController(text: 'Étape ${_trip.length + 1}');
    final name = await showDialog<String>(context: context, builder: (_) => AlertDialog(
      title: const Text('Nom de l\'étape'),
      content: TextField(controller: nameCtrl, autofocus: true),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(context, nameCtrl.text), child: const Text('Ajouter')),
      ],
    ));
    if (name == null || name.trim().isEmpty) return;
    setState(() => _trip.addStep(TripStep.fromPoint(name.trim(), picked)));
    _recalculateLegs();
  }

  /// Ajoute une étape à la position GPS actuelle — "Ma position" comme
  /// adresse de départ possible, sans avoir à la chercher/saisir.
  Future<void> _addStepFromMyPosition() async {
    if (widget.userPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Position GPS indisponible — activez la localisation '
              'ou définissez une position manuelle depuis la carte principale')));
      return;
    }
    setState(() => _trip.addStep(
        TripStep.fromPoint('Ma position', widget.userPosition!)));
    _recalculateLegs();
  }

  /// Menu rapide au toucher d'un POI sur la carte principale — évite de
  /// passer par le sélecteur "Mes POI" quand on voit déjà le point voulu.
  void _showPoiQuickMenu(PoiPoint p) {
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF1a1a1a),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.location_on, color: Colors.white70),
          title: Text(p.name, style: const TextStyle(color: Colors.white)),
          subtitle: p.description != null
              ? Text(p.description!, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 12))
              : null,
        ),
        ListTile(
          leading: const Icon(Icons.add_location_alt, color: Colors.amber),
          title: const Text('Ajouter comme étape', style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(context);
            setState(() => _trip.addStep(TripStep.fromPoi(p)));
            _recalculateLegs();
          },
        ),
      ])),
    );
  }

  Future<void> _addStepFromPoi() async {
    final allPois = <PoiPoint>[
      ...widget.rootLayers.expand((l) => l.points),
      ...widget.folders.expand((f) => f.layers.expand((l) => l.points)),
    ];
    if (allPois.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Aucun POI enregistré')));
      return;
    }
    final selected = await showModalBottomSheet<PoiPoint>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: .6, maxChildSize: .9, expand: false,
        builder: (_, scrollCtrl) => ListView.builder(
          controller: scrollCtrl,
          itemCount: allPois.length,
          itemBuilder: (ctx, i) => ListTile(
            leading: const Icon(Icons.place),
            title: Text(allPois[i].name),
            subtitle: Text('${allPois[i].lat.toStringAsFixed(4)}, ${allPois[i].lon.toStringAsFixed(4)}'),
            onTap: () => Navigator.pop(ctx, allPois[i]),
          ),
        ),
      ),
    );
    if (selected == null) return;
    setState(() => _trip.addStep(TripStep.fromPoi(selected)));
    _recalculateLegs();
  }

  /// Ajoute une étape à partir d'un point d'une trace GPX chargée — permet
  /// d'intégrer un GPX directement dans un itinéraire de navigation, pas
  /// seulement les POI.
  Future<void> _addStepFromGpx() async {
    if (widget.gpxTracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Aucune trace GPX chargée')));
      return;
    }
    final picked = await showModalBottomSheet<({GpxTrack track, int index})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: .7, maxChildSize: .9, expand: false,
        builder: (_, scrollCtrl) => ListView(
          controller: scrollCtrl,
          children: [
            for (final track in widget.gpxTracks) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(track.displayName,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              // Points nommés (waypoints) en priorité — plus pertinents comme
              // étapes qu'un point brut de trace continue.
              for (int i = 0; i < track.data.waypoints.length; i++)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.route),
                  title: Text(track.data.waypoints[i].name ??
                      'Waypoint ${i + 1}'),
                  onTap: () => Navigator.pop(
                      context, (track: track, index: i)),
                ),
            ],
          ],
        ),
      ),
    );
    if (picked == null) return;
    final point = picked.track.data.waypoints[picked.index];
    setState(() => _trip.addStep(
        TripStep.fromGpxPoint(picked.track.fileName, point, picked.index)));
    _recalculateLegs();
  }

  void _removeStep(int index) {
    setState(() => _trip.removeAt(index));
    _legRoutes.clear();
    _recalculateLegs();
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() => _trip.reorder(oldIndex, newIndex));
    _legRoutes.clear();
    _recalculateLegs();
  }

  // ── Persistance des itinéraires ────────────────────────────────────────────
  static Future<Directory> _tripsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir  = Directory('${base.path}/PulseGpx/trips');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _saveTrip() async {
    final nameCtrl = TextEditingController(
        text: 'Itinéraire ${DateTime.now().day}/${DateTime.now().month}');
    final name = await showDialog<String>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sauvegarder l\'itinéraire'),
        content: TextField(controller: nameCtrl, autofocus: true,
          decoration: const InputDecoration(labelText: 'Nom')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, nameCtrl.text),
              child: const Text('Sauvegarder')),
        ],
      ));
    if (name == null || name.trim().isEmpty || _trip.isEmpty) return;
    final dir  = await _tripsDir();
    final slug = name.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    final file = File('${dir.path}/$slug.json');
    final data = jsonEncode({...(_trip.toJson()), 'name': name.trim()});
    await file.writeAsString(data);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ Itinéraire « ${name.trim()} » sauvegardé'),
        backgroundColor: Colors.green, duration: const Duration(seconds: 2)));
  }

  Future<void> _loadTrip() async {
    final dir = await _tripsDir();
    if (!dir.existsSync()) return;
    final files = dir.listSync().whereType<File>()
        .where((f) => f.path.endsWith('.json')).toList();
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Aucun itinéraire sauvegardé')));
      return;
    }
    // Charger les métadonnées de chaque itinéraire
    final trips = <Map<String, dynamic>>[];
    for (final f in files) {
      try {
        final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        trips.add({...data, '_file': f.path});
      } catch (_) {}
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16213e),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(padding: EdgeInsets.all(12),
          child: Text('Itinéraires sauvegardés',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15))),
        const Divider(color: Color(0xFF0f3460)),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: trips.length,
            itemBuilder: (ctx, i) {
              final t = trips[i];
              final name = t['name']?.toString() ?? 'Itinéraire';
              final steps = (t['steps'] as List?)?.length ?? 0;
              return ListTile(
                leading: const Icon(Icons.route, color: Colors.amber),
                title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 13)),
                subtitle: Text('$steps étapes',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                    onPressed: () async {
                      await File(t['_file'] as String).delete();
                      if (ctx.mounted) Navigator.pop(ctx);
                    }),
                  const Icon(Icons.chevron_right, color: Colors.white38),
                ]),
                onTap: () => Navigator.pop(ctx, t),
              );
            },
          )),
        const SizedBox(height: 8),
      ])),
    );
    if (chosen == null) return;
    try {
      final loaded = RouteTrip.fromJson(chosen);
      setState(() { _trip = loaded; _legRoutes.clear(); });
      _recalculateLegs();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur de chargement : $e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _trip.isNotEmpty;
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a1a),
      body: SafeArea(child: Column(children: [
        // ── En-tête façon Mappy : durée/distance + bouton Nouveau ──
        Container(
          color: const Color(0xFFb71c1c),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            const SizedBox(width: 4),
            const Icon(Icons.access_time, color: Colors.white70, size: 16),
            const SizedBox(width: 4),
            Text(_fmtDur(_totalDuration),
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: 14),
            const Icon(Icons.straighten, color: Colors.white70, size: 16),
            const SizedBox(width: 4),
            Text(_fmtDist(_totalDistance),
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: () { setState(() { _trip = RouteTrip(); _legRoutes.clear(); }); },
              icon: const Icon(Icons.add, size: 16, color: Colors.white),
              label: const Text('Nouveau', style: TextStyle(color: Colors.white, fontSize: 12)),
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white54),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.terrain, color: Colors.white70, size: 20),
              tooltip: 'Profil altimétrique 3D', onPressed: canSave ? _open3DProfile : null),
            IconButton(
              icon: Icon(Icons.show_chart, size: 20,
                  color: _showRouteProfile ? Colors.amber : Colors.white70),
              tooltip: 'Profil altimétrique sur la carte',
              onPressed: canSave ? _toggleRouteProfile2D : null),
            IconButton(
              icon: const Icon(Icons.folder_open, color: Colors.white70, size: 20),
              tooltip: 'Charger un itinéraire', onPressed: _loadTrip),
            IconButton(
              icon: const Icon(Icons.save_outlined, color: Colors.white70, size: 20),
              tooltip: 'Sauvegarder', onPressed: canSave ? _saveTrip : null),
          ]),
        ),

        // ── Barre de style de route (façon 68°, remplace l'onglet Jour/Parcours) ──
        Container(
          color: const Color(0xFF232323),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            ...TripRouteStyle.values.map((s) {
              final active = s == _routeStyle;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () { setState(() => _routeStyle = s); _recalculateLegs(); },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: active ? Colors.amber.withOpacity(.2) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: active ? Colors.amber : Colors.white24)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(s.emoji, style: const TextStyle(fontSize: 13)),
                      const SizedBox(width: 4),
                      Text(s.label, style: TextStyle(fontSize: 10,
                          color: active ? Colors.amber : Colors.white54)),
                    ]),
                  ),
                ),
              );
            }),
            const Spacer(),
            PopupMenuButton<String>(
              icon: Text(switch(_profile) { 'cycling' => '🚲', 'walking' => '🚶', _ => '🚗' },
                  style: const TextStyle(fontSize: 18)),
              onSelected: (p) { setState(() => _profile = p); _recalculateLegs(); },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'driving', child: Text('🚗 Voiture/Moto')),
                PopupMenuItem(value: 'cycling', child: Text('🚲 Vélo')),
                PopupMenuItem(value: 'walking', child: Text('🚶 À pied')),
              ],
            ),
          ]),
        ),

        // ── Liste des étapes façon Mappy — pliable pour ne pas masquer la carte ──
        Container(
          color: const Color(0xFF1a1a1a),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            InkWell(
              onTap: () => setState(() => _stepsExpanded = !_stepsExpanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(children: [
                  Icon(_stepsExpanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.white54, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    _trip.isEmpty ? 'Aucune étape'
                        : '${_trip.length} étape${_trip.length > 1 ? "s" : ""}'
                          '${!_stepsExpanded ? " — toucher pour déplier" : ""}',
                    style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  const Spacer(),
                  if (!_stepsExpanded && _trip.isNotEmpty)
                    Text(_trip.steps.map((s) => s.name).join(' → '),
                        overflow: TextOverflow.ellipsis, maxLines: 1,
                        style: const TextStyle(color: Colors.white38, fontSize: 10)),
                ]),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              child: !_stepsExpanded
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: _trip.isEmpty
                          ? Padding(padding: const EdgeInsets.all(20),
                              child: Column(children: [
                                const Icon(Icons.route, size: 36, color: Colors.white24),
                                const SizedBox(height: 8),
                                const Text('Ajoutez une première étape',
                                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                              ]))
                          : ReorderableListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              itemCount: _trip.length,
                              onReorder: _reorder,
                              itemBuilder: (ctx, i) => _mappyStepRow(i),
                            ),
                    ),
            ),
          ]),
        ),

        // Barre d'ajout d'étape (façon "+ / recherche" Mappy) — défilable
        // horizontalement pour accueillir 5 boutons sans les écraser sur
        // petit écran.
        Container(
          color: const Color(0xFF232323),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: SingleChildScrollView(scrollDirection: Axis.horizontal,
            child: Row(children: [
            SizedBox(width: 108, child: OutlinedButton.icon(
              onPressed: _addStepFromMyPosition,
              icon: Icon(Icons.my_location, size: 15,
                  color: widget.userPosition != null ? Colors.lightBlueAccent : Colors.white24),
              label: const Text('Ma position', style: TextStyle(fontSize: 11, color: Colors.white70)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 6)))),
            const SizedBox(width: 6),
            SizedBox(width: 96, child: OutlinedButton.icon(
              onPressed: _addStepFromSearch,
              icon: const Icon(Icons.search, size: 15, color: Colors.white70),
              label: const Text('Adresse', style: TextStyle(fontSize: 11, color: Colors.white70)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 6)))),
            const SizedBox(width: 6),
            SizedBox(width: 88, child: OutlinedButton.icon(
              onPressed: _addStepFromMap,
              icon: const Icon(Icons.map_outlined, size: 15, color: Colors.white70),
              label: const Text('Carte', style: TextStyle(fontSize: 11, color: Colors.white70)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 6)))),
            const SizedBox(width: 6),
            SizedBox(width: 100, child: OutlinedButton.icon(
              onPressed: _addStepFromPoi,
              icon: const Icon(Icons.bookmark_outline, size: 15, color: Colors.white70),
              label: const Text('Mes POI', style: TextStyle(fontSize: 11, color: Colors.white70)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 6)))),
            const SizedBox(width: 6),
            SizedBox(width: 88, child: OutlinedButton.icon(
              onPressed: _addStepFromGpx,
              icon: const Icon(Icons.timeline, size: 15, color: Colors.white70),
              label: const Text('GPX', style: TextStyle(fontSize: 11, color: Colors.white70)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 6)))),
          ]),
        )),

        // ── Carte avec icônes catégories flottantes (façon Mappy) ──
        Expanded(child: Stack(children: [
          FlutterMap(
            mapController: _mc,
            options: MapOptions(
              initialCenter: widget.userPosition ?? const LatLng(46, 2), initialZoom: 6,
            ),
            children: [
              const AppMapLayer(),
              PolylineLayer<Object>(polylines: [
                for (final r in _legRoutes.values)
                  if (r != null)
                    Polyline(points: r.geometry, strokeWidth: 4, color: Colors.blue.withOpacity(.85)),
                // Traces GPX déjà chargées — contexte visuel + source
                // possible d'étape (bouton "GPX" dans la barre au-dessus).
                for (final t in widget.gpxTracks)
                  if (t.visible)
                    Polyline(points: t.data.trackPoints
                        .map((p) => LatLng(p.lat, p.lon)).toList(),
                        strokeWidth: 3, color: t.color.withOpacity(.55)),
              ]),
              // POI déjà enregistrés — touchables pour les ajouter comme
              // étape sans passer par le sélecteur "Mes POI".
              MarkerLayer(markers: [
                for (final l in [...widget.rootLayers,
                    ...widget.folders.expand((f) => f.layers)])
                  if (l.visible)
                    for (final p in l.points)
                      Marker(point: LatLng(p.lat, p.lon), width: 30, height: 30,
                        child: GestureDetector(
                          onTap: () => _showPoiQuickMenu(p),
                          child: Icon(Icons.location_on, color: l.color, size: 28,
                              shadows: const [Shadow(color: Colors.black54, blurRadius: 3)]),
                        )),
              ]),
              MarkerLayer(markers: [
                if (_routeProfileCursor != null)
                  Marker(point: _routeProfileCursor!, width: 20, height: 20,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.amber, shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
                      ))),
                if (widget.userPosition != null)
                  Marker(point: widget.userPosition!, width: 26, height: 26,
                    child: Container(decoration: const BoxDecoration(
                        color: Colors.blue, shape: BoxShape.circle),
                      child: const Icon(Icons.person, color: Colors.white, size: 14))),
                for (int i = 0; i < _trip.length; i++)
                  Marker(point: _trip.steps[i].position, width: 30, height: 30,
                    child: Container(
                      decoration: BoxDecoration(
                        color: i == 0 ? Colors.green : (i == _trip.length - 1 ? Colors.red : Colors.orange),
                        shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                      child: Center(child: Text('${i + 1}', style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))))),
                for (final poi in _quickPoiResults)
                  Marker(point: LatLng(poi.lat, poi.lon), width: 26, height: 26,
                    child: GestureDetector(
                      onTap: () => _addQuickPoi(poi),
                      child: Container(decoration: BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle,
                          border: Border.all(color: Colors.black26)),
                        child: Center(child: Text(poi.emoji, style: const TextStyle(fontSize: 14)))))),
              ]),
            ],
          ),

          // Icônes catégories rondes colorées, façon Mappy, en haut à droite
          Positioned(top: 10, right: 10,
            child: Row(children: [
              _categoryDot('hotel', Icons.hotel, const Color(0xFF1565C0)),
              const SizedBox(width: 6),
              _categoryDot('restaurant', Icons.restaurant, const Color(0xFFD81B60)),
              const SizedBox(width: 6),
              _categoryDot('viewpoint', Icons.visibility, const Color(0xFFEF6C00)),
              const SizedBox(width: 6),
              _categoryDot('nature', Icons.terrain, const Color(0xFF7B1FA2)),
              const SizedBox(width: 6),
              _categoryDot('fuel', Icons.local_gas_station, const Color(0xFF2E7D32)),
            ]),
          ),

          if (_calculating)
            const Positioned(top: 10, left: 10,
              child: SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber))),

          Positioned(bottom: 16, right: 16,
            child: FloatingActionButton.small(
              heroTag: 'fit_trip',
              onPressed: _fitAll, backgroundColor: const Color(0xFF003580),
              child: const Icon(Icons.fit_screen, color: Colors.white))),

          // ── Profil altimétrique 2D (voir _toggleRouteProfile2D) ──
          if (_showRouteProfile && _routeProfileLoading)
            const Positioned(left: 0, right: 0, bottom: 0,
              child: NavProfileLoadingBar())
          else if (_showRouteProfile && _routeProfilePoints != null)
            Positioned(left: 0, right: 0, bottom: 0,
              child: RouteElevationProfile(
                points: _routeProfilePoints!,
                height: 100,
                onScrub: (pos) => setState(() => _routeProfileCursor = pos),
                onScrubEnd: () {},
                onClose: () => setState(() {
                  _showRouteProfile = false;
                  _routeProfileCursor = null;
                }),
              )),
        ])),

        // ── Bouton de lancement ──
        Padding(padding: const EdgeInsets.all(10),
          child: SizedBox(width: double.infinity,
            child: FilledButton.icon(
              onPressed: _trip.isEmpty ? null : () => Navigator.pop(context, _trip),
              icon: const Icon(Icons.navigation),
              label: const Text('Lancer la navigation'),
              style: FilledButton.styleFrom(backgroundColor: Colors.amber,
                  foregroundColor: Colors.black, minimumSize: const Size(double.infinity, 46)),
            ))),
      ])),
    );
  }

  // ── Ligne d'étape façon Mappy : marqueur + adresse + outils ──────────────
  Widget _mappyStepRow(int i) {
    final step = _trip.steps[i];
    final leg = i > 0 ? _legRoutes[i - 1] : null;
    final isFirst = i == 0, isLast = i == _trip.length - 1;
    return Column(key: ValueKey(step.id), mainAxisSize: MainAxisSize.min, children: [
      // Ligne adresse
      Container(
        color: const Color(0xFF1a1a1a),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          GestureDetector(
            onTap: () => _removeStep(i),
            child: Container(width: 26, height: 26,
              decoration: BoxDecoration(
                color: isFirst ? Colors.green : (isLast ? Colors.red : Colors.grey.shade700),
                shape: BoxShape.circle),
              child: Icon(isFirst ? Icons.circle : (isLast ? Icons.flag : Icons.close),
                  size: isFirst ? 10 : 14, color: Colors.white)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(step.name,
              style: const TextStyle(color: Colors.amber, fontSize: 13),
              overflow: TextOverflow.ellipsis)),
          ReorderableDelayedDragStartListener(
            index: i,
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.drag_indicator, size: 18, color: Colors.white38))),
          IconButton(
            icon: const Icon(Icons.center_focus_strong, size: 16, color: Colors.white38),
            onPressed: () => _mc.move(step.position, 13),
            padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        ]),
      ),
      // Ligne "leg" entre deux étapes : distance/durée + icône route
      if (leg != null)
        Container(
          color: const Color(0xFF262626),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            const SizedBox(width: 26),
            const SizedBox(width: 10),
            const Icon(Icons.swap_vert, size: 14, color: Colors.white38),
            const SizedBox(width: 6),
            Text(_fmtDur(leg.totalDurationS),
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
            const SizedBox(width: 8),
            const SizedBox(width: 2),
            Icon(_routeStyle == TripRouteStyle.highways ? Icons.add_road : Icons.route,
                size: 14, color: Colors.blue.shade300),
            const SizedBox(width: 6),
            Text(_fmtDist(leg.totalDistanceM),
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ]),
        ),
    ]);
  }

  // ── Bouton catégorie rond (recherche POI rapide, façon Mappy) ────────────
  Widget _categoryDot(String categoryId, IconData icon, Color color) {
    final active = _activeCategory == categoryId;
    return GestureDetector(
      onTap: () => _toggleCategorySearch(categoryId),
      child: Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          color: color, shape: BoxShape.circle,
          border: Border.all(color: active ? Colors.white : Colors.white70,
              width: active ? 3 : 1.5),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(.3),
              blurRadius: 4, offset: const Offset(0, 2))],
        ),
        child: Icon(icon, color: Colors.white, size: 16),
      ),
    );
  }

  Future<void> _toggleCategorySearch(String categoryId) async {
    if (_activeCategory == categoryId) {
      setState(() { _activeCategory = null; _quickPoiResults = []; });
      return;
    }
    setState(() { _activeCategory = categoryId; _quickPoiResults = []; });
    final b = _mc.camera.visibleBounds;
    final category = kPoiCategories.firstWhere((c) => c.id == categoryId);
    category.selected = true;
    final results = await OverpassPoiService.search(
      minLat: b.south, maxLat: b.north, minLon: b.west, maxLon: b.east,
      categories: [category], limit: 40);
    category.selected = false;
    if (mounted && _activeCategory == categoryId) {
      setState(() => _quickPoiResults = results);
    }
  }

  Future<void> _addQuickPoi(OverpassPoiResult poi) async {
    setState(() {
      _trip.addStep(TripStep.fromPoint(poi.name, LatLng(poi.lat, poi.lon)));
      _activeCategory = null;
      _quickPoiResults = [];
    });
    _recalculateLegs();
  }

  String _fmtDist(double m) => m < 1000 ? '${m.round()} m' : '${(m/1000).toStringAsFixed(1)} km';
  String _fmtDur(double s) {
    if (s < 60) return '${s.round()} s';
    if (s < 3600) return '${(s/60).round()} min';
    final h = (s/3600).floor(); final m = ((s%3600)/60).round();
    return '${h}h${m.toString().padLeft(2,'0')}';
  }
}

/// Mini-écran de sélection de point sur la carte (tap pour placer)
class _MapPickerScreen extends StatefulWidget {
  final LatLng initialCenter;
  final List<PoiLayer> rootLayers;
  final List<PoiFolder> folders;
  final List<GpxTrack> gpxTracks;
  const _MapPickerScreen({
    required this.initialCenter,
    this.rootLayers = const [], this.folders = const [], this.gpxTracks = const [],
  });
  @override
  State<_MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<_MapPickerScreen> {
  late final MapController _mc;
  LatLng? _picked;

  @override
  void initState() { super.initState(); _mc = MapController(); }
  @override
  void dispose() { _mc.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choisir un point sur la carte'),
          backgroundColor: const Color(0xFF003580), foregroundColor: Colors.white),
      body: Stack(children: [
        FlutterMap(
          mapController: _mc,
          options: MapOptions(
            initialCenter: widget.initialCenter, initialZoom: 12,
            onTap: (_, point) => setState(() => _picked = point),
          ),
          children: [
            const AppMapLayer(),
            // Traces GPX déjà chargées — contexte visuel pour choisir un
            // point cohérent avec un itinéraire/une randonnée existante.
            PolylineLayer<Object>(polylines: [
              for (final t in widget.gpxTracks)
                if (t.visible)
                  Polyline(points: t.data.trackPoints
                      .map((p) => LatLng(p.lat, p.lon)).toList(),
                      strokeWidth: 3, color: t.color.withOpacity(.7)),
            ]),
            // POI déjà enregistrés — contexte visuel (pas de menu ici, ce
            // picker sert à choisir un point libre ; pour ajouter un POI
            // existant comme étape, utiliser le bouton "Mes POI").
            MarkerLayer(markers: [
              for (final l in [...widget.rootLayers,
                  ...widget.folders.expand((f) => f.layers)])
                if (l.visible)
                  for (final p in l.points)
                    Marker(point: LatLng(p.lat, p.lon), width: 22, height: 22,
                      child: Icon(Icons.location_on, color: l.color, size: 22)),
            ]),
            if (_picked != null)
              MarkerLayer(markers: [
                Marker(point: _picked!, width: 36, height: 36,
                  child: const Icon(Icons.location_on, color: Colors.red, size: 36)),
              ]),
          ],
        ),
        Positioned(bottom: 16, left: 16, right: 16,
          child: FilledButton(
            onPressed: _picked == null ? null : () => Navigator.pop(context, _picked),
            style: FilledButton.styleFrom(backgroundColor: Colors.amber,
                foregroundColor: Colors.black, minimumSize: const Size(double.infinity, 48)),
            child: const Text('Valider ce point'))),
      ]),
    );
  }
}
