import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'gpx_track.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'poi_zoom_settings.dart';
import 'poi_detail_screen.dart';
import 'layers_panel.dart';
import 'route_elevation_profile.dart';
import 'overpass_poi_service.dart';
import 'tourist_poi_overlay.dart';
import 'location_service.dart';
import 'tile_cache_screen.dart';
import 'core/services/vector_map_layer.dart';
import 'navigation_service.dart';
import 'map_orientation_button.dart';
import 'speed_camera_service.dart';
import 'speed_camera_layer.dart';
import 'route_trip.dart';
import 'place_search_field.dart';
import 'speed_limit_service.dart';
import 'speed_limit_layer.dart';
import 'trip_editor_screen.dart';
import 'trip_navigation_screen.dart';

class GpxOnlyView extends StatefulWidget {
  final List<GpxTrack>  tracks;
  final List<PoiLayer>  poiLayers;
  final List<PoiFolder> poiFolders;
  final PoiZoomSettings? zoomSettings;
  /// Appelé quand des POI sont ajoutés/modifiés depuis la carte,
  /// pour que le parent puisse sauvegarder la session.
  final VoidCallback? onChanged;

  const GpxOnlyView({
    super.key,
    required this.tracks,
    this.poiLayers   = const [],
    this.poiFolders  = const [],
    this.zoomSettings,
    this.onChanged,
  });

  @override
  State<GpxOnlyView> createState() => _GpxOnlyViewState();
}

class _GpxOnlyViewState extends State<GpxOnlyView> {
  bool   _showStats   = true;
  bool   _showTracks  = false;
  bool   _showZoomCfg = false;
  double _currentZoom = 10.0;
  late final MapController   _mapController;
  late final PoiZoomSettings _zoomSettings;
  late final MapOrientationController _orientCtrl;
  final SpeedCameraController _radarCtrl = SpeedCameraController();
  SpeedCamera? _activeRadarAlert;
  double _activeRadarDist = 0;
  RouteTrip? _activeTrip;
  final SpeedLimitController _speedLimitCtrl = SpeedLimitController();
  // ── Profil altimétrique 2D incrusté sur la carte ──────────────────────────
  GpxTrack? _mapProfileTrack;      // trace dont le profil est affiché
  LatLng?   _mapProfileCursor;     // position courante du curseur du profil

  // ── Localisation GPS + boussole ───────────────────────────────────────────
  bool     _locationActive = false;
  double?  _userLat, _userLon, _userHeading;
  bool     _manualPositionMode = false; // true = position fixée manuellement (Windows/pas de signal)
  PoiPoint? _compassTarget;
  // ValueNotifiers pour pousser les updates GPS vers NavigationScreen en temps réel
  final _positionNotifier = ValueNotifier<LatLng>(const LatLng(0, 0));
  final _headingNotifier  = ValueNotifier<double?>(null);
  String?  _locationError;
  bool     _followLocation = false;  // recentrage auto

  // ── POI touristiques Overpass ─────────────────────────────────────────────
  bool                        _showTouristPoi = false;
  final List<PoiCategory>     _categories     = List.from(kPoiCategories);
  List<OverpassPoiResult>     _touristResults = [];
  final Set<int>              _touristAdded   = {};

  // ── Détection de recouvrement ─────────────────────────────────────────────
  // Cache des offsets calculés (clé = poi id = hashCode)
  final Map<int, Offset> _thumbOffsets = {};

  void _cycleOrientation() {
    setState(() => _orientCtrl.cycle());
    if (_userLat != null && _userLon != null) {
      _orientCtrl.apply(
          userPosition: LatLng(_userLat!, _userLon!),
          userHeading: _userHeading,
          zoomForFollow: _currentZoom);
    } else {
      // Pas de GPS actif → centrer sur les points visibles pour Nord/Cap aussi
      _orientCtrl.apply(
          userPosition: const LatLng(0, 0),
          userHeading: _userHeading,
          zoomForFollow: _currentZoom);
    }
  }

  // ── Position manuelle (Windows / pas de signal GPS) ───────────────────────
  /// Définit une position simulée comme "ma position" pour la navigation,
  /// utile sous Windows ou quand le GPS réel n'a pas de signal.
  void _setManualPosition(LatLng pos) {
    setState(() {
      _userLat = pos.latitude;
      _userLon = pos.longitude;
      _manualPositionMode = true;
      _locationActive = true; // pour activer l'affichage du marqueur/navigation
    });
    _positionNotifier.value = pos;
  }

  void _clearManualPosition() {
    setState(() {
      if (_manualPositionMode) {
        _userLat = null; _userLon = null;
        _locationActive = false;
      }
      _manualPositionMode = false;
    });
  }

  // ── Itinéraire multi-étapes ────────────────────────────────────────────────

  /// Charge un itinéraire sauvegardé directement (sans passer par l'éditeur)
  /// et propose de lancer la navigation immédiatement — accès rapide via
  /// appui long sur le bouton itinéraire.
  Future<void> _quickLoadTrip() async {
    final dir = await TripEditorScreen.tripsDirectory();
    if (!dir.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Aucun itinéraire sauvegardé')));
      return;
    }
    final files = dir.listSync().whereType<File>()
        .where((f) => f.path.endsWith('.json')).toList();
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Aucun itinéraire sauvegardé')));
      return;
    }
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
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 360),
          child: ListView.builder(
            shrinkWrap: true, itemCount: trips.length,
            itemBuilder: (ctx, i) {
              final t = trips[i];
              final name = t['name']?.toString() ?? 'Itinéraire';
              final steps = (t['steps'] as List?)?.length ?? 0;
              return ListTile(
                leading: const Icon(Icons.route, color: Colors.amber),
                title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 13)),
                subtitle: Text('$steps étapes',
                    style: const TextStyle(color: Colors.white38, fontSize: 11)),
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
      if (loaded.isEmpty) return;
      setState(() => _activeTrip = loaded..reset());

      // Point de départ : position GPS live si disponible, sinon la
      // 1ère adresse du trajet fait office de départ — on ne demande
      // plus de position manuelle séparée (c'est déjà celle saisie par
      // l'utilisateur comme première étape).
      final start = (_userLat != null && _userLon != null)
          ? LatLng(_userLat!, _userLon!)
          : _activeTrip!.steps.first.position;
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(
        builder: (_) => TripNavigationScreen(
          trip: _activeTrip!,
          initialPosition: start,
          profile: 'driving',
          positionNotifier: _positionNotifier,
          headingNotifier: _headingNotifier,
        ),
      ));
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Erreur de chargement : $e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _openTripEditor() async {
    final result = await Navigator.push<RouteTrip>(context, MaterialPageRoute(
      builder: (_) => TripEditorScreen(
        initialTrip: _activeTrip,
        rootLayers: widget.poiLayers,
        folders:    widget.poiFolders,
        gpxTracks:  widget.tracks,
        userPosition: (_userLat != null && _userLon != null)
            ? LatLng(_userLat!, _userLon!) : null,
        profile: 'driving',
      ),
    ));
    if (result == null || result.isEmpty) return;

    // Point de départ : position GPS live si disponible, sinon la 1ère
    // adresse saisie dans l'itinéraire — plus de dialogue bloquant
    // "Position de départ (sans GPS)" avant de pouvoir naviguer.
    final start = (_userLat != null && _userLon != null)
        ? LatLng(_userLat!, _userLon!)
        : result.steps.first.position;

    setState(() => _activeTrip = result..reset());
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => TripNavigationScreen(
        trip: _activeTrip!,
        initialPosition: start,
        profile: 'driving',
        positionNotifier: _positionNotifier,
        headingNotifier: _headingNotifier,
      ),
    ));
    if (mounted) setState(() {}); // rafraîchir l'icône du bouton (terminé/en cours)
  }

  Future<void> _showManualPositionDialog() async {
    final latCtrl = TextEditingController(
        text: _userLat?.toStringAsFixed(6) ?? '');
    final lonCtrl = TextEditingController(
        text: _userLon?.toStringAsFixed(6) ?? '');

    final result = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Position de départ (sans GPS)'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
            'Aucun signal GPS détecté (normal sous Windows, ou hors couverture).\n'
            'Choisissez votre point de départ pour utiliser la navigation.',
            style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await PlaceSearchDialog.show(context,
                  title: 'Rechercher la position de départ');
              if (picked != null) {
                latCtrl.text = picked.position.latitude.toStringAsFixed(6);
                lonCtrl.text = picked.position.longitude.toStringAsFixed(6);
              }
            },
            icon: const Icon(Icons.search, size: 16),
            label: const Text('Rechercher par nom (ville, adresse…)'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 0)),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: latCtrl,
              decoration: const InputDecoration(labelText: 'Latitude', isDense: true),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: lonCtrl,
              decoration: const InputDecoration(labelText: 'Longitude', isDense: true),
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true))),
          ]),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(context, 'center'),
            icon: const Icon(Icons.center_focus_strong, size: 16),
            label: const Text('Utiliser le centre de la carte actuelle'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          if (_manualPositionMode)
            TextButton(onPressed: () => Navigator.pop(context, 'clear'),
                child: const Text('Effacer', style: TextStyle(color: Colors.red))),
          FilledButton(onPressed: () => Navigator.pop(context, 'manual'),
              child: const Text('Valider')),
        ],
      ),
    );

    if (result == 'center') {
      _setManualPosition(_mapController.camera.center);
    } else if (result == 'manual') {
      final lat = double.tryParse(latCtrl.text.trim());
      final lon = double.tryParse(lonCtrl.text.trim());
      if (lat != null && lon != null && lat.abs() <= 90 && lon.abs() <= 180) {
        _setManualPosition(LatLng(lat, lon));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Coordonnées invalides'), backgroundColor: Colors.red));
      }
    } else if (result == 'clear') {
      _clearManualPosition();
    }
  }

  // ── Radars : revérification périodique de la juridiction ──────────────────
  LatLng? _lastJurisdictionCheckPos;
  Future<void> _maybeRecheckJurisdiction(LatLng pos) async {
    if (!_radarCtrl.layerEnabled && !_radarCtrl.alertEnabled) return;
    final moved = _lastJurisdictionCheckPos == null
        ? true
        : NavigationService.distanceM(_lastJurisdictionCheckPos!, pos) > 2000;
    if (!moved) return;
    _lastJurisdictionCheckPos = pos;
    await _radarCtrl.checkJurisdiction(pos);
  }

  // ── Vue globale : tous les points GPX + POI visibles ──────────────────────
  List<LatLng> _allVisiblePoints() {
    final pts = <LatLng>[];
    for (final t in widget.tracks) {
      if (t.visible) {
        pts.addAll(t.data.trackPoints.map((p) => LatLng(p.lat, p.lon)));
      }
    }
    for (final l in widget.poiLayers) {
      if (l.visible) pts.addAll(l.points.map((p) => LatLng(p.lat, p.lon)));
    }
    for (final f in widget.poiFolders) {
      for (final l in f.layers) {
        if (l.visible) pts.addAll(l.points.map((p) => LatLng(p.lat, p.lon)));
      }
    }
    if (_userLat != null && _userLon != null) {
      pts.add(LatLng(_userLat!, _userLon!));
    }
    return pts;
  }

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _orientCtrl = MapOrientationController(_mapController,
        overviewPoints: _allVisiblePoints);
    _zoomSettings  = widget.zoomSettings ?? PoiZoomSettings();
    _radarCtrl.addListener(() { if (mounted) setState(() {}); });
    _speedLimitCtrl.addListener(() { if (mounted) setState(() {}); });
    _radarCtrl.loadPrefs();
    _speedLimitCtrl.loadPrefs();
  }

  @override
  void dispose() {
    LocationService.stop();
    _positionNotifier.dispose();
    _headingNotifier.dispose();
    _radarCtrl.dispose();
    _speedLimitCtrl.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // ── Bbox englobante ───────────────────────────────────────────────────────
  ({double minLat, double maxLat, double minLon, double maxLon}) get _bbox {
    double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
    bool any = false;
    void check(double lat, double lon) {
      any = true;
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lon < minLon) minLon = lon;
      if (lon > maxLon) maxLon = lon;
    }
    for (final t in widget.tracks) {
      if (!t.visible) continue;
      for (final p in t.data.trackPoints) check(p.lat, p.lon);
    }
    for (final l in widget.poiLayers) {
      if (!l.visible) continue;
      for (final p in l.points) check(p.lat, p.lon);
    }
    for (final f in widget.poiFolders) {
      if (!f.visible) continue;
      for (final l in f.layers) {
        if (!l.visible) continue;
        for (final p in l.points) check(p.lat, p.lon);
      }
    }
    if (!any) return (minLat: 45.0, maxLat: 46.0, minLon: 5.0, maxLon: 6.0);
    return (minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon);
  }

  LatLng get _center {
    final b = _bbox;
    return LatLng((b.minLat + b.maxLat) / 2, (b.minLon + b.maxLon) / 2);
  }

  double get _initZoom {
    final b = _bbox;
    final span = [b.maxLat - b.minLat, b.maxLon - b.minLon]
        .reduce((a, b) => a > b ? a : b);
    if (span < 0.005) return 15.0;
    if (span < 0.02)  return 14.0;
    if (span < 0.05)  return 13.0;
    if (span < 0.1)   return 12.0;
    if (span < 0.3)   return 11.0;
    if (span < 0.8)   return 10.0;
    if (span < 2.0)   return 9.0;
    return 8.0;
  }

  // Palier d'affichage discret — reconstruit seulement au changement de palier
  int _zoomLevel(double z) {
    if (z < _zoomSettings.zoomLabel) return 0;
    if (z < _zoomSettings.zoomThumb) return 1;
    if (z < 15.0)                    return 2;
    return 3;
  }

  // Tous les POI visibles avec leur couche source
  List<({PoiPoint poi, Color color, PoiLayer layer})> get _allVisiblePoi {
    final result = <({PoiPoint poi, Color color, PoiLayer layer})>[];
    for (final l in widget.poiLayers) {
      if (!l.visible) continue;
      for (final p in l.points) result.add((poi: p, color: l.color, layer: l));
    }
    for (final f in widget.poiFolders) {
      if (!f.visible) continue;
      for (final l in f.layers) {
        if (!l.visible) continue;
        for (final p in l.points) result.add((poi: p, color: l.color, layer: l));
      }
    }
    return result;
  }

  // ── Calcul des offsets anti-recouvrement ──────────────────────────────────
  // Pour chaque POI, vérifie si sa miniature chevauche un tracé GPX proche
  // et décale si besoin. Opération approximative en pixels projetés.
  void _computeThumbOffsets(Size mapSize) {
    _thumbOffsets.clear();
    final pois = _allVisiblePoi;
    if (pois.isEmpty) return;

    final cam = _mapController.camera;

    // Convertir LatLng → pixels écran via la vraie caméra flutter_map
    Offset toScreen(double lat, double lon) {
      try {
        final pt = cam.latLngToScreenPoint(LatLng(lat, lon));
        return Offset(pt.x.toDouble(), pt.y.toDouble());
      } catch (_) {
        return Offset.zero;
      }
    }

    final double thumbSize = _currentZoom >= 15.0 ? 60.0 : 48.0;
    const double dotSize   = _dotSize;
    const double gap       = 6.0; // marge minimale entre miniatures

    // Calculer position écran de chaque POI
    final List<Offset> dots    = pois.map((e) => toScreen(e.poi.lat, e.poi.lon)).toList();
    final List<Offset> shifts  = List.filled(pois.length, Offset.zero);

    // Candidats d'offset à tester (8 directions + plus loin)
    List<Offset> _candidates(double ts) => [
      Offset(dotSize + gap, -(ts + gap)),        // haut-droite (défaut)
      Offset(-(ts + gap), -(ts + gap)),           // haut-gauche
      Offset(dotSize + gap, gap),                 // bas-droite
      Offset(-(ts + gap), gap),                   // bas-gauche
      Offset(dotSize / 2 - ts / 2, -(ts + gap)), // haut-centré
      Offset(dotSize / 2 - ts / 2, gap),          // bas-centré
      Offset(dotSize + gap + ts, -(ts + gap)),    // haut très à droite
      Offset(-(ts * 2 + gap), -(ts + gap)),       // haut très à gauche
    ];

    for (int i = 0; i < pois.length; i++) {
      final px = dots[i];
      if (px == Offset.zero) continue;

      bool placed = false;
      for (final candidate in _candidates(thumbSize)) {
        // Rect de la miniature candidate
        final thumbRect = Rect.fromLTWH(
          px.dx + candidate.dx,
          px.dy + candidate.dy,
          thumbSize, thumbSize,
        );

        // 1. Conflit avec les tracés GPX
        bool conflictsTrack = false;
        for (final t in widget.tracks) {
          if (!t.visible) continue;
          final pts = t.data.trackPoints;
          for (int j = 1; j < pts.length; j++) {
            final a  = toScreen(pts[j-1].lat, pts[j-1].lon);
            final b  = toScreen(pts[j].lat,   pts[j].lon);
            if (_segmentIntersectsRect(a, b, thumbRect.inflate(gap))) {
              conflictsTrack = true;
              break;
            }
          }
          if (conflictsTrack) break;
        }
        if (conflictsTrack) continue;

        // 2. Conflit avec les miniatures déjà placées
        bool conflictsPoi = false;
        for (int k = 0; k < i; k++) {
          if (dots[k] == Offset.zero) continue;
          final otherRect = Rect.fromLTWH(
            dots[k].dx + shifts[k].dx,
            dots[k].dy + shifts[k].dy,
            thumbSize, thumbSize,
          );
          if (thumbRect.inflate(gap / 2).overlaps(otherRect.inflate(gap / 2))) {
            conflictsPoi = true;
            break;
          }
        }
        if (conflictsPoi) continue;

        // 3. Conflit avec les ronds GPS des autres POI
        bool conflictsDots = false;
        for (int k = 0; k < pois.length; k++) {
          if (k == i || dots[k] == Offset.zero) continue;
          final dotRect = Rect.fromCenter(
              center: dots[k], width: dotSize + gap, height: dotSize + gap);
          if (thumbRect.inflate(gap / 2).overlaps(dotRect)) {
            conflictsDots = true;
            break;
          }
        }
        if (conflictsDots) continue;

        shifts[i] = candidate;
        placed = true;
        break;
      }

      // Si aucun candidat ne convient, prendre le haut-droite par défaut
      if (!placed) shifts[i] = _candidates(thumbSize).first;
      _thumbOffsets[pois[i].poi.hashCode] = shifts[i];
    }
  }

  // Vérifie si un segment AB intersecte (ou est proche de) un Rect
  bool _segmentIntersectsRect(Offset a, Offset b, Rect r) {
    // Vérifier si le segment passe à moins de gap pixels du rect
    // Approche : tester si l'un des 4 côtés du rect est franchi
    final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
    // Distance min du segment au rect
    final pts = [a, b];
    for (final p in pts) {
      if (r.contains(p)) return true;
    }
    // Tester si le segment intersecte les 4 côtés du rect
    for (int i = 0; i < 4; i++) {
      final c1 = corners[i];
      final c2 = corners[(i + 1) % 4];
      if (_segmentsIntersect(a, b, c1, c2)) return true;
    }
    // Distance segment → centre rect
    return _distPointSegment(r.center, a, b) < 4.0;
  }

  bool _segmentsIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
    final d1 = _cross(p3, p4, p1);
    final d2 = _cross(p3, p4, p2);
    final d3 = _cross(p1, p2, p3);
    final d4 = _cross(p1, p2, p4);
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) return true;
    return false;
  }

  double _cross(Offset o, Offset a, Offset b) =>
      (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

  // Distance d'un point à un segment
  double _distPointSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final ap = p - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    final t = (ap.dx * ab.dx + ap.dy * ab.dy) / len2;
    final tc = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + tc * ab.dx, a.dy + tc * ab.dy);
    return (p - proj).distance;
  }

  // ── Menu contextuel POI (appui long) ────────────────────────────────────
  // ── Long press sur la carte → POI le plus proche ────────────────────────
  void _onMapLongPress(LatLng latLng) {
    // Seuil large : ~500px equiv à ce zoom
    // à zoom 14 : 0.05/64 ≈ 0.0008° ≈ 80m ; à zoom 10 : 0.05/4 ≈ 0.012° ≈ 1.3km
    final thresholdDeg = 0.05 / math.pow(2, (_currentZoom - 8).clamp(0, 8));

    // Chercher le POI normal le plus proche
    double minDist = double.infinity;
    ({PoiPoint poi, Color color, PoiLayer layer})? nearest;
    for (final e in _allVisiblePoi) {
      final dlat = e.poi.lat - latLng.latitude;
      final dlon = e.poi.lon - latLng.longitude;
      final dist = dlat * dlat + dlon * dlon;
      if (dist < minDist) { minDist = dist; nearest = e; }
    }
    if (nearest != null && minDist < thresholdDeg * thresholdDeg) {
      _showPoiContextMenu(context, nearest.poi, nearest.layer);
      return;
    }

    // Chercher dans les résultats Overpass
    if (_showTouristPoi && _touristResults.isNotEmpty) {
      double minDistOvp = double.infinity;
      int nearestIdx = -1;
      for (int i = 0; i < _touristResults.length; i++) {
        final r = _touristResults[i];
        final dlat = r.lat - latLng.latitude;
        final dlon = r.lon - latLng.longitude;
        final dist = dlat * dlat + dlon * dlon;
        if (dist < minDistOvp) { minDistOvp = dist; nearestIdx = i; }
      }
      if (nearestIdx >= 0 && minDistOvp < thresholdDeg * thresholdDeg) {
        _showOverpassContextMenu(nearestIdx);
        return;
      }
    }

    // Aucun POI proche : proposer d'en créer un à cet endroit
    _showCreatePoiMenu(latLng);
  }

  // Menu pour créer un nouveau POI à l'endroit tapé
  void _showCreatePoiMenu(LatLng latLng) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        maxChildSize: 0.85,
        minChildSize: 0.3,
        expand: false,
        builder: (_, ctrl) => _CreatePoiSheet(
          latLng:     latLng,
          rootLayers: widget.poiLayers,
          folders:    widget.poiFolders,
          onCreated:  (poi, layer) async {
            Navigator.pop(ctx);

            // Détection de doublon (distance < 100m ou nom similaire)
            final allExisting = [
              ...widget.poiLayers.expand((l) => l.points),
              ...widget.poiFolders.expand((f) => f.layers.expand((l) => l.points)),
            ];
            PoiPoint? duplicate;
            for (final ep in allExisting) {
              final dist = _distM(poi.lat, poi.lon, ep.lat, ep.lon);
              if (dist < 100 || _nameSim(poi.name, ep.name) > 0.8) {
                duplicate = ep;
                break;
              }
            }

            if (duplicate != null && mounted) {
              final proceed = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('⚠️ Doublon possible'),
                  content: Text(
                      'Un POI similaire existe déjà :\n« ${duplicate!.name} »\n\n'
                      'Voulez-vous ajouter quand même « ${poi.name} » ?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false),
                        child: const Text('Annuler')),
                    FilledButton(onPressed: () => Navigator.pop(context, true),
                        style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                        child: const Text('Ajouter quand même')),
                  ],
                ),
              );
              if (proceed != true) return;
            }

            setState(() => layer.points.add(poi));
            widget.onChanged?.call();
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('${poi.name} ajouté dans "${layer.label}"'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2)));
          },
        ),
      ),
    );
  }

  // Menu contextuel pour un résultat Overpass (ajout + édition)
  void _showOverpassContextMenu(int idx) {
    final r     = _touristResults[idx];
    final added = _touristAdded.contains(idx);
    final cat   = _categories.firstWhere(
      (c) => c.id == r.categoryId, orElse: () => _categories.first);

    showModalBottomSheet(
      context: context, // context du State — toujours valide ici
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(children: [
            Text(r.emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.name, style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
                Text('${cat.emoji} ${cat.label}',
                    style: TextStyle(fontSize: 12, color: cat.color)),
              ],
            )),
            if (added)
              const Icon(Icons.check_circle, color: Colors.green, size: 20),
          ]),
        ),
        const Divider(height: 1),
        if (!added)
          ListTile(
            leading: Icon(Icons.add_location_alt, color: cat.color),
            title: const Text('Ajouter aux POI'),
            subtitle: const Text("Ouvre l'édition avant d'ajouter"),
            onTap: () async {
              Navigator.pop(context);
              await _addOverpassPoi(idx);
            },
          ),
        ListTile(
          leading: const Icon(Icons.my_location, color: Colors.teal),
          title: const Text('Centrer la carte ici'),
          onTap: () {
            Navigator.pop(context);
            _mapController.move(LatLng(r.lat, r.lon), _currentZoom);
          },
        ),
        if (added)
          ListTile(
            leading: const Icon(Icons.remove_circle_outline, color: Colors.orange),
            title: const Text('Retirer de la sélection'),
            onTap: () {
              Navigator.pop(context);
              setState(() => _touristAdded.remove(idx));
            },
          ),
        const SizedBox(height: 8),
      ])),
    );
  }

  // ── Localisation GPS ───────────────────────────────────────────────────────
  /// Traite un tick de position — utilisé par le vrai GPS ET la simulation,
  /// pour que radars, limites de vitesse, orientation et navigation se
  /// comportent identiquement dans les deux cas.
  void _handlePositionTick(LatLng pos) {
    setState(() { _userLat = pos.latitude; _userLon = pos.longitude; });
    _positionNotifier.value = pos;
    if (_followLocation && mounted) {
      _mapController.move(pos, _currentZoom);
    }
    if (_orientCtrl.mode != MapOrientationMode.overview) {
      _orientCtrl.apply(userPosition: pos, userHeading: _userHeading,
          zoomForFollow: _currentZoom);
    }
    // Radars
    if (_radarCtrl.alertEnabled) {
      final hit = _radarCtrl.checkProximity(pos);
      if (hit != null && mounted) {
        setState(() {
          _activeRadarAlert = hit;
          _activeRadarDist = NavigationService.distanceM(pos, LatLng(hit.lat, hit.lon));
        });
      }
    }
    // Limites de vitesse — indicateur dynamique
    if (_speedLimitCtrl.segments.isNotEmpty) {
      _speedLimitCtrl.updateCurrentPosition(pos);
    }
    _maybeRecheckJurisdiction(pos);
  }

  void _handleHeadingTick(double? h) {
    if (h == null) return;
    setState(() => _userHeading = h);
    _headingNotifier.value = h;
    if (_orientCtrl.mode == MapOrientationMode.heading &&
        _userLat != null && _userLon != null) {
      _orientCtrl.apply(userPosition: LatLng(_userLat!, _userLon!),
          userHeading: h, zoomForFollow: _currentZoom);
    }
  }

  Future<void> _toggleLocation() async {
    if (_locationActive) {
      LocationService.stop();
      setState(() { _locationActive=false; _followLocation=false; _manualPositionMode=false;
          _userLat=null; _userLon=null; _userHeading=null; _locationError=null; });
      return;
    }
    _manualPositionMode = false; // activer le vrai GPS désactive le mode manuel
    final err = await LocationService.start(
      onPosition: (pos) => _handlePositionTick(LatLng(pos.latitude, pos.longitude)),
      onHeading: (h) => _handleHeadingTick(h),
    );
    if (err != null) {
      setState(() { _locationError = err; });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err), backgroundColor: Colors.red));
    } else {
      setState(() { _locationActive = true; _locationError = null; });
    }
  }

  void _centerOnUser() {
    if (_userLat != null && _userLon != null) {
      _followLocation = true;
      _mapController.move(LatLng(_userLat!, _userLon!), 16.0);
    }
  }

  // Ajouter un résultat Overpass aux POI normaux (avec édition)
  Future<void> _addOverpassPoi(int idx) async {
    final r   = _touristResults[idx];
    final cat = _categories.firstWhere(
      (c) => c.id == r.categoryId, orElse: () => _categories.first);

    // Ouvrir l'édition pour permettre de modifier avant d'ajouter
    final poi = r.toPoiPoint();
    final edited = await Navigator.push<PoiPoint>(
      context,
      MaterialPageRoute(builder: (_) =>
          PoiDetailScreen(poi: poi, color: cat.color)),
    );
    if (edited == null) return; // annulé

    // Trouver ou créer la couche de cette catégorie
    final layerLabel = '${cat.emoji} ${cat.label}';
    PoiLayer? layer = widget.poiLayers
        .where((l) => l.label == layerLabel).firstOrNull;
    if (layer == null) {
      layer = PoiLayer(label: layerLabel, points: [], color: cat.color);
      widget.poiLayers.add(layer);
    }
    layer.points.add(edited);
    setState(() => _touristAdded.add(idx));
    widget.onChanged?.call();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${edited.name} ajouté dans "$layerLabel"'),
        backgroundColor: cat.color,
        duration: const Duration(seconds: 2),
      ));
    }
  }

  void _showPoiContextMenu(BuildContext ctx, PoiPoint poi, PoiLayer layer) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          // En-tête
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Container(width: 12, height: 12,
                decoration: BoxDecoration(
                  color: layer.color, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(poi.name, style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
                  if (poi.type != null)
                    Text('${_typeEmoji(poi.type)} ${poi.type}',
                        style: TextStyle(fontSize: 12,
                            color: Colors.grey.shade600)),
                ],
              )),
            ]),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.edit, color: Colors.blue),
            title: const Text('Modifier ce POI'),
            onTap: () { Navigator.pop(context); _editPoi(poi, layer); },
          ),
          // ── Navigation ────────────────────────────────────────────────────
          // Fusionnée avec la navigation d'itinéraire (TripNavigationScreen) :
          // un POI devient un itinéraire à une seule étape, ce qui donne accès
          // gratuitement à la simulation GPS, aux alertes radar et aux
          // panneaux de limitation de vitesse — auparavant absents du
          // panneau de navigation POI, qui dupliquait sa propre logique de
          // route (voir MIGRATION_NOTES.md).
          ListTile(
            leading: Icon(Icons.turn_right, color: Colors.blue.shade300),
            title: const Text('🧭 Naviguer vers ce POI'),
            subtitle: (_userLat == null || _userLon == null)
                ? Text(LocationService.isSupported
                    ? 'Activez le GPS ou définissez une position manuelle'
                    : 'Définissez votre position de départ (bouton orange)',
                    style: const TextStyle(fontSize: 11, color: Colors.orange))
                : Text(
                    '${NavigationService.distanceM(LatLng(_userLat!, _userLon!), LatLng(poi.lat, poi.lon)).toStringAsFixed(0)} m'
                    '${_manualPositionMode ? " (position manuelle)" : ""}',
                    style: const TextStyle(fontSize: 11)),
            onTap: () async {
              Navigator.pop(context);
              if (_userLat == null || _userLon == null) {
                // Le dialogue permet de rechercher une adresse ou de saisir
                // des coordonnées — on enchaîne directement sur la
                // navigation dès qu'une position est validée, plutôt que de
                // forcer l'utilisateur à retoucher "Naviguer" une seconde
                // fois après avoir choisi son point de départ.
                await _showManualPositionDialog();
                if (_userLat == null || _userLon == null) return; // annulé
              }
              final trip = RouteTrip(steps: [TripStep.fromPoi(poi)]);
              await Navigator.push(context, MaterialPageRoute(
                builder: (_) => TripNavigationScreen(
                  trip: trip,
                  initialPosition: LatLng(_userLat!, _userLon!),
                  profile: 'driving',
                  positionNotifier: _positionNotifier,
                  headingNotifier: _headingNotifier,
                ),
              ));
              if (mounted) setState(() {});
            },
          ),
          // ── Trait compass ──────────────────────────────────────────────────
          ListTile(
            leading: Icon(
              _compassTarget == poi ? Icons.gps_off : Icons.social_distance,
              color: Colors.amber.shade700),
            title: Text(_compassTarget == poi
                ? 'Supprimer le trait GPS'
                : 'Tracer un trait vers ma position'),
            subtitle: (_userLat == null || _userLon == null)
                ? const Text('GPS non actif — activez la localisation',
                    style: TextStyle(fontSize: 11, color: Colors.red))
                : _compassTarget == poi
                    ? const Text('Tap sur le marqueur doré pour retirer',
                        style: TextStyle(fontSize: 11))
                    : Text(
                        '${_distM(poi.lat, poi.lon, _userLat!, _userLon!).toStringAsFixed(0)} m',
                        style: const TextStyle(fontSize: 11)),
            onTap: () {
              Navigator.pop(context);
              setState(() => _compassTarget = _compassTarget == poi ? null : poi);
            },
          ),
          ListTile(
            leading: Icon(Icons.visibility_off, color: Colors.orange.shade700),
            title: const Text('Masquer la couche'),
            onTap: () {
              Navigator.pop(context);
              setState(() => layer.visible = false);
            },
          ),
          ListTile(
            leading: const Icon(Icons.my_location, color: Colors.teal),
            title: const Text('Centrer la carte ici'),
            onTap: () {
              Navigator.pop(context);
              _mapController.move(
                LatLng(poi.lat, poi.lon), _currentZoom);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('Supprimer ce POI'),
            onTap: () {
              Navigator.pop(context);
              setState(() => layer.points.remove(poi));
            },
          ),
          const SizedBox(height: 8),
        ])),  // Column + SingleChildScrollView
      ),
    );
  }

  // ── Édition d'un POI ────────────────────────────────────────────────────────
  Future<void> _editPoi(PoiPoint poi, PoiLayer layer) async {
    final updated = await Navigator.push<PoiPoint>(
      context,
      MaterialPageRoute(builder: (_) =>
          PoiDetailScreen(poi: poi, color: layer.color)),
    );
    if (updated != null) {
      final idx = layer.points.indexOf(poi);
      if (idx >= 0) {
        setState(() => layer.points[idx] = updated);
      }
    }
  }

  // ── Dialogue paramètres zoom ──────────────────────────────────────────────
  void _showZoomSettings() {
    setState(() => _showZoomCfg = true);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final mapSize = Size(constraints.maxWidth,
          constraints.maxHeight - (widget.tracks.isNotEmpty ? 60 : 0));

      // Recalculer les offsets au niveau miniature
      if (_zoomLevel(_currentZoom) >= 2) {
        _computeThumbOffsets(mapSize);
      }

      return Column(children: [
        // ── Toolbar ──────────────────────────────────────────────────────
        Container(
          color: const Color(0xFF003580),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            const Icon(Icons.route, size: 16, color: Colors.white70),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                widget.tracks.length == 1
                    ? widget.tracks.first.displayName
                    : '${widget.tracks.length} tracés',
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Indicateur zoom courant
            GestureDetector(
              onTap: _showZoomSettings,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('z${_currentZoom.toStringAsFixed(1)}',
                      style: const TextStyle(color: Colors.white70, fontSize: 10)),
                  const SizedBox(width: 3),
                  const Icon(Icons.settings, size: 10, color: Colors.white54),
                ]),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.center_focus_strong,
                  color: Colors.white, size: 20),
              onPressed: () => _mapController.move(_center, _initZoom),
            ),
            IconButton(
              icon: Icon(_showTracks ? Icons.layers : Icons.layers_outlined,
                  color: Colors.white, size: 20),
              onPressed: () => setState(() => _showTracks = !_showTracks),
            ),
            IconButton(
              icon: Icon(_showStats ? Icons.bar_chart : Icons.bar_chart_outlined,
                  color: Colors.white, size: 20),
              onPressed: () => setState(() => _showStats = !_showStats),
            ),
            IconButton(
              icon: Icon(
                _showTouristPoi ? Icons.travel_explore : Icons.travel_explore_outlined,
                color: _showTouristPoi ? Colors.teal.shade200 : Colors.white,
                size: 20),
              tooltip: 'POI touristiques',
              onPressed: () => setState(() => _showTouristPoi = !_showTouristPoi),
            ),
          ]),
        ),

        // ── Carte ─────────────────────────────────────────────────────────
        Expanded(
          child: _MapWithLongPress(
            onLongPress: _onMapLongPress,
            mapController: _mapController,
            child: Stack(children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _center,
                initialZoom: _initZoom,
                minZoom: 3, maxZoom: 18,
                // Désactiver double-tap zoom pour éviter conflit avec nos actions
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.doubleTapZoom,
                ),
                onPositionChanged: (pos, hasGesture) {
                  if (hasGesture) _followLocation = false; // pan manuel = stop follow
                  final z = pos.zoom ?? _currentZoom;
                  final oldLvl  = _zoomLevel(_currentZoom);
                  final newLvl  = _zoomLevel(z);
                  final oldName = _currentZoom >= 9.0;
                  final newName = z >= 9.0;
                  _currentZoom = z;
                  // Recalculer offsets si on est au niveau miniature
                  if (newLvl >= 2) {
                    // Déclencher rebuild pour recalc offsets à la fin du frame
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() {});
                    });
                  } else if (newLvl != oldLvl || oldName != newName) {
                    setState(() {});
                  }
                },
                // onLongPress natif flutter_map — seul callback qui fonctionne
                onLongPress: (tapPos, latLng) {
                  debugPrint('MAP onLongPress fired: \$latLng');
                  _onMapLongPress(latLng);
                },
              ),
              children: [
                const AppMapLayer(),
                // ── Couche position utilisateur ──
                if (_userLat != null && _userLon != null) ...[
                  // Cercle de précision
                  CircleLayer(circles: [
                    CircleMarker(
                      point: LatLng(_userLat!, _userLon!),
                      radius: 24, useRadiusInMeter: false,
                      color: Colors.blue.withOpacity(0.15),
                      borderColor: Colors.blue.withOpacity(0.4),
                      borderStrokeWidth: 1.5,
                    ),
                  ]),
                  // Marqueur avec orientation
                  MarkerLayer(markers: [
                    Marker(
                      point: LatLng(_userLat!, _userLon!),
                      width: 36, height: 36,
                      child: _UserLocationMarker(heading: _userHeading),
                    ),
                  ]),
                ],
                // ── Trait GPS → POI cible ──
                if (_compassTarget != null && _userLat != null && _userLon != null) ...[
                  PolylineLayer<Object>(polylines: [
                    Polyline(
                      points: [
                        LatLng(_userLat!, _userLon!),
                        LatLng(_compassTarget!.lat, _compassTarget!.lon),
                      ],
                      strokeWidth: 2.5,
                      color: Colors.amber.withOpacity(.85),
                      strokeCap: StrokeCap.round,
                    ),
                  ]),
                  MarkerLayer(markers: [
                    Marker(
                      point: LatLng(_compassTarget!.lat, _compassTarget!.lon),
                      width: 36, height: 36,
                      child: GestureDetector(
                        onTap: () => setState(() => _compassTarget = null),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.amber,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: [BoxShadow(color: Colors.amber.withOpacity(.5),
                                blurRadius: 8, spreadRadius: 2)]),
                          child: const Icon(Icons.my_location, size: 18, color: Colors.black),
                        ),
                      ),
                    ),
                  ]),
                ],
                PolylineLayer(polylines: [
                  for (final t in widget.tracks)
                    if (t.visible && t.data.trackPoints.isNotEmpty) ...[
                      Polyline(
                        points: t.data.trackPoints
                            .map((p) => LatLng(p.lat, p.lon)).toList(),
                        strokeWidth: 6.0,
                        color: Colors.black.withOpacity(0.18),
                      ),
                      Polyline(
                        points: t.data.trackPoints
                            .map((p) => LatLng(p.lat, p.lon)).toList(),
                        strokeWidth: 3.5,
                        color: t.color.withOpacity(0.88),
                      ),
                    ],
                ]),
                // ── Radars (info statique, si activée) ──
                if (_radarCtrl.layerEnabled)
                  SpeedCameraMarkerLayer(cameras: _radarCtrl.cameras),

                // ── Limites de vitesse (info statique, si activée) ──
                if (_speedLimitCtrl.layerEnabled)
                  SpeedLimitMapLayer(segments: _speedLimitCtrl.segments),

                // Marqueurs GPX
                MarkerLayer(markers: [
                  if (_mapProfileCursor != null)
                    Marker(point: _mapProfileCursor!, width: 22, height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.amber, shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
                        ),
                      )),
                  for (final t in widget.tracks)
                    if (t.visible && t.data.trackPoints.isNotEmpty) ...[
                      _gpxMarker(LatLng(t.data.trackPoints.first.lat,
                          t.data.trackPoints.first.lon), t.color, '▶'),
                      if (t.data.trackPoints.length > 1)
                        _gpxMarker(LatLng(t.data.trackPoints.last.lat,
                            t.data.trackPoints.last.lon), t.color, '■'),
                      for (final wp in t.data.waypoints)
                        _gpxMarker(LatLng(wp.lat, wp.lon),
                            Colors.orange, wp.name ?? '•'),
                    ],
                ]),
                // Marqueurs POI adaptatifs avec long-press + double-tap
                MarkerLayer(
                  markers: _allVisiblePoi.map((e) => _adaptivePoiMarker(
                    e.poi, e.color, e.layer, _currentZoom,
                  )).toList(),
                ),
                // Marqueurs POI touristiques Overpass
                // Taille FIXE 28×28 — rond ancré sur les coordonnées GPS
                // Nom affiché via Stack overflow (ne déplace pas l'ancre)
                if (_showTouristPoi && _touristResults.isNotEmpty)
                  MarkerLayer(
                    markers: _touristResults.asMap().entries.map((e) {
                      final i     = e.key;
                      final r     = e.value;
                      final added = _touristAdded.contains(i);
                      final cat   = _categories.firstWhere(
                        (c) => c.id == r.categoryId,
                        orElse: () => _categories.first);
                      // Seuil nom plus bas : dès zoom 9
                      final showName = _currentZoom >= 9.0;
                      const dotSize  = 28.0;
                      return Marker(
                        point: LatLng(r.lat, r.lon),
                        width: dotSize,
                        height: dotSize,
                        // Pas d'alignment → centre par défaut = ancre GPS fixe
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTap: () => _addOverpassPoi(i),
                          onLongPress: () => _showOverpassContextMenu(i),
                          child: Stack(clipBehavior: Clip.none, children: [
                            // Rond centré = ancre GPS
                            Container(
                              width: dotSize, height: dotSize,
                              decoration: BoxDecoration(
                                color: added ? Colors.grey.shade400 : cat.color,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                                boxShadow: [BoxShadow(
                                  color: cat.color.withOpacity(0.4), blurRadius: 3)],
                              ),
                              child: Center(child: Text(r.emoji,
                                  style: const TextStyle(fontSize: 13))),
                            ),
                            // Étiquette nom à droite — déborde hors du Marker
                            if (showName)
                              Positioned(
                                left: dotSize + 2,
                                top: 5,
                                child: Container(
                                  constraints: const BoxConstraints(maxWidth: 120),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: (added ? Colors.grey.shade400 : cat.color)
                                        .withOpacity(0.88),
                                    borderRadius: BorderRadius.circular(4),
                                    boxShadow: const [BoxShadow(
                                        color: Colors.black26, blurRadius: 2)],
                                  ),
                                  child: Text(r.name,
                                    style: const TextStyle(
                                      fontSize: 9, color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                ),
                              ),
                          ]),
                        ),
                      );
                    }).toList(),
                  ),
              ],
            ),

            // Panneau couches
            if (_showTracks)
              Positioned(top: 8, right: 8, left: 8,
                child: LayersPanel(
                  key: ValueKey('layers_${widget.tracks.length}_${widget.poiLayers.length}_${widget.poiFolders.length}'),
                  tracks: widget.tracks,
                  poiLayers: widget.poiLayers,
                  poiFolders: widget.poiFolders,
                  onChanged: () => setState(() {}),
                  onPoiMenu: (ctx, poi, layer) => _showPoiContextMenu(ctx, poi, layer),
                  onShowMapProfile: (t) => setState(() {
                    _mapProfileTrack  = (_mapProfileTrack == t) ? null : t;
                    _mapProfileCursor = null;
                    _showTracks = false; // replier le panneau pour voir le profil
                  }),
                ),
              ),

            // Panneau POI touristiques
            if (_showTouristPoi)
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 420),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(12)),
                    boxShadow: const [BoxShadow(
                        color: Colors.black26, blurRadius: 8)],
                  ),
                  child: AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.bottomCenter,
                  child: TouristPoiOverlay(
                    mapController: _mapController,
                    poiLayers: widget.poiLayers,
                    categories: _categories,
                    onLayerAdded: (_) { setState(() {}); widget.onChanged?.call(); },
                    onClose: () => setState(() {
                      _showTouristPoi = false;
                      _touristResults = [];
                      _touristAdded.clear();
                    }),
                    onResultsChanged: (results) => setState(() {
                      _touristResults = results;
                      _touristAdded.clear();
                    }),
                  ),
                ),
                ),
              ),

            // Panneau réglages zoom POI
            if (_showZoomCfg)
              Positioned(bottom: 8, left: 8, right: 8,
                child: _ZoomSettingsPanel(
                  settings: _zoomSettings,
                  currentZoom: _currentZoom,
                  onChanged: () => setState(() {}),
                  onClose: () => setState(() => _showZoomCfg = false),
                ),
              ),

            // Légende zoom
            if (!_showZoomCfg)
              Positioned(bottom: 4, right: 4,
                child: GestureDetector(
                  onTap: _showZoomSettings,
                  child: _zoomLegend(),
                ),
              ),

            // ── Profil altimétrique 2D (incrusté sur la carte) ──
            if (_mapProfileTrack != null &&
                widget.tracks.contains(_mapProfileTrack))
              Positioned(left: 0, right: 0, bottom: 0,
                child: RouteElevationProfile(
                  points: _mapProfileTrack!.data.trackPoints,
                  onScrub: (pos) => setState(() => _mapProfileCursor = pos),
                  onScrubEnd: () {},
                  onClose: () => setState(() {
                    _mapProfileTrack  = null;
                    _mapProfileCursor = null;
                  }),
                )),

            // ── Boutons GPS (Android/iOS) ou position manuelle (Windows/sans signal) ──
            Positioned(bottom: 56, right: 8,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Orientation carte (Nord / Cap / Vue globale)
                MapOrientationButton(
                  mode: _orientCtrl.mode,
                  onTap: _cycleOrientation,
                ),
                const SizedBox(height: 6),
                if (LocationService.isSupported) ...[
                  _mapFab(
                    icon: _locationActive ? Icons.gps_fixed : Icons.gps_not_fixed,
                    color: _locationActive
                        ? (_manualPositionMode
                            ? Colors.orange
                            : (_followLocation ? Colors.blue : Colors.green))
                        : Colors.grey.shade700,
                    tooltip: _locationActive
                        ? (_manualPositionMode ? 'Position manuelle active' : 'Désactiver GPS')
                        : 'Activer GPS',
                    onTap: _toggleLocation,
                  ),
                  if (_locationActive && _userLat != null) ...[
                    const SizedBox(height: 6),
                    _mapFab(
                      icon: Icons.my_location,
                      color: Colors.blue,
                      tooltip: 'Recentrer sur ma position',
                      onTap: _centerOnUser,
                    ),
                  ],
                ],
                // Position manuelle — toujours disponible (Windows ou GPS hors signal)
                const SizedBox(height: 6),
                _mapFab(
                  icon: _manualPositionMode ? Icons.edit_location_alt : Icons.location_searching,
                  color: _manualPositionMode ? Colors.orange : Colors.grey.shade600,
                  tooltip: _manualPositionMode
                      ? 'Position manuelle active — modifier'
                      : LocationService.isSupported
                          ? 'Définir ma position manuellement (si pas de signal)'
                          : 'Définir ma position (navigation sans GPS — Windows)',
                  onTap: _showManualPositionDialog,
                ),
              ]),
            ),

            // Bandeau d'info si position manuelle active
            if (_manualPositionMode)
              Positioned(top: 8, left: 8, right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(.9),
                    borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    const Icon(Icons.edit_location_alt, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    const Expanded(child: Text(
                        'Position manuelle (pas de GPS réel) — navigation simulée',
                        style: TextStyle(color: Colors.white, fontSize: 11))),
                    GestureDetector(
                      onTap: _clearManualPosition,
                      child: const Icon(Icons.close, size: 16, color: Colors.white)),
                  ]),
                ),
              ),

            // ── Bouton pré-chargement tuiles ──
            Positioned(bottom: 56, left: 8,
              child: _mapFab(
                icon: Icons.download_for_offline_outlined,
                color: Colors.teal,
                tooltip: 'Pré-charger des cartes hors-ligne',
                onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => TileCacheScreen(
                    initialCenter: _userLat != null
                        ? LatLng(_userLat!, _userLon!)
                        : null,
                  ),
                )),
              ),
            ),

            // ── Bouton radars ──
            Positioned(bottom: 112, left: 8,
              child: _mapFab(
                icon: Icons.camera_alt,
                color: _radarCtrl.layerEnabled
                    ? (_radarCtrl.alertEnabled ? Colors.red : Colors.orange)
                    : Colors.grey.shade600,
                tooltip: 'Paramètres radars',
                onTap: () async {
                  // Charger les radars de la zone visible si besoin
                  if (_radarCtrl.cameras.isEmpty) {
                    final b = _mapController.camera.visibleBounds;
                    _radarCtrl.loadCamerasInBbox(
                        b.south, b.north, b.west, b.east);
                  }
                  await showDialog(context: context, builder: (_) =>
                      SpeedCameraSettingsDialog(
                        controller: _radarCtrl,
                        currentPosition: (_userLat != null && _userLon != null)
                            ? LatLng(_userLat!, _userLon!) : null,
                      ));
                },
              ),
            ),

            // ── Bouton itinéraire multi-étapes ──
            Positioned(bottom: 168, left: 8,
              child: GestureDetector(
                onLongPress: _quickLoadTrip,
                child: _mapFab(
                  icon: Icons.route,
                  color: _activeTrip != null ? Colors.amber : Colors.indigo,
                  tooltip: 'Itinéraire multi-étapes (appui long : itinéraires sauvegardés)',
                  onTap: _openTripEditor,
                ),
              ),
            ),

            // ── Bouton limites de vitesse ──
            Positioned(bottom: 224, left: 8,
              child: _mapFab(
                icon: Icons.speed,
                color: _speedLimitCtrl.layerEnabled ? Colors.orange : Colors.grey.shade600,
                tooltip: 'Limitations de vitesse',
                onTap: () async {
                  if (_speedLimitCtrl.segments.isEmpty) {
                    final b = _mapController.camera.visibleBounds;
                    final segs = await SpeedLimitService.fetchInBbox(
                        b.south, b.north, b.west, b.east);
                    _speedLimitCtrl.setSegments(segs);
                  }
                  await showDialog(context: context, builder: (_) =>
                      SpeedLimitSettingsDialog(controller: _speedLimitCtrl));
                },
              ),
            ),

            // ── Panneau limite de vitesse dynamique (façon panneau routier) ──
            if (_speedLimitCtrl.current?.maxSpeedKmh != null && _locationActive)
              Positioned(top: _manualPositionMode ? 48 : 8, right: 8,
                child: SpeedLimitSign(maxSpeedKmh: _speedLimitCtrl.current!.maxSpeedKmh)),

            // ── Bandeau alerte radar active ──
            if (_activeRadarAlert != null)
              Positioned(top: 8, left: 8, right: 8,
                child: SpeedCameraAlertBanner(
                  camera: _activeRadarAlert!,
                  distanceM: _activeRadarDist,
                  onDismiss: () => setState(() => _activeRadarAlert = null),
                )),

          ]),
          ),  // fin _MapWithLongPress
        ),

        if (_showStats) _buildStats(),
        _buildLegend(),
      ]);
    });
  }

  // ── Marqueur POI adaptatif + appui long ───────────────────────────────────
  static const double _dotSize = 12.0;

  Marker _adaptivePoiMarker(
      PoiPoint poi, Color color, PoiLayer layer, double zoom) {
    final bool showLabel = zoom >= _zoomSettings.zoomLabel;
    final bool showThumb = zoom >= _zoomSettings.zoomThumb;
    final bool hasPhoto  = poi.localPhotos.isNotEmpty || poi.photoUrls.isNotEmpty;
    final double thumbSize = zoom >= 15.0 ? 60.0 : 48.0;
    final Offset thumbShift = _thumbOffsets[poi.hashCode] ?? Offset.zero;

    // Zone tactile élargie autour du rond (44px minimum recommandé Material)
    const double tapSize = 44.0;
    const double offset  = (tapSize - _dotSize) / 2;

    return Marker(
      point: LatLng(poi.lat, poi.lon),
      width: tapSize,
      height: tapSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap:  () => _editPoi(poi, layer),
        onLongPress:  () => _showPoiContextMenu(context, poi, layer),
        child: Stack(clipBehavior: Clip.none, children: [

          // ── Zone tactile transparente (44×44) ─────────────────────────
          Positioned.fill(child: Container(color: Colors.transparent)),

          // ── Rond GPS centré dans la zone tactile ──────────────────────
          Positioned(
            left: offset, top: offset,
            child: Container(
              width: _dotSize, height: _dotSize,
              decoration: BoxDecoration(
                color: color, shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 3)],
              ),
            ),
          ),

          // ── Miniature avec décalage anti-recouvrement ──────────────────
          if (showThumb && hasPhoto) ...[
            // Centre du rond (dans le repère du Marker 44×44)
            // = offset + dotSize/2 depuis le coin haut-gauche
            // Centre de la miniature = thumbShift + thumbSize/2 horizontalement
            //                       = -(au-dessus du rond) + thumbSize/2 verticalement
            // Trait du centre du rond au centre de la miniature
            Positioned(
              left: 0, top: 0,
              child: CustomPaint(
                // Canvas couvre toute la zone débordante possible
                size: Size(
                  (offset + _dotSize/2 + thumbShift.dx.abs() + thumbSize).abs() + tapSize,
                  (offset + _dotSize/2 + thumbShift.dy.abs() + thumbSize).abs() + tapSize,
                ),
                painter: _LinePainter(
                  // Départ : centre du rond dans le repère élargi
                  from: Offset(offset + _dotSize/2, offset + _dotSize/2),
                  // Arrivée : centre de la miniature
                  to: Offset(
                    offset + thumbShift.dx + thumbSize / 2,
                    // bottom= tapSize-offset+2-thumbShift.dy → top= offset-2+thumbShift.dy-thumbSize/2
                    offset - 2 + thumbShift.dy - thumbSize / 2,
                  ),
                  color: color,
                ),
              ),
            ),
            Positioned(
              left:   offset + thumbShift.dx,
              bottom: (tapSize - offset) + 2 - thumbShift.dy,
              child: Container(
                width: thumbSize, height: thumbSize,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: color, width: 2),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildThumb(poi, thumbSize),
              ),
            ),
          ],

          // ── Étiquette nom (à droite du rond, par rapport au centre de la zone tactile) ──
          if (showLabel)
            Positioned(
              left: offset + _dotSize + 4,
              top:  offset - 1,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 140),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_typeEmoji(poi.type),
                      style: const TextStyle(fontSize: 9)),
                  const SizedBox(width: 2),
                  Flexible(child: Text(poi.name,
                    style: const TextStyle(fontSize: 10,
                        fontWeight: FontWeight.bold, color: Colors.white),
                    overflow: TextOverflow.ellipsis, maxLines: 1,
                  )),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _buildThumb(PoiPoint poi, double size) {
    if (poi.localPhotos.isNotEmpty) {
      return Image.file(File(poi.localPhotos.first),
        fit: BoxFit.cover, width: size, height: size,
        errorBuilder: (_, __, ___) => _thumbFallback(poi));
    }
    if (poi.photoUrls.isNotEmpty) {
      return Image.network(poi.photoUrls.first,
        fit: BoxFit.cover, width: size, height: size,
        errorBuilder: (_, __, ___) => _thumbFallback(poi));
    }
    return _thumbFallback(poi);
  }

  Widget _thumbFallback(PoiPoint poi) => Container(
    color: Colors.grey.shade200,
    child: Center(child: Text(_typeEmoji(poi.type),
        style: const TextStyle(fontSize: 20))),
  );

  String _typeEmoji(String? type) {
    const map = {
      'hotel': '🏨', 'restaurant': '🍽️', 'monument': '🏛️',
      'peak': '⛰️',  'waterfall': '💧',  'castle': '🏰',
      'museum': '🖼️','village': '🏘️',   'city': '🏙️',
      'chapel': '⛪', 'parking': '🅿️',   'fuel': '⛽',
      'lake': '🌊',   'forest': '🌲',
    };
    return map[type] ?? '📍';
  }

  Marker _gpxMarker(LatLng pt, Color color, String label) => Marker(
    point: pt, width: 20, height: 20,
    child: Container(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [BoxShadow(color: color.withOpacity(0.4), blurRadius: 3)]),
      child: Center(child: Text(label,
          style: const TextStyle(fontSize: 8, color: Colors.white))),
    ),
  );

  Widget _zoomLegend() {
    String hint; IconData icon;
    if (_currentZoom >= _zoomSettings.zoomThumb) {
      hint = 'Photos'; icon = Icons.photo;
    } else if (_currentZoom >= _zoomSettings.zoomLabel) {
      hint = 'Noms'; icon = Icons.label;
    } else {
      hint = 'Points'; icon = Icons.circle;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(color: Colors.black54,
          borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 10, color: Colors.white),
        const SizedBox(width: 3),
        Text(hint, style: const TextStyle(color: Colors.white, fontSize: 9)),
        const SizedBox(width: 3),
        const Icon(Icons.settings, size: 9, color: Colors.white54),
      ]),
    );
  }

  Widget _buildStats() {
    final visible = widget.tracks.where((t) => t.visible).toList();
    final allPoi  = _allVisiblePoi.length;
    double totalKm = 0; double? minEle, maxEle; int totalPts = 0;
    for (final t in visible) {
      totalPts += t.data.trackPoints.length;
      totalKm  += _distKm(t);
      for (final p in t.data.trackPoints) {
        if (p.ele == null || !p.ele!.isFinite) continue;
        minEle = minEle == null ? p.ele : (p.ele! < minEle ? p.ele : minEle);
        maxEle = maxEle == null ? p.ele : (p.ele! > maxEle ? p.ele : maxEle);
      }
    }
    return Container(
      color: Colors.blue.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Wrap(spacing: 16, runSpacing: 2, children: [
        _stat('📍', '$totalPts pts'),
        _stat('📏', '${totalKm.toStringAsFixed(1)} km'),
        if (minEle != null && maxEle != null && minEle.isFinite && maxEle.isFinite)
          _stat('⛰️', '${minEle.toInt()}–${maxEle.toInt()} m'),
        if (visible.isNotEmpty)
          _stat('🗺️', '${visible.length} tracé${visible.length > 1 ? "s" : ""}'),
        if (allPoi > 0) _stat('📌', '$allPoi POI'),
      ]),
    );
  }

  double _distKm(GpxTrack t) {
    const d = Distance();
    double total = 0;
    final pts = t.data.trackPoints;
    for (int i = 1; i < pts.length; i++) {
      total += d(LatLng(pts[i-1].lat, pts[i-1].lon),
                 LatLng(pts[i].lat,   pts[i].lon));
    }
    return total / 1000;
  }

  Widget _buildLegend() => Container(
    color: Colors.white,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    child: Row(children: [
      Expanded(child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          ...widget.tracks.map((t) => Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 18, height: 3, color: t.color),
              const SizedBox(width: 4),
              Text(t.displayName, style: const TextStyle(fontSize: 10),
                  overflow: TextOverflow.ellipsis),
            ]),
          )),
          if (_allVisiblePoi.isNotEmpty)
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.location_on, size: 12, color: Colors.grey),
              const SizedBox(width: 2),
              Text('${_allVisiblePoi.length} POI',
                  style: const TextStyle(fontSize: 10)),
            ]),
        ]),
      )),
      Text('© OSM', style: TextStyle(fontSize: 9, color: Colors.grey.shade400)),
    ]),
  );

  Widget _stat(String icon, String val) =>
    Row(mainAxisSize: MainAxisSize.min, children: [
      Text(icon, style: const TextStyle(fontSize: 12)),
      const SizedBox(width: 3),
      Text(val, style: TextStyle(fontSize: 11,
          fontWeight: FontWeight.w500, color: Colors.blue.shade800)),
    ]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Painter pour le trait de liaison miniature ↔ point GPS
// ─────────────────────────────────────────────────────────────────────────────
class _LinePainter extends CustomPainter {
  final Offset from, to;
  final Color  color;
  const _LinePainter({required this.from, required this.to, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(from, to,
      Paint()
        ..color = color.withOpacity(0.7)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.from != from || old.to != to || old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// Panneau de réglage des seuils de zoom
// ─────────────────────────────────────────────────────────────────────────────
class _ZoomSettingsPanel extends StatefulWidget {
  final PoiZoomSettings settings;
  final double          currentZoom;
  final VoidCallback    onChanged;
  final VoidCallback    onClose;

  const _ZoomSettingsPanel({
    required this.settings,
    required this.currentZoom,
    required this.onChanged,
    required this.onClose,
  });

  @override
  State<_ZoomSettingsPanel> createState() => _ZoomSettingsPanelState();
}

class _ZoomSettingsPanelState extends State<_ZoomSettingsPanel> {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(Icons.tune, size: 16, color: Color(0xFF003580)),
          const SizedBox(width: 6),
          const Expanded(child: Text('Seuils d\'affichage POI',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: widget.onClose,
            padding: EdgeInsets.zero, constraints: const BoxConstraints(),
          ),
        ]),
        const SizedBox(height: 8),

        // Seuil label
        _sliderRow(
          icon: Icons.label,
          label: 'Noms visibles',
          color: Colors.indigo,
          value: widget.settings.zoomLabel,
          min: 5, max: 18,
          currentZoom: widget.currentZoom,
          onChanged: (v) {
            widget.settings.zoomLabel = v;
            // Décorrélé : pas de forçage sur zoomThumb
            widget.onChanged(); setState(() {});
          },
        ),
        const SizedBox(height: 6),

        // Seuil miniature
        _sliderRow(
          icon: Icons.photo,
          label: 'Miniatures visibles',
          color: Colors.teal,
          value: widget.settings.zoomThumb,
          min: 5, max: 18,
          currentZoom: widget.currentZoom,
          onChanged: (v) {
            widget.settings.zoomThumb = v;
            // Décorrélé : pas de forçage sur zoomLabel
            widget.onChanged(); setState(() {});
          },
        ),
        const SizedBox(height: 8),

        // Boutons "appliquer zoom actuel" — indépendants
        Row(children: [
          Expanded(child: OutlinedButton.icon(
            icon: const Icon(Icons.label, size: 14, color: Colors.indigo),
            label: Text('Noms à z=${widget.currentZoom.toStringAsFixed(1)}',
                style: const TextStyle(fontSize: 11, color: Colors.indigo)),
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.indigo)),
            onPressed: () {
              widget.settings.zoomLabel =
                  double.parse(widget.currentZoom.toStringAsFixed(1));
              widget.onChanged(); setState(() {});
            },
          )),
          const SizedBox(width: 6),
          Expanded(child: OutlinedButton.icon(
            icon: const Icon(Icons.photo, size: 14, color: Colors.teal),
            label: Text('Photos à z=${widget.currentZoom.toStringAsFixed(1)}',
                style: const TextStyle(fontSize: 11, color: Colors.teal)),
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.teal)),
            onPressed: () {
              widget.settings.zoomThumb =
                  double.parse(widget.currentZoom.toStringAsFixed(1));
              widget.onChanged(); setState(() {});
            },
          )),
        ]),
      ]),
    );
  }

  Widget _sliderRow({
    required IconData icon, required String label,
    required double value, required double min, required double max,
    required double currentZoom, required ValueChanged<double> onChanged,
    Color color = Colors.blue,
  }) {
    final active = currentZoom >= value;
    final c = active ? color : Colors.grey;
    return Row(children: [
      Icon(icon, size: 14, color: c),
      const SizedBox(width: 6),
      SizedBox(width: 104,
        child: Text(label,
            style: TextStyle(fontSize: 11, color: c))),
      Expanded(child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: color,
          thumbColor: color,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        ),
        child: Slider(
          value: value, min: min, max: max,
          divisions: ((max - min) * 2).round(),
          onChanged: onChanged,
        ),
      )),
      Container(
        width: 36,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.1) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text('z${value.toStringAsFixed(1)}',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
                color: c)),
      ),
    ]);
  }
}

class _MapWithLongPress extends StatefulWidget {
  final Widget child;
  final MapController mapController;
  final void Function(LatLng) onLongPress;

  const _MapWithLongPress({
    required this.child,
    required this.mapController,
    required this.onLongPress,
  });

  @override
  State<_MapWithLongPress> createState() => _MapWithLongPressState();
}

class _MapWithLongPressState extends State<_MapWithLongPress> {
  Offset? _pointerDown;
  DateTime? _downTime;
  bool _fired = false;

  static const _longPressDuration = Duration(milliseconds: 600);
  static const _moveThreshold = 10.0; // px

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        _pointerDown = e.localPosition;
        _downTime = DateTime.now();
        _fired = false;
        // Déclencher après 600ms si pas de mouvement
        Future.delayed(_longPressDuration, () {
          if (!mounted || _fired) return;
          if (_pointerDown == null) return;
          final elapsed = DateTime.now().difference(_downTime!);
          if (elapsed >= _longPressDuration) {
            _fired = true;
            _convertAndFire(_pointerDown!);
          }
        });
      },
      onPointerMove: (e) {
        if (_pointerDown == null) return;
        final delta = (e.localPosition - _pointerDown!).distance;
        if (delta > _moveThreshold) {
          // Mouvement détecté → annuler le long press
          _pointerDown = null;
        }
      },
      onPointerUp:     (_) => _pointerDown = null,
      onPointerCancel: (_) => _pointerDown = null,
      child: widget.child,
    );
  }

  void _convertAndFire(Offset localPos) {
    try {
      final latLng = widget.mapController.camera.pointToLatLng(
        math.Point(localPos.dx, localPos.dy),
      );
      widget.onLongPress(latLng);
    } catch (e) {
      debugPrint('pointToLatLng error: $e');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Feuille de choix destination POI : dossiers + racine
// ─────────────────────────────────────────────────────────────────────────────
class _CreatePoiSheet extends StatefulWidget {
  final LatLng                               latLng;
  final List<PoiLayer>                       rootLayers;
  final List<PoiFolder>                      folders;
  final void Function(PoiPoint, PoiLayer)   onCreated;

  const _CreatePoiSheet({
    required this.latLng,
    required this.rootLayers,
    required this.folders,
    required this.onCreated,
  });

  @override
  State<_CreatePoiSheet> createState() => _CreatePoiSheetState();
}

class _CreatePoiSheetState extends State<_CreatePoiSheet> {
  PoiLayer? _selected;
  bool      _creatingNew  = false;
  String?   _newLayerName;
  PoiFolder? _newLayerFolder; // null = racine

  Color get _selectedColor => _selected?.color ?? poiColorForIndex(
      widget.rootLayers.length +
      widget.folders.fold(0, (s, f) => s + f.layers.length));

  Future<void> _proceed() async {
    PoiLayer layer;

    if (_creatingNew) {
      final name = _newLayerName?.trim() ?? 'Mes POI';
      layer = PoiLayer(
        label:  name,
        points: [],
        color:  _selectedColor,
      );
      if (_newLayerFolder != null) {
        _newLayerFolder!.layers.add(layer);
      } else {
        widget.rootLayers.add(layer);
      }
    } else if (_selected != null) {
      layer = _selected!;
    } else {
      // Créer une couche racine par défaut
      layer = PoiLayer(label: 'Mes POI', points: [], color: _selectedColor);
      widget.rootLayers.add(layer);
    }

    // Ouvrir l'édition du POI
    final newPoi = PoiPoint(
      name: 'Nouveau POI',
      lat: widget.latLng.latitude,
      lon: widget.latLng.longitude,
    );
    final edited = await Navigator.push<PoiPoint>(
      context,
      MaterialPageRoute(builder: (_) =>
          PoiDetailScreen(poi: newPoi, color: layer.color)),
    );
    if (edited == null || !mounted) return;
    widget.onCreated(edited, layer);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      // Poignée
      Container(
        width: 40, height: 4,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(2)),
      ),

      // En-tête
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          const Icon(Icons.add_location_alt, color: Colors.teal, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Créer un POI',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            Text(
              '${widget.latLng.latitude.toStringAsFixed(5)}, '
              '${widget.latLng.longitude.toStringAsFixed(5)}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ])),
        ]),
      ),
      const Divider(),

      // Liste des destinations
      Expanded(child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [

        // ── Couches racine ──────────────────────────────────────────────────
        if (widget.rootLayers.isNotEmpty) ...[
          _sectionLabel('📂 Sans dossier'),
          ...widget.rootLayers.map((l) => _layerTile(l, null)),
        ],

        // ── Dossiers ────────────────────────────────────────────────────────
        ...widget.folders.map((folder) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel('📁 ${folder.label}'),
            ...folder.layers.map((l) => _layerTile(l, folder)),
            // Nouvelle couche dans ce dossier
            _newLayerTile(folder),
          ],
        )),

        // ── Nouvelle couche à la racine ──────────────────────────────────────
        const Divider(),
        _newLayerTile(null),
      ])),

      // Bouton Suivant
      SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: (_selected != null || _creatingNew) ? _proceed : null,
          icon: const Icon(Icons.arrow_forward),
          label: const Text('Créer le POI ici'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 48)),
        ),
      )),
    ]);
  }

  Widget _layerTile(PoiLayer l, PoiFolder? folder) {
    final isSelected = _selected == l && !_creatingNew;
    return ListTile(
      dense: true,
      selected: isSelected,
      selectedTileColor: l.color.withOpacity(0.08),
      leading: Container(width: 14, height: 14,
        decoration: BoxDecoration(color: l.color, shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5))),
      title: Text(l.label, style: const TextStyle(fontSize: 13)),
      subtitle: Text('${l.points.length} POI',
          style: const TextStyle(fontSize: 10)),
      trailing: isSelected
          ? const Icon(Icons.check_circle, color: Colors.teal)
          : null,
      onTap: () => setState(() {
        _selected       = l;
        _creatingNew    = false;
        _newLayerName   = null;
        _newLayerFolder = folder;
      }),
    );
  }

  Widget _newLayerTile(PoiFolder? folder) {
    final isSelected = _creatingNew && _newLayerFolder?.id == folder?.id &&
        (folder == null) == (_newLayerFolder == null);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
        dense: true,
        selected: isSelected,
        selectedTileColor: Colors.blue.withOpacity(0.08),
        leading: Icon(Icons.add_circle_outline,
            color: isSelected ? Colors.blue : Colors.grey.shade500, size: 20),
        title: Text(
          folder == null
              ? 'Nouvelle couche (sans dossier)'
              : 'Nouvelle couche dans "${folder.label}"',
          style: TextStyle(fontSize: 13,
              color: isSelected ? Colors.blue : Colors.black87)),
        trailing: isSelected
            ? const Icon(Icons.check_circle, color: Colors.blue)
            : null,
        onTap: () => setState(() {
          _creatingNew    = true;
          _selected       = null;
          _newLayerFolder = folder;
          _newLayerName   = null;
        }),
      ),
      if (isSelected)
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Nom de la couche',
              isDense: true,
              border: OutlineInputBorder()),
            style: const TextStyle(fontSize: 13),
            onChanged: (v) => _newLayerName = v,
          ),
        ),
    ]);
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
    child: Text(text, style: TextStyle(
        fontSize: 11, fontWeight: FontWeight.bold,
        color: Colors.grey.shade600)),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper FAB compact pour la carte
// ─────────────────────────────────────────────────────────────────────────────
Widget _mapFab({required IconData icon, required Color color,
    required String tooltip, required VoidCallback onTap}) =>
  Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.white,
      elevation: 3,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 22, color: color),
        ),
      ),
    ),
  );

// ─────────────────────────────────────────────────────────────────────────────
// Marqueur de position utilisateur avec indicateur d'orientation
// ─────────────────────────────────────────────────────────────────────────────
class _UserLocationMarker extends StatelessWidget {
  final double? heading;
  const _UserLocationMarker({this.heading});

  @override
  Widget build(BuildContext context) {
    return Stack(alignment: Alignment.center, children: [
      // Cône d'orientation (si heading disponible)
      if (heading != null)
        Transform.rotate(
          angle: (heading! * 3.14159265358979 / 180),
          child: CustomPaint(
            size: const Size(36, 36),
            painter: _HeadingConePainter(),
          ),
        ),
      // Cercle central bleu
      Container(
        width: 16, height: 16,
        decoration: BoxDecoration(
          color: Colors.blue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
      ),
    ]);
  }
}

class _HeadingConePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final paint = Paint()
      ..color = Colors.blue.withOpacity(0.35)
      ..style = PaintingStyle.fill;
    // Qualifier explicitement dart:ui.Path pour éviter le conflit avec
    // flutter_map qui exporte Path<LatLng>
    final path = ui.Path();
    path.moveTo(cx, cy);
    path.lineTo(cx - 7, cy - 16);
    path.arcToPoint(Offset(cx + 7, cy - 16),
        radius: const Radius.circular(8), clockwise: true);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HeadingConePainter old) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers de détection de doublons (distance + similarité de nom)
// ─────────────────────────────────────────────────────────────────────────────

/// Distance approx entre deux coords GPS en mètres
double _distM(double lat1, double lon1, double lat2, double lon2) {
  final dlat = (lat2 - lat1) * 111320;
  final dlon = (lon2 - lon1) * 111320 * _cosApprox(lat1 * 3.14159 / 180);
  final sq = dlat * dlat + dlon * dlon;
  return sq <= 0 ? 0 : _sqrtApprox(sq);
}

double _cosApprox(double x) {
  double r = 1, t = 1;
  for (int i = 1; i <= 8; i++) { t *= -x * x / (2 * i * (2 * i - 1)); r += t; }
  return r;
}

double _sqrtApprox(double x) {
  if (x <= 0) return 0;
  double s = x / 2;
  for (int i = 0; i < 20; i++) s = (s + x / s) / 2;
  return s;
}

/// Similarité de noms (coefficient de Dice sur bigrammes), 0..1
double _nameSim(String a, String b) {
  final na = a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final nb = b.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 1.0;
  Set<String> bigrams(String s) {
    final set = <String>{};
    for (int i = 0; i < s.length - 1; i++) set.add(s.substring(i, i + 2));
    return set;
  }
  final ba = bigrams(na), bb = bigrams(nb);
  final common = ba.intersection(bb).length;
  if (ba.length + bb.length == 0) return 0;
  return 2 * common / (ba.length + bb.length);
}
