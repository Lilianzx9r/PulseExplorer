import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'route_trip.dart';
import 'navigation_service.dart';
import 'core/services/map_camera_utils.dart';
import 'route_options.dart';
import 'map_orientation_button.dart';
import 'core/services/vector_map_layer.dart';
import 'speed_camera_service.dart';
import 'speed_camera_layer.dart';
import 'speed_limit_service.dart';
import 'speed_limit_layer.dart';
import 'gpx_parser.dart';
import 'elevation_api_service.dart';
import 'route_elevation_profile.dart';
import 'gps_simulator.dart';
import 'gps_simulator_panel.dart';
import 'junction_view.dart';

// ─────────────────────────────────────────────────────────────────────────────
// trip_navigation_screen.dart
//
// Navigation guidée à travers un itinéraire multi-étapes.
//
// Validation d'étape :
//   - Auto-validée quand on entre dans un rayon de proximité (150m)
//   - Annulée (skip) si on s'éloigne de l'étape courante EN DIRECTION de
//     l'étape suivante (détecté via la projection du déplacement), pour
//     éviter de rester bloqué sur une étape ratée tout en gardant une
//     vraie confirmation géométrique plutôt qu'un simple minuteur.
// ─────────────────────────────────────────────────────────────────────────────

class TripNavigationScreen extends StatefulWidget {
  final RouteTrip trip;
  final String profile;
  final RouteOptions options;
  final ValueNotifier<LatLng>? positionNotifier;
  final ValueNotifier<double?>? headingNotifier;
  final LatLng initialPosition;

  const TripNavigationScreen({
    super.key, required this.trip, required this.initialPosition,
    this.profile = 'driving', this.options = const RouteOptions(),
    this.positionNotifier, this.headingNotifier,
  });

  @override
  State<TripNavigationScreen> createState() => _TripNavigationScreenState();
}

class _TripNavigationScreenState extends State<TripNavigationScreen> {
  late final MapController _mc;
  late final MapOrientationController _orientCtrl;
  late LatLng _livePos;
  double? _liveHeading;
  LatLng? _prevPos; // position précédente, pour détecter la direction de déplacement

  NavRoute? _currentLegRoute;
  bool _loading = false;
  // Index de la manœuvre courante DANS le tronçon (_currentLegRoute.steps) —
  // sans ce suivi, la carte d'instruction restait bloquée sur la toute
  // première manœuvre du tronçon pendant toute sa durée (bug corrigé).
  int _maneuverIndex = 0;

  static const _validationRadiusM = 150.0;
  static const _skipDriftM = 80.0; // distance d'éloignement tolérée avant skip

  // ── Radars + limitations de vitesse ──────────────────────────────────────
  // Services déjà existants (speed_camera_*.dart, speed_limit_*.dart) mais
  // jusqu'ici jamais branchés à un écran — voir MIGRATION_NOTES.md.
  final SpeedCameraController _camCtrl = SpeedCameraController();
  final SpeedLimitController _limitCtrl = SpeedLimitController();
  SpeedCamera? _activeCamAlert;
  double _activeCamAlertDist = 0;
  static const _camAlertRadiusM = 800.0; // alerte 800 m avant le radar
  bool _hazardsLoaded = false;

  // ── Profil altimétrique 2D pendant la navigation ────────────────────────
  // Affiche le tronçon courant (départ → prochaine étape), avec la portion
  // déjà parcourue en clair. Limité au tronçon courant (pas l'itinéraire
  // multi-étapes complet) : les tronçons suivants ne sont calculés/route-
  // -és qu'au moment voulu, agréger leur profil à l'avance nécessiterait de
  // pré-calculer tous les tronçons restants — voir MIGRATION_NOTES.md.
  bool _showElevProfile = false;
  bool _elevShowFullLeg = true; // true = tronçon complet, false = restant seulement
  List<GpxPoint>? _elevProfilePoints;
  bool _elevProfileLoading = false;
  List<LatLng>? _elevProfileGeomUsed; // évite de re-fetcher la même géométrie

  // ── Simulation GPS intégrée ──────────────────────────────────────────────
  // Auparavant disponible uniquement depuis la carte principale
  // (gpx_only_view.dart), et donc perdue dès qu'on poussait un écran de
  // navigation plein écran. Intégrée ici pour être disponible quelle que
  // soit l'origine de la navigation (POI ou itinéraire — voir fusion en
  // tête de MIGRATION_NOTES.md).
  GpsSimulator? _simulator;

  @override
  void initState() {
    super.initState();
    _mc = MapController();
    _orientCtrl = MapOrientationController(_mc,
        overviewPoints: () => widget.trip.steps.map((s) => s.position).toList());
    // Pendant la navigation guidée, la carte s'oriente par défaut dans le
    // sens de la route (comme la quasi-totalité des applis de guidage) —
    // le mode "Nord fixe" reste disponible via le bouton dédié.
    _orientCtrl.mode = MapOrientationMode.heading;
    _livePos = widget.initialPosition;
    widget.positionNotifier?.addListener(_onPositionUpdate);
    widget.headingNotifier?.addListener(_onHeadingUpdate);
    _fetchLegRoute();
    _loadHazards();
  }

  @override
  void dispose() {
    widget.positionNotifier?.removeListener(_onPositionUpdate);
    widget.headingNotifier?.removeListener(_onHeadingUpdate);
    _simulator?.stop();
    _mc.dispose();
    super.dispose();
  }

  /// Démarre/arrête la simulation GPS le long du tronçon courant. Écrit
  /// dans les MÊMES notifiers que le vrai GPS (voir GpsSimulator.withExternalNotifiers)
  /// pour que radars, limitations de vitesse, orientation carte et
  /// validation d'étapes fonctionnent sans code spécifique à la simulation.
  void _toggleSimulation() {
    if (_simulator?.isRunning == true) {
      _simulator!.stop();
      setState(() {});
      return;
    }
    final geometry = _currentLegRoute?.geometry;
    if (geometry == null || geometry.length < 2 ||
        widget.positionNotifier == null || widget.headingNotifier == null) return;
    _simulator = GpsSimulator.withExternalNotifiers(
      positionNotifier: widget.positionNotifier!,
      headingNotifier: widget.headingNotifier!,
    )..start(geometry, speedKmh: 50);
    setState(() {});
  }

  void _onHeadingUpdate() {
    if (!mounted || widget.headingNotifier == null) return;
    setState(() => _liveHeading = widget.headingNotifier!.value);
  }

  void _onPositionUpdate() {
    if (!mounted || widget.positionNotifier == null) return;
    final newPos = widget.positionNotifier!.value;
    _prevPos = _livePos;
    setState(() => _livePos = newPos);

    _checkStepValidation(newPos);
    _checkHazards(newPos);
    _advanceManeuver(newPos);

    if (_orientCtrl.mode != MapOrientationMode.overview) {
      _orientCtrl.apply(userPosition: _livePos, userHeading: _liveHeading);
    }
  }

  /// Télécharge une fois les radars et limitations de vitesse pour
  /// l'emprise complète de l'itinéraire (marge de sécurité incluse), charge
  /// les préférences d'affichage persistées (voir app_dirs.dart), et
  /// vérifie la juridiction courante pour l'alerte active radar.
  Future<void> _loadHazards() async {
    if (_hazardsLoaded) return;
    _hazardsLoaded = true;

    // Réglages persistés (affichage couche + préférence d'alerte radar) —
    // ne sont plus remis à zéro à chaque navigation, contrairement à avant.
    await _camCtrl.loadPrefs();
    await _limitCtrl.loadPrefs();

    final pts = widget.trip.steps.map((s) => s.position).toList()..add(_livePos);
    if (pts.isEmpty) return;
    double minLat = pts.first.latitude, maxLat = pts.first.latitude;
    double minLon = pts.first.longitude, maxLon = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    // Marge ~1.5 km autour de l'itinéraire, pour couvrir les radars/limites
    // juste avant le départ ou après l'arrivée.
    const marginDeg = 0.015;
    minLat -= marginDeg; maxLat += marginDeg;
    minLon -= marginDeg; maxLon += marginDeg;

    // Les données sont récupérées dans tous les cas (nécessaires pour
    // l'alerte radar même si l'affichage de la couche est désactivé) ; seul
    // l'AFFICHAGE respecte le réglage persisté de l'utilisateur.
    unawaited(_camCtrl.loadCamerasInBbox(minLat, maxLat, minLon, maxLon));
    unawaited(SpeedLimitService.fetchInBbox(minLat, maxLat, minLon, maxLon)
        .then((segs) { if (mounted) _limitCtrl.setSegments(segs); }));

    // L'alerte active radar reste conditionnée à la juridiction détectée
    // par GPS (voir speed_camera_service.dart) — la préférence utilisateur
    // chargée ci-dessus ne s'applique que si le pays détecté l'autorise.
    await _camCtrl.checkJurisdiction(_livePos);
    if (mounted) setState(() {});
  }

  /// Vérifie la proximité radar (alerte à 800 m, voir _camAlertRadiusM) et
  /// met à jour l'indicateur de limitation de vitesse courante.
  void _checkHazards(LatLng pos) {
    _limitCtrl.updateCurrentPosition(pos);

    final cam = _camCtrl.checkProximity(pos, radiusM: _camAlertRadiusM);
    if (cam != null) {
      final d = NavigationService.distanceM(pos, LatLng(cam.lat, cam.lon));
      setState(() { _activeCamAlert = cam; _activeCamAlertDist = d; });
      // Masque automatiquement l'alerte après quelques secondes pour ne pas
      // encombrer l'écran pendant toute l'approche des 800 m.
      Future.delayed(const Duration(seconds: 8), () {
        if (mounted && _activeCamAlert?.id == cam.id) {
          setState(() => _activeCamAlert = null);
        }
      });
    } else if (_activeCamAlert != null) {
      final d = NavigationService.distanceM(
          pos, LatLng(_activeCamAlert!.lat, _activeCamAlert!.lon));
      if (d < 30) setState(() => _activeCamAlert = null); // radar dépassé
      else setState(() => _activeCamAlertDist = d);
    }
  }

  /// Vérifie si l'étape courante doit être validée (proximité) ou annulée
  /// (éloignement dans la direction de l'étape suivante).
  void _checkStepValidation(LatLng pos) {
    final step = widget.trip.currentStep;
    if (step == null) return;

    final distToStep = NavigationService.distanceM(pos, step.position);

    // 1. Validation par proximité
    if (distToStep <= _validationRadiusM) {
      _validateCurrentStep();
      return;
    }

    // 2. Annulation si on s'éloigne en direction de l'étape suivante
    final next = widget.trip.nextStep;
    if (next != null && _prevPos != null) {
      final distPrevToStep = NavigationService.distanceM(_prevPos!, step.position);
      final movingAway = distToStep > distPrevToStep; // on s'éloigne de l'étape
      final distToNext = NavigationService.distanceM(pos, next.position);
      final distPrevToNext = NavigationService.distanceM(_prevPos!, next.position);
      final approachingNext = distToNext < distPrevToNext; // on se rapproche de la suivante

      if (movingAway && approachingNext && distToStep > _skipDriftM) {
        _skipCurrentStep();
      }
    }
  }

  void _validateCurrentStep() {
    final stepName = widget.trip.currentStep?.name ?? '';
    setState(() => widget.trip.validateCurrent());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ Étape validée : $stepName'),
        backgroundColor: Colors.green, duration: const Duration(seconds: 2)));
    }
    _fetchLegRoute();
  }

  void _skipCurrentStep() {
    final stepName = widget.trip.currentStep?.name ?? '';
    setState(() => widget.trip.skipCurrent());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('⏭️ Étape passée : $stepName (éloignement détecté)'),
        backgroundColor: Colors.orange, duration: const Duration(seconds: 3)));
    }
    _fetchLegRoute();
  }

  Future<void> _fetchLegRoute() async {
    final step = widget.trip.currentStep;
    if (step == null) return;
    setState(() => _loading = true);
    final route = await NavigationService.smartRoute(
      _livePos, step.position,
      profile: widget.profile, targetName: step.name, options: widget.options);
    if (mounted) setState(() {
      _currentLegRoute = route;
      _loading = false;
      _maneuverIndex = 0; // nouveau tronçon → repartir de la première manœuvre
      _elevProfilePoints = null; // le profil en cache ne correspond plus
      _elevProfileGeomUsed = null;
    });
    _fitCurrentLeg();
  }

  /// Fait avancer l'instruction affichée au fil de la progression le long
  /// du tronçon — sans ça, la carte "virage" restait figée sur la première
  /// manœuvre OSRM du tronçon (souvent le tout premier virage) pendant
  /// toute sa durée, ne reflétant plus la réalité après quelques centaines
  /// de mètres (ex: plusieurs ronds-points/virages successifs).
  void _advanceManeuver(LatLng pos) {
    final steps = _currentLegRoute?.steps;
    if (steps == null || steps.length < 2) return;
    while (_maneuverIndex < steps.length - 1) {
      final distToCurrent = NavigationService.distanceM(pos, steps[_maneuverIndex].location);
      final distToNext = NavigationService.distanceM(pos, steps[_maneuverIndex + 1].location);
      // On passe à la manœuvre suivante si on est tout près de l'actuelle,
      // OU si on s'en est clairement éloigné en se rapprochant de la
      // suivante (évite de rester bloqué si le GPS "saute" par-dessus le
      // point exact de la manœuvre).
      if (distToCurrent < 25 || distToNext < distToCurrent) {
        _maneuverIndex++;
      } else {
        break;
      }
    }
  }

  /// Récupère l'altitude le long du tronçon courant via API (une seule fois
  /// par tronçon, mise en cache) — même service que gpx_only_view.dart et
  /// trip_editor_screen.dart (ElevationApiService), pour rester cohérent.
  Future<void> _fetchElevProfile() async {
    final geometry = _currentLegRoute?.geometry;
    if (geometry == null || geometry.length < 2) return;
    if (identical(geometry, _elevProfileGeomUsed)) return; // déjà fait
    _elevProfileGeomUsed = geometry;
    setState(() => _elevProfileLoading = true);
    try {
      final raw = GpxData(
        trackPoints: geometry.map((p) => GpxPoint(lat: p.latitude, lon: p.longitude)).toList(),
        waypoints: const [],
      );
      final enriched = await ElevationApiService.enrichTrackElevation(raw);
      if (mounted) setState(() => _elevProfilePoints = enriched.trackPoints);
    } catch (_) {
      if (mounted) setState(() => _elevProfilePoints = null);
    } finally {
      if (mounted) setState(() => _elevProfileLoading = false);
    }
  }

  void _toggleElevProfile() {
    setState(() => _showElevProfile = !_showElevProfile);
    if (_showElevProfile) _fetchElevProfile();
  }

  /// Fraction (0..1) de la distance du tronçon déjà parcourue, par
  /// projection de la position actuelle sur le profil (point le plus
  /// proche) — permet d'afficher "où j'en suis" sur le profil même si le
  /// tracé n'est pas une ligne droite.
  double? _legProgressFrac(LatLng pos) {
    final pts = _elevProfilePoints;
    if (pts == null || pts.length < 2) return null;
    double cum = 0, bestCum = 0, bestDist = double.infinity;
    GpxPoint? prev;
    for (final p in pts) {
      if (prev != null) {
        cum += NavigationService.distanceM(LatLng(prev.lat, prev.lon), LatLng(p.lat, p.lon));
      }
      final d = NavigationService.distanceM(pos, LatLng(p.lat, p.lon));
      if (d < bestDist) { bestDist = d; bestCum = cum; }
      prev = p;
    }
    if (cum <= 0) return 0;
    return (bestCum / cum).clamp(0.0, 1.0);
  }

  /// Points affichés dans le ruban selon le mode "tronçon complet" ou
  /// "restant seulement" (à partir de la position projetée sur le profil).
  List<GpxPoint> _elevDisplayPoints(LatLng pos) {
    final pts = _elevProfilePoints;
    if (pts == null) return const [];
    if (_elevShowFullLeg) return pts;
    final frac = _legProgressFrac(pos) ?? 0;
    final startIdx = (frac * (pts.length - 1)).round().clamp(0, pts.length - 2);
    return pts.sublist(startIdx);
  }

  /// Accès aux réglages persistants radars/limitations de vitesse (voir
  /// app_dirs.dart) — nécessaire ici puisque ces réglages démarrent
  /// désactivés par défaut tant que l'utilisateur ne les a pas activés une
  /// première fois (plus de forçage automatique, voir _loadHazards).
  void _openHazardSettings() {
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF1a1a1a),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.camera_alt, color: Colors.white70),
          title: const Text('Radars', style: TextStyle(color: Colors.white)),
          subtitle: const Text('Affichage et alerte de proximité',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          onTap: () {
            Navigator.pop(context);
            showDialog(context: context, builder: (_) => SpeedCameraSettingsDialog(
              controller: _camCtrl, currentPosition: _livePos));
          },
        ),
        ListTile(
          leading: const Icon(Icons.speed, color: Colors.white70),
          title: const Text('Limitations de vitesse', style: TextStyle(color: Colors.white)),
          subtitle: const Text('Affichage des panneaux sur la carte',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          onTap: () {
            Navigator.pop(context);
            showDialog(context: context, builder: (_) => SpeedLimitSettingsDialog(
              controller: _limitCtrl));
          },
        ),
      ])),
    );
  }

  void _fitCurrentLeg() {
    if (_currentLegRoute == null || _currentLegRoute!.geometry.isEmpty) return;
    // safeFitBounds évite le crash flutter_map ("Infinity or NaN toInt")
    // sur bounding box dégénérée — voir core/services/map_camera_utils.dart.
    safeFitBounds(_mc, _currentLegRoute!.geometry, padding: const EdgeInsets.all(48));
  }

  void _manuallyValidate() => _validateCurrentStep();
  void _manuallySkip() => _skipCurrentStep();

  void _cycleOrientation() {
    setState(() => _orientCtrl.cycle());
    _orientCtrl.apply(userPosition: _livePos, userHeading: _liveHeading);
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.trip.currentStep;
    final stepIdx = widget.trip.currentIndex;

    if (step == null || widget.trip.isComplete) {
      return Scaffold(
        backgroundColor: const Color(0xFF0a1628),
        appBar: AppBar(title: const Text('Itinéraire'),
            backgroundColor: const Color(0xFF003580), foregroundColor: Colors.white),
        // Pas de texte "Itinéraire terminé" — juste un drapeau dans une vue
        // carrefour, cohérent avec l'affichage pendant la navigation.
        body: Center(child: JunctionView.arrival(
          point: _livePos,
          headingDeg: _liveHeading ?? 0,
        )),
      );
    }

    final dist = NavigationService.distanceM(_livePos, step.position);
    final legSteps = _currentLegRoute?.steps;
    final nextManeuver = (legSteps != null && legSteps.isNotEmpty)
        ? legSteps[_maneuverIndex.clamp(0, legSteps.length - 1)] : null;
    final followingManeuver = (legSteps != null && _maneuverIndex + 1 < legSteps.length)
        ? legSteps[_maneuverIndex + 1] : null;
    // Distance LIVE jusqu'à la manœuvre (recalculée depuis la position
    // actuelle, pas la distance statique du pas OSRM) — décompte réel au
    // fil de l'approche, comme dans une vraie appli de guidage.
    final distToManeuver = nextManeuver != null
        ? NavigationService.distanceM(_livePos, nextManeuver.location) : dist;
    final speedKmh = _estimateSpeedKmh();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // ── Carte plein écran ──
        FlutterMap(
          mapController: _mc,
          options: MapOptions(initialCenter: _livePos, initialZoom: 15,
              onMapReady: () => Future.microtask(_fitCurrentLeg)),
          children: [
            const AppMapLayer(),
            if (_currentLegRoute != null)
              PolylineLayer<Object>(polylines: [
                Polyline(points: _currentLegRoute!.geometry, strokeWidth: 9,
                    color: Colors.red.shade900, strokeCap: StrokeCap.round),
                Polyline(points: _currentLegRoute!.geometry, strokeWidth: 6,
                    color: Colors.red, strokeCap: StrokeCap.round),
              ]),
            if (_limitCtrl.layerEnabled) SpeedLimitMapLayer(segments: _limitCtrl.segments),
            if (_camCtrl.layerEnabled) SpeedCameraMarkerLayer(cameras: _camCtrl.cameras),
            MarkerLayer(markers: [
              Marker(point: _livePos, width: 46, height: 46,
                child: Transform.rotate(
                  angle: (_liveHeading ?? 0) * 3.14159 / 180,
                  child: Container(decoration: BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [BoxShadow(color: Colors.red.withOpacity(.6),
                          blurRadius: 10, spreadRadius: 2)]),
                    child: const Icon(Icons.navigation, color: Colors.white, size: 22)))),
              Marker(point: step.position, width: 40, height: 40,
                child: Container(decoration: const BoxDecoration(
                    color: Colors.black87, shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 4)]),
                  child: const Icon(Icons.flag, color: Colors.white, size: 20))),
              for (int i = stepIdx + 1; i < widget.trip.length; i++)
                Marker(point: widget.trip.steps[i].position, width: 24, height: 24,
                  child: Container(decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(.6), shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5)),
                    child: Center(child: Text('${i+1}', style: const TextStyle(
                        color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold))))),
            ]),
          ],
        ),

        // ── Panneau limitation de vitesse (sous le badge d'étape) ──
        if (_limitCtrl.current?.maxSpeedKmh != null)
          Positioned(top: 130, right: 12,
            child: SpeedLimitSign(maxSpeedKmh: _limitCtrl.current!.maxSpeedKmh)),

        // ── Vue de carrefour zoomée (sortie autoroute, bifurcation, rond-point,
        // plusieurs voies) — apparaît à l'approche, façon Garmin/TomTom. ──
        if (nextManeuver != null && nextManeuver.isComplexJunction &&
            distToManeuver < 400 && _currentLegRoute != null)
          Positioned(right: 12, bottom: 190,
            child: JunctionView(
              step: nextManeuver,
              routeGeometry: _currentLegRoute!.geometry,
              // Cap de progression vers la manœuvre — calculé depuis la
              // position réelle plutôt que la boussole (fiable même sans
              // magnétomètre, y compris en simulation).
              headingDeg: NavigationService.bearingDeg(_livePos, nextManeuver.location),
            )),

        // ── Alerte radar à 800 m (bandeau, auto-masqué après quelques s) ──
        // Placée sous la rangée haute (carte de manœuvre + pastille "puis" +
        // cercle vitesse + panneau limitation) pour ne pas se superposer —
        // ces éléments occupent déjà tout le haut de l'écran jusqu'à ~190px.
        if (_activeCamAlert != null)
          Positioned(top: 195, left: 0, right: 0,
            child: Center(child: SpeedCameraAlertBanner(
              camera: _activeCamAlert!,
              distanceM: _activeCamAlertDist,
              onDismiss: () => setState(() => _activeCamAlert = null),
            ))),

        // ── Bandeau virage rouge géant façon Coyote (haut-gauche) ──
        if (nextManeuver != null)
          Positioned(top: 12, left: 12,
            child: Container(
              width: 130,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFC62828),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4),
                    blurRadius: 8, offset: const Offset(0, 3))]),
              child: Column(children: [
                Stack(clipBehavior: Clip.none, children: [
                  Icon(NavigationService.maneuverIcon(nextManeuver.maneuver, nextManeuver.modifier),
                      color: Colors.white, size: 40),
                  // Numéro de sortie au rond-point, si disponible — badge
                  // blanc superposé façon Waze/Google Maps.
                  if (nextManeuver.exitNumber != null)
                    Positioned(right: -6, top: -4,
                      child: Container(
                        width: 20, height: 20,
                        decoration: const BoxDecoration(
                            color: Colors.white, shape: BoxShape.circle),
                        child: Center(child: Text('${nextManeuver.exitNumber}',
                            style: const TextStyle(color: Color(0xFFC62828),
                                fontSize: 12, fontWeight: FontWeight.bold))))),
                ]),
                const SizedBox(height: 4),
                Text(_fmtDist(distToManeuver),
                    style: const TextStyle(color: Colors.white,
                        fontWeight: FontWeight.bold, fontSize: 16)),
                // Détail des voies à emprunter, si plusieurs voies existent
                // avec des directions différentes à l'approche de cette
                // manœuvre (ex: 3 voies, seule celle de droite tourne).
                if (nextManeuver.lanes != null && nextManeuver.lanes!.length > 1) ...[
                  const SizedBox(height: 6),
                  Row(mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final lane in nextManeuver.lanes!)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1.5),
                          child: Container(
                            width: 18, height: 18,
                            decoration: BoxDecoration(
                              color: lane.valid ? Colors.white : Colors.white24,
                              borderRadius: BorderRadius.circular(4)),
                            child: Icon(_laneIcon(lane.indications), size: 13,
                                color: lane.valid
                                    ? const Color(0xFFC62828) : Colors.white38),
                          ),
                        ),
                    ]),
                ],
              ]),
            )),

        // ── Cercle vitesse façon Coyote (haut-droite) ──
        Positioned(top: 12, right: 12,
          child: Container(
            width: 64, height: 64,
            decoration: BoxDecoration(
              color: Colors.black87, shape: BoxShape.circle,
              border: Border.all(color: Colors.white24, width: 2)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text((speedKmh.isFinite ? speedKmh.round() : 0).toString(),
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 20)),
              const Text('km/h', style: TextStyle(color: Colors.white54, fontSize: 9)),
            ]),
          )),

        // ── Boutons ronds sombres façon Coyote (gauche, sous le virage) ──
        Positioned(top: 150, left: 20,
          child: Column(children: [
            _coyoteButton(Icons.alt_route, _quickReroute),
            const SizedBox(height: 10),
            _coyoteButton(Icons.volume_up, () {}),
            const SizedBox(height: 10),
            _coyoteButton(_orientCtrl.mode == MapOrientationMode.heading
                ? Icons.explore : Icons.navigation, _cycleOrientation),
            const SizedBox(height: 10),
            _coyoteButton(Icons.show_chart, _toggleElevProfile,
                active: _showElevProfile),
            const SizedBox(height: 10),
            _coyoteButton(Icons.smart_toy,
                _currentLegRoute != null && widget.positionNotifier != null
                    ? _toggleSimulation : () {},
                active: _simulator?.isRunning == true),
            const SizedBox(height: 10),
            _coyoteButton(Icons.settings, _openHazardSettings),
          ]),
        ),

        // Étape suivante (petit aperçu, façon Coyote quand une manœuvre suit)
        if (followingManeuver != null)
          Positioned(top: 12, left: 154,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54, borderRadius: BorderRadius.circular(8)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(NavigationService.maneuverIcon(followingManeuver.maneuver, null),
                    color: Colors.white70, size: 16),
                const SizedBox(width: 4),
                Text('puis ${_fmtDist(followingManeuver.distanceM)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ]),
            )),

        // Timeline étapes (discrète, sous le cercle vitesse)
        Positioned(top: 84, right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
                color: Colors.black54, borderRadius: BorderRadius.circular(12)),
            child: Text('Étape ${stepIdx+1}/${widget.trip.length}',
                style: const TextStyle(color: Colors.white70, fontSize: 10))),
        ),

        if (_loading)
          const Positioned(top: 12, left: 154,
            child: SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber))),

        // ── Profil altimétrique 2D du tronçon (voir _toggleElevProfile) ──
        if (_showElevProfile && _elevProfileLoading)
          const Positioned(left: 0, right: 0, bottom: 92, child: NavProfileLoadingBar())
        else if (_showElevProfile && _elevProfilePoints != null)
          Positioned(left: 0, right: 0, bottom: 92,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Bascule "tronçon complet" / "restant seulement"
              Container(
                color: const Color(0xFF1a1a1a).withOpacity(0.92),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(children: [
                  const Icon(Icons.route, size: 13, color: Colors.white38),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => setState(() => _elevShowFullLeg = true),
                    child: Text('Tronçon complet',
                        style: TextStyle(fontSize: 11,
                            color: _elevShowFullLeg ? Colors.amber : Colors.white38,
                            fontWeight: _elevShowFullLeg ? FontWeight.bold : FontWeight.normal))),
                  const SizedBox(width: 14),
                  GestureDetector(
                    onTap: () => setState(() => _elevShowFullLeg = false),
                    child: Text('Restant',
                        style: TextStyle(fontSize: 11,
                            color: !_elevShowFullLeg ? Colors.amber : Colors.white38,
                            fontWeight: !_elevShowFullLeg ? FontWeight.bold : FontWeight.normal))),
                ]),
              ),
              RouteElevationProfile(
                points: _elevDisplayPoints(_livePos),
                height: 90,
                progressFrac: _elevShowFullLeg ? _legProgressFrac(_livePos) : null,
                onScrub: (_) {},
                onClose: _toggleElevProfile,
              ),
            ]),
          ),

        // ── Panneau de contrôle de la simulation GPS ──
        if (_simulator != null)
          Positioned(left: 0, right: 0, bottom: 92,
            child: GpsSimulatorPanel(
              simulator: _simulator!,
              onStop: () { _simulator!.stop(); setState(() {}); },
            )),

        // ── Bandeau ETA rouge en bas façon Coyote ──
        Positioned(bottom: 0, left: 0, right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Color(0xFFC62828),
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: SafeArea(top: false, child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(color: Colors.black26, shape: BoxShape.circle),
                    child: const Icon(Icons.close, color: Colors.white, size: 18))),
                const SizedBox(width: 10),
                const Icon(Icons.access_time, color: Colors.white70, size: 14),
                const SizedBox(width: 4),
                Text(_etaLabel(), style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(width: 14),
                Text(_fmtDist(dist),
                    style: const TextStyle(color: Colors.white70, fontSize: 13)),
                const Spacer(),
                GestureDetector(
                  onTap: _manuallySkip,
                  child: Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(color: Colors.black26, shape: BoxShape.circle),
                    child: const Icon(Icons.skip_next, color: Colors.white, size: 18))),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _manuallyValidate,
                  child: Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(color: Colors.green.shade700, shape: BoxShape.circle),
                    child: const Icon(Icons.check, color: Colors.white, size: 18))),
              ]),
              const SizedBox(height: 8),
              // Timeline étapes (points façon barre de progression Coyote)
              Row(children: [
                for (int i = 0; i < widget.trip.length; i++) ...[
                  if (i > 0) Expanded(child: Container(height: 2,
                      color: widget.trip.steps[i].status == TripStepStatus.validated
                          ? Colors.white : Colors.white24)),
                  Container(width: 16, height: 16,
                    decoration: BoxDecoration(shape: BoxShape.circle,
                      color: switch(widget.trip.steps[i].status) {
                        TripStepStatus.validated => Colors.white,
                        TripStepStatus.skipped   => Colors.orange,
                        _ => i == stepIdx ? Colors.amber : Colors.white38,
                      }),
                    child: widget.trip.steps[i].status == TripStepStatus.validated
                        ? const Icon(Icons.check, size: 10, color: Color(0xFFC62828))
                        : null),
                ],
              ]),
            ])),
          )),
      ]),
    );
  }

  Widget _coyoteButton(IconData icon, VoidCallback onTap, {bool active = false}) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 44, height: 44,
      decoration: BoxDecoration(
        color: active ? Colors.amber.shade700 : Colors.black87, shape: BoxShape.circle,
        border: Border.all(color: active ? Colors.amber : Colors.white24)),
      child: Icon(icon, color: Colors.white, size: 20),
    ),
  );

  void _quickReroute() => _fetchLegRoute();

  double _estimateSpeedKmh() {
    if (_prevPos == null) return 0;
    final d = NavigationService.distanceM(_prevPos!, _livePos);
    // Approximation grossière : distance depuis le dernier tick GPS/simulation
    return (d * 3.6).clamp(0, 200); // conversion m/tick ~ m/s -> km/h (indicatif)
  }

  String _etaLabel() {
    if (_currentLegRoute == null) return '--:--';
    final durationS = _currentLegRoute!.totalDurationS;
    // Filet de sécurité : si une durée non finie arrivait malgré tout
    // (source externe, ex. réponse OSRM inattendue), ne pas planter
    // l'écran de navigation pour un simple affichage d'heure d'arrivée.
    if (!durationS.isFinite) return '--:--';
    final eta = DateTime.now().add(Duration(seconds: durationS.round()));
    return '${eta.hour.toString().padLeft(2,'0')}:${eta.minute.toString().padLeft(2,'0')}';
  }

  /// Icône représentative de la direction principale d'une voie (OSRM
  /// fournit parfois plusieurs indications par voie, ex: ['straight','right']
  /// — on privilégie l'indication la plus "engageante" pour l'icône.
  IconData _laneIcon(List<String> indications) {
    if (indications.contains('sharp left')) return Icons.turn_sharp_left;
    if (indications.contains('sharp right')) return Icons.turn_sharp_right;
    if (indications.contains('left')) return Icons.turn_left;
    if (indications.contains('right')) return Icons.turn_right;
    if (indications.contains('slight left')) return Icons.turn_slight_left;
    if (indications.contains('slight right')) return Icons.turn_slight_right;
    if (indications.contains('uturn')) return Icons.u_turn_left;
    return Icons.straight;
  }

  String _fmtDist(double m) {
    if (!m.isFinite) return '-- m';
    return m < 1000 ? '${m.round()} m' : '${(m/1000).toStringAsFixed(1)} km';
  }
}
