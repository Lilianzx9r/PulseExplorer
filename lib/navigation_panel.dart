import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'navigation_service.dart';
import 'core/services/map_camera_utils.dart';
import 'poi_layer.dart';
import 'tile_cache_screen.dart';
import 'map_orientation_button.dart';
import 'route_options.dart';
import 'route_picker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// navigation_panel.dart
//
// Panneau de navigation compact (sur la carte) + écran plein écran.
// ─────────────────────────────────────────────────────────────────────────────

/// Panel compact flottant sur la carte principale.
/// À placer dans un [Stack] par-dessus la FlutterMap.
class NavigationPanel extends StatefulWidget {
  final PoiPoint   target;
  final LatLng     userPosition;
  final double?    userHeading;
  final VoidCallback onClose;
  /// Notifier optionnel pour que NavigationScreen reçoive les positions live
  final ValueNotifier<LatLng>? positionNotifier;
  final ValueNotifier<double?>? headingNotifier;
  /// Appelé à chaque (re)calcul d'itinéraire (hors-ligne ou OSRM) — permet à
  /// l'appelant de récupérer la géométrie sans la recalculer lui-même (voir
  /// MIGRATION_NOTES.md : ceci remplace l'appel séparé et redondant que
  /// gpx_only_view.dart faisait à NavigationService.smartRoute pour nourrir
  /// le simulateur GPS).
  final ValueChanged<NavRoute>? onRouteComputed;

  const NavigationPanel({
    super.key,
    required this.target,
    required this.userPosition,
    required this.onClose,
    this.userHeading,
    this.positionNotifier,
    this.headingNotifier,
    this.onRouteComputed,
  });

  @override
  State<NavigationPanel> createState() => _NavigationPanelState();
}

class _NavigationPanelState extends State<NavigationPanel> {
  NavRoute? _route;
  bool _loading = false;
  String _profile = 'walking'; // walking | driving | cycling
  bool _isOfflineMode = true;
  RouteOptions _routeOptions = const RouteOptions();

  @override
  void initState() {
    super.initState();
    _computeRoute();
  }

  // Position utilisée pour le dernier calcul OSRM (évite les appels trop fréquents)
  LatLng? _lastOsrmPos;

  @override
  void didUpdateWidget(NavigationPanel old) {
    super.didUpdateWidget(old);
    // Rafraîchir OSRM seulement si déplacement > 50m depuis dernier calcul
    final moved = _lastOsrmPos == null
        ? true
        : NavigationService.distanceM(_lastOsrmPos!, widget.userPosition) > 50;
    if (moved && !_loading) _fetchOsrmRoute();
    // La boussole et la distance se mettent à jour automatiquement via build()
  }

  /// Met à jour la route affichée ET notifie l'appelant (voir
  /// widget.onRouteComputed) — point unique de mise à jour pour éviter
  /// qu'un appelant externe ait besoin de recalculer la même route.
  void _setRoute(NavRoute route, {required bool offline}) {
    if (!mounted) return;
    setState(() { _route = route; _isOfflineMode = offline; });
    widget.onRouteComputed?.call(route);
  }

  Future<void> _computeRoute() async {
    // Ligne droite immédiate (hors-ligne, toujours disponible)
    final offline = NavigationService.straightLine(
        widget.userPosition,
        LatLng(widget.target.lat, widget.target.lon),
        widget.target.name);
    // Ne pas écraser une route OSRM existante — juste initialiser
    if (_route == null) _setRoute(offline, offline: true);
    _fetchOsrmRoute();
  }

  Future<void> _fetchOsrmRoute() async {
    if (_loading) return;
    setState(() => _loading = true);
    _lastOsrmPos = widget.userPosition;
    try {
      final online = await NavigationService.smartRoute(
        widget.userPosition,
        LatLng(widget.target.lat, widget.target.lon),
        profile: _profile,
        targetName: widget.target.name,
      );
      if (mounted && online != null) {
        _setRoute(online, offline: false);
      } else if (mounted && _route == null) {
        // Fallback ligne droite si OSRM échoue
        _setRoute(NavigationService.straightLine(
            widget.userPosition,
            LatLng(widget.target.lat, widget.target.lon),
            widget.target.name), offline: true);
      }
    } catch (_) {
      if (mounted && _route == null) {
        _setRoute(NavigationService.straightLine(
            widget.userPosition,
            LatLng(widget.target.lat, widget.target.lon),
            widget.target.name), offline: true);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = LatLng(widget.target.lat, widget.target.lon);
    final dist   = NavigationService.distanceM(widget.userPosition, target);
    final bear   = NavigationService.bearingDeg(widget.userPosition, target);

    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(
        builder: (_) => NavigationScreen(
          target: widget.target,
          userPosition: widget.userPosition,
          userHeading: widget.userHeading,
          initialRoute: _route,
          profile: _profile,
          positionNotifier: widget.positionNotifier,
          headingNotifier: widget.headingNotifier,
        ),
      )),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0f1e3c).withOpacity(.95),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4),
              blurRadius: 12, offset: const Offset(0, 4))],
          border: Border.all(color: Colors.amber.withOpacity(.4)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Barre titre
          Padding(padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
            child: Row(children: [
              const Icon(Icons.navigation, color: Colors.amber, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.target.name,
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 13),
                  overflow: TextOverflow.ellipsis)),
              // Badge mode (OSRM / hors-ligne)
              if (_loading)
                const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.amber))
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _isOfflineMode
                        ? Colors.orange.withOpacity(.2)
                        : Colors.green.withOpacity(.2),
                    borderRadius: BorderRadius.circular(8)),
                  child: Text(_route?.modeLabel ?? (_isOfflineMode ? '✈ Direct' : '🗺 Route'),
                      style: TextStyle(fontSize: 9,
                          color: _isOfflineMode ? (_route?.isGraphRoute == true ? Colors.teal : Colors.orange) : Colors.green))),
              const SizedBox(width: 4),
              // Plein écran
              IconButton(icon: const Icon(Icons.open_in_full, size: 16, color: Colors.white54),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => NavigationScreen(
                      target: widget.target,
                      userPosition: widget.userPosition,
                      userHeading: widget.userHeading,
                      initialRoute: _route,
                      profile: _profile,
                      positionNotifier: widget.positionNotifier,
                      headingNotifier: widget.headingNotifier,
                    ),
                  )),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
              IconButton(icon: const Icon(Icons.close, size: 16, color: Colors.white54),
                  onPressed: widget.onClose,
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),

          // Contenu compact : boussole + distance + prochaine instruction
          Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Row(children: [
              // Boussole
              _CompassWidget(
                bearing: bear,
                userHeading: widget.userHeading,
                size: 64,
              ),
              const SizedBox(width: 14),
              // Infos distance + ETA
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_distLabel(dist),
                    style: const TextStyle(color: Colors.amber,
                        fontSize: 22, fontWeight: FontWeight.bold)),
                if (_route != null)
                  Text('⏱ ${_route!.durationLabel} • ${_route!.distanceLabel}',
                      style: const TextStyle(color: Colors.white60, fontSize: 11)),
                const SizedBox(height: 4),
                // Prochaine instruction
                if (_route != null && _route!.steps.length > 1)
                  Row(children: [
                    Icon(NavigationService.maneuverIcon(
                        _route!.steps[1].maneuver, null),
                        size: 14, color: Colors.white70),
                    const SizedBox(width: 4),
                    Expanded(child: Text(_route!.steps[0].instruction,
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                        maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
              ])),
            ])),

          // Sélecteur de profil + choix itinéraire
          Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _profileBtn('🚶', 'walking'),
              const SizedBox(width: 8),
              _profileBtn('🚲', 'cycling'),
              const SizedBox(width: 8),
              _profileBtn('🚗', 'driving'),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _openRoutePicker,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _routeOptions.hasActiveFilters
                        ? Colors.teal.withOpacity(.2) : Colors.white10,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _routeOptions.hasActiveFilters
                        ? Colors.teal : Colors.white24)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.alt_route, size: 14,
                        color: _routeOptions.hasActiveFilters ? Colors.teal : Colors.white60),
                    const SizedBox(width: 4),
                    Text('Itinéraires', style: TextStyle(fontSize: 11,
                        color: _routeOptions.hasActiveFilters ? Colors.teal : Colors.white60)),
                  ]),
                ),
              ),
            ])),
        ]),
      ),
    );
  }

  Future<void> _openRoutePicker() async {
    final picked = await Navigator.push<NavRoute>(context, MaterialPageRoute(
      builder: (_) => RoutePickerScreen(
        from: widget.userPosition,
        to: LatLng(widget.target.lat, widget.target.lon),
        targetName: widget.target.name,
        profile: _profile,
        initialOptions: _routeOptions,
      ),
    ));
    if (picked != null && mounted) {
      setState(() { _route = picked; _isOfflineMode = picked.isOffline; });
    }
  }

  Widget _profileBtn(String label, String profile) => GestureDetector(
    onTap: () {
      setState(() => _profile = profile);
      _computeRoute();
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: _profile == profile
            ? Colors.amber.withOpacity(.25) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _profile == profile ? Colors.amber : Colors.white24)),
      child: Text(label, style: const TextStyle(fontSize: 16))),
  );

  String _distLabel(double m) {
    if (!m.isFinite) return '-- m';
    if (m < 1000) return '${m.round()} m';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Écran plein écran de navigation
// ─────────────────────────────────────────────────────────────────────────────
class NavigationScreen extends StatefulWidget {
  final PoiPoint   target;
  final LatLng     userPosition;
  final double?    userHeading;
  final NavRoute?  initialRoute;
  final String     profile;
  final ValueNotifier<LatLng>?  positionNotifier;
  final ValueNotifier<double?>? headingNotifier;

  const NavigationScreen({
    super.key,
    required this.target,
    required this.userPosition,
    this.userHeading,
    this.initialRoute,
    this.profile = 'walking',
    this.positionNotifier,
    this.headingNotifier,
  });

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  late final MapController _mc;
  late final MapOrientationController _orientCtrl;
  NavRoute? _route;
  bool   _loading      = false;
  bool   _showSteps    = true;
  late String _profile;
  int    _currentStep  = 0;
  late LatLng  _livePos;
  double? _liveHeading;
  LatLng? _lastOsrmPos;
  RouteOptions _routeOptions = const RouteOptions();

  @override
  void initState() {
    super.initState();
    _mc = MapController();
    _orientCtrl = MapOrientationController(_mc,
        overviewPoints: () => _route?.geometry ?? [_livePos]);
    _profile = widget.profile;
    _route   = widget.initialRoute;
    _livePos = widget.userPosition;
    _liveHeading = widget.userHeading;
    // Écouter les updates GPS live
    widget.positionNotifier?.addListener(_onPositionUpdate);
    widget.headingNotifier?.addListener(_onHeadingUpdate);
    if (_route == null || _route!.isOffline) _fetchOsrmRoute();
  }

  @override
  void dispose() {
    widget.positionNotifier?.removeListener(_onPositionUpdate);
    widget.headingNotifier?.removeListener(_onHeadingUpdate);
    _mc.dispose();
    super.dispose();
  }

  void _onPositionUpdate() {
    if (!mounted || widget.positionNotifier == null) return;
    final newPos = widget.positionNotifier!.value;
    setState(() => _livePos = newPos);
    // Recalculer OSRM tous les 50m
    final moved = _lastOsrmPos == null
        ? true
        : NavigationService.distanceM(_lastOsrmPos!, newPos) > 50;
    if (moved && !_loading) _fetchOsrmRoute();
    // Appliquer l'orientation sélectionnée (Nord/Cap suivent la position)
    if (_orientCtrl.mode != MapOrientationMode.overview) {
      _orientCtrl.apply(userPosition: _livePos, userHeading: _liveHeading);
    }
  }

  void _onHeadingUpdate() {
    if (!mounted || widget.headingNotifier == null) return;
    setState(() => _liveHeading = widget.headingNotifier!.value);
    if (_orientCtrl.mode == MapOrientationMode.heading) {
      _orientCtrl.apply(userPosition: _livePos, userHeading: _liveHeading);
    }
  }

  void _cycleOrientation() {
    setState(() => _orientCtrl.cycle());
    _orientCtrl.apply(userPosition: _livePos, userHeading: _liveHeading);
  }

  Future<void> _fetchOsrmRoute() async {
    setState(() => _loading = true);
    _lastOsrmPos = _livePos;
    final r = await NavigationService.smartRoute(
      _livePos,
      LatLng(widget.target.lat, widget.target.lon),
      profile: _profile,
      targetName: widget.target.name,
    );
    if (mounted) setState(() {
      if (r != null) _route = r;
      else _route ??= NavigationService.straightLine(
          _livePos,
          LatLng(widget.target.lat, widget.target.lon),
          widget.target.name);
      _loading = false;
      _currentStep = 0;
      _fitRoute();
    });
  }

  void _fitRoute() {
    if (_route == null || _route!.geometry.isEmpty) return;
    // safeFitBounds évite le crash flutter_map sur bounding box dégénérée
    // (ex: POI à la position actuelle) — voir core/services/map_camera_utils.dart.
    safeFitBounds(_mc, _route!.geometry, padding: const EdgeInsets.all(48));
  }

  @override
  Widget build(BuildContext context) {
    final target = LatLng(widget.target.lat, widget.target.lon);
    final dist   = NavigationService.distanceM(_livePos, target);
    final bear   = NavigationService.bearingDeg(_livePos, target);
    final steps  = _route?.steps ?? [];

    return Scaffold(
      backgroundColor: const Color(0xFF0a1628),
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: Row(children: [
          const Icon(Icons.navigation, color: Colors.amber, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.target.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14))),
        ]),
        actions: [
          // Profil
          PopupMenuButton<String>(
            icon: Text(switch(_profile) {
              'cycling' => '🚲', 'driving' => '🚗', _ => '🚶'},
              style: const TextStyle(fontSize: 20)),
            onSelected: (p) { setState(() { _profile = p; }); _fetchOsrmRoute(); },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'walking',  child: Text('🚶 À pied')),
              PopupMenuItem(value: 'cycling',  child: Text('🚲 Vélo')),
              PopupMenuItem(value: 'driving',  child: Text('🚗 Voiture')),
            ],
          ),
          // Choix d'itinéraire (alternatives + réglages)
          IconButton(
            icon: Icon(Icons.alt_route,
                color: _routeOptions.hasActiveFilters ? Colors.tealAccent : Colors.white70),
            tooltip: 'Choisir un itinéraire',
            onPressed: () async {
              final picked = await Navigator.push<NavRoute>(context, MaterialPageRoute(
                builder: (_) => RoutePickerScreen(
                  from: _livePos,
                  to: LatLng(widget.target.lat, widget.target.lon),
                  targetName: widget.target.name,
                  profile: _profile,
                  initialOptions: _routeOptions,
                ),
              ));
              if (picked != null && mounted) {
                setState(() => _route = picked);
                _fitRoute();
              }
            },
          ),
          // Toggle liste d'instructions
          IconButton(
            icon: Icon(_showSteps ? Icons.list : Icons.map, color: Colors.white70),
            tooltip: _showSteps ? 'Masquer les instructions' : 'Afficher les instructions',
            onPressed: () => setState(() => _showSteps = !_showSteps)),
          // Recentrer
          IconButton(
            icon: const Icon(Icons.fit_screen, color: Colors.white70),
            onPressed: _fitRoute),
        ],
      ),
      body: Column(children: [
        // Bande de navigation principale (prochaine instruction)
        if (steps.isNotEmpty)
          Container(
            color: const Color(0xFF003580),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              Icon(NavigationService.maneuverIcon(
                  steps[_currentStep].maneuver, null),
                  color: Colors.white, size: 32),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(steps[_currentStep].instruction,
                    style: const TextStyle(color: Colors.white,
                        fontWeight: FontWeight.bold, fontSize: 14)),
                if (_currentStep < steps.length - 1)
                  Text('puis : ${steps[_currentStep + 1].instruction}',
                      style: const TextStyle(color: Colors.white60, fontSize: 11),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
              const SizedBox(width: 8),
              // Boussole compacte
              _CompassWidget(bearing: bear, userHeading: _liveHeading, size: 52),
            ]),
          ),

        // Barre résumé
        Container(
          color: const Color(0xFF0f1e3c),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(children: [
            Text('📍 ${_distLabel(dist)}',
                style: const TextStyle(color: Colors.amber,
                    fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(width: 16),
            if (_route != null) ...[
              Text('⏱ ${_route!.durationLabel}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(width: 16),
              Text(_route!.isOffline ? '✈ À vol d\'oiseau' : '🗺 Itinéraire',
                  style: TextStyle(
                    fontSize: 11,
                    color: _route!.isOffline ? Colors.orange : Colors.green)),
            ],
            const Spacer(),
            if (_loading)
              const SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.amber)),
          ]),
        ),

        // Carte
        Expanded(child: Stack(children: [
          FlutterMap(
            mapController: _mc,
            options: MapOptions(
              initialCenter: _livePos,
              initialZoom: 14,
              onMapReady: () => Future.microtask(_fitRoute),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.pulsegpx.app',
                tileProvider: CachedOsmTileProvider(),
              ),
              // Tracé de l'itinéraire
              if (_route != null && _route!.geometry.length > 1)
                PolylineLayer<Object>(polylines: [
                  // Fond (ombre)
                  Polyline(
                    points: _route!.geometry,
                    strokeWidth: 8,
                    color: Colors.blue.withOpacity(.25),
                  ),
                  // Ligne principale
                  Polyline(
                    points: _route!.geometry,
                    strokeWidth: 5,
                    color: _route!.isOffline
                        ? Colors.orange.withOpacity(.85)
                        : Colors.blue.withOpacity(.9),
                    strokeCap: StrokeCap.round,
                  ),
                ]),
              // Marqueurs
              MarkerLayer(markers: [
                // Position utilisateur
                Marker(
                  point: _livePos,
                  width: 40, height: 40,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blue,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [BoxShadow(color: Colors.blue.withOpacity(.5),
                          blurRadius: 8, spreadRadius: 2)]),
                    child: const Icon(Icons.person, color: Colors.white, size: 22)),
                ),
                // POI cible
                Marker(
                  point: target,
                  width: 44, height: 44,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [BoxShadow(color: Colors.red.withOpacity(.5),
                          blurRadius: 8, spreadRadius: 2)]),
                    child: const Icon(Icons.flag, color: Colors.white, size: 22)),
                ),
                // Points d'étape OSRM
                if (_route != null && !_route!.isOffline)
                  ..._route!.steps.where((s) =>
                      s.maneuver != 'depart' && s.maneuver != 'arrive').map((s) =>
                    Marker(
                      point: s.location,
                      width: 24, height: 24,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.blue, width: 2)),
                        child: Icon(
                          NavigationService.maneuverIcon(s.maneuver, null),
                          size: 12, color: Colors.blue)),
                    )),
              ]),
            ],
          ),

          // Bouton orientation carte (Nord / Cap / Vue globale)
          Positioned(bottom: 72, right: 16,
            child: MapOrientationButton(
              mode: _orientCtrl.mode,
              onTap: _cycleOrientation,
            )),

          // Bouton recadrage flottant
          Positioned(bottom: 16, right: 16,
            child: FloatingActionButton.small(
              onPressed: _fitRoute,
              backgroundColor: const Color(0xFF003580),
              child: const Icon(Icons.fit_screen, color: Colors.white))),
        ])),

        // Liste d'instructions dépliable
        if (_showSteps && steps.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            color: const Color(0xFF0f1e3c),
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: steps.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF1a2f5e)),
              itemBuilder: (ctx, i) {
                final step = steps[i];
                final isCurrent = i == _currentStep;
                return ListTile(
                  dense: true,
                  tileColor: isCurrent ? Colors.amber.withOpacity(.1) : null,
                  leading: Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? Colors.amber.withOpacity(.2) : Colors.white.withOpacity(.05),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isCurrent ? Colors.amber : Colors.white24)),
                    child: Icon(
                      NavigationService.maneuverIcon(step.maneuver, null),
                      size: 16,
                      color: isCurrent ? Colors.amber : Colors.white54)),
                  title: Text(step.instruction,
                      style: TextStyle(
                        color: isCurrent ? Colors.white : Colors.white70,
                        fontSize: 12,
                        fontWeight: isCurrent
                            ? FontWeight.bold : FontWeight.normal)),
                  subtitle: step.distanceM > 0
                      ? Text(_distLabel(step.distanceM),
                          style: const TextStyle(color: Colors.white38, fontSize: 10))
                      : null,
                  onTap: () {
                    setState(() => _currentStep = i);
                    _mc.move(step.location, 15);
                  },
                );
              },
            ),
          ),
      ]),
    );
  }

  String _distLabel(double m) {
    if (!m.isFinite) return '-- m';
    if (m < 1000) return '${m.round()} m';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget boussole — flèche pointant vers la destination
// ─────────────────────────────────────────────────────────────────────────────
class _CompassWidget extends StatelessWidget {
  final double  bearing;     // cap vers la destination (0=Nord)
  final double? userHeading; // orientation de l'utilisateur (nullable)
  final double  size;

  const _CompassWidget({
    required this.bearing,
    required this.size,
    this.userHeading,
  });

  @override
  Widget build(BuildContext context) {
    // Si on connaît l'orientation de l'utilisateur, on soustrait pour avoir
    // le cap relatif ("devant vous" = haut du cadran)
    final relative = userHeading != null
        ? (bearing - userHeading! + 360) % 360
        : bearing;

    return SizedBox(width: size, height: size,
      child: Stack(alignment: Alignment.center, children: [
        // Cercle de fond
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF0f1e3c),
            border: Border.all(color: Colors.amber.withOpacity(.4), width: 1.5)),
        ),
        // Flèche tournante
        Transform.rotate(
          angle: relative * math.pi / 180,
          child: Icon(Icons.navigation, color: Colors.amber, size: size * 0.55)),
        // Texte cap
        Positioned(bottom: 4,
          child: Text('${bearing.isFinite ? bearing.round() : 0}°',
              style: TextStyle(color: Colors.white38, fontSize: size * 0.15))),
      ]),
    );
  }
}
