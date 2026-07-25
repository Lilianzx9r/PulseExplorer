import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'navigation_service.dart';
import 'core/services/map_camera_utils.dart';
import 'core/services/vector_map_layer.dart';

// ─────────────────────────────────────────────────────────────────────────────
// junction_view.dart
//
// Vue rapprochée d'un carrefour ou du point d'arrivée — mini-carte
// fortement zoomée, avec le tracé de l'itinéraire mis en évidence (mode
// manœuvre) ou un drapeau d'arrivée (mode arrivée), plus un panneau de
// signalisation le cas échéant.
//
// TOUJOURS orientée dans le sens de la marche (rotation = -cap, comme le
// mode "Cap" de la navigation) et cadrée pour montrer l'ENSEMBLE du
// carrefour — la sélection des points affichés se fait par RAYON de
// distance autour du point d'intérêt (pas par nombre de points le long de
// la géométrie), pour ne pas risquer de couper une partie d'un rond-point
// dont la géométrie serait échantillonnée plus densément que la marge fixe
// utilisée auparavant.
//
// Ne prétend pas reproduire le rendu 3D photoréaliste de Google Maps/Waze
// (nécessiterait des assets 3D dédiés, hors de portée ici) — vise plutôt le
// style "mini-carte zoomée avec tracé en surbrillance" façon Garmin/TomTom,
// réalisable avec l'infrastructure flutter_map déjà utilisée dans l'app.
// ─────────────────────────────────────────────────────────────────────────────

class JunctionView extends StatefulWidget {
  /// Manœuvre à afficher (mode carrefour). Laisser null pour le mode
  /// arrivée (voir JunctionView.arrival).
  final NavStep? step;
  final List<LatLng> routeGeometry;
  /// Cap de progression (degrés), pour orienter la vue dans le sens de la
  /// marche — même convention que MapOrientationController (rotation = -cap).
  final double headingDeg;
  final double width;
  final double height;
  /// Mode arrivée : affiche un drapeau au lieu du tracé de manœuvre.
  final bool isArrival;
  final LatLng? arrivalPoint;

  const JunctionView({
    super.key,
    required this.step,
    required this.routeGeometry,
    required this.headingDeg,
    this.width = 170,
    this.height = 170,
  })  : isArrival = false,
        arrivalPoint = null;

  const JunctionView.arrival({
    super.key,
    required LatLng point,
    required this.headingDeg,
    this.width = 170,
    this.height = 170,
  })  : isArrival = true,
        arrivalPoint = point,
        step = null,
        routeGeometry = const [];

  @override
  State<JunctionView> createState() => _JunctionViewState();
}

class _JunctionViewState extends State<JunctionView> {
  late final MapController _mc;

  LatLng get _center => widget.isArrival ? widget.arrivalPoint! : widget.step!.location;

  @override
  void initState() {
    super.initState();
    _mc = MapController();
  }

  @override
  void dispose() {
    _mc.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(JunctionView old) {
    super.didUpdateWidget(old);
    // Une nouvelle manœuvre (ou un cap qui a significativement changé) →
    // recadrer/réorienter la mini-carte.
    if (old.step?.location != widget.step?.location ||
        old.arrivalPoint != widget.arrivalPoint ||
        (old.headingDeg - widget.headingDeg).abs() > 8) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
    }
  }

  void _fit() {
    try {
      _mc.rotate(-widget.headingDeg);
      if (widget.isArrival) {
        _mc.move(_center, 17);
        return;
      }
      safeFitBounds(_mc, _junctionPoints(), padding: const EdgeInsets.all(20),
          fallbackZoom: 18);
    } catch (_) {
      // La carte peut ne pas encore être prête (avant onMapReady) —
      // ignoré, _fit() sera rappelé via onMapReady.
    }
  }

  /// Points de la géométrie à inclure dans le cadrage, sélectionnés par
  /// RAYON de distance autour du point de manœuvre — capture l'intégralité
  /// d'un rond-point ou d'un échangeur quelle que soit la densité
  /// d'échantillonnage de la géométrie OSRM, contrairement à une simple
  /// fenêtre de N points de part et d'autre.
  List<LatLng> _junctionPoints() {
    final step = widget.step!;
    final isRoundabout = step.maneuver == 'roundabout' || step.maneuver == 'rotary' ||
        step.maneuver == 'exit roundabout' || step.maneuver == 'exit rotary';
    // Rayon plus large pour un rond-point (pour ne couper aucune de ses
    // branches) que pour un simple virage/sortie.
    final radiusM = isRoundabout ? 170.0 : 90.0;

    final pts = widget.routeGeometry
        .where((p) => NavigationService.distanceM(p, step.location) <= radiusM)
        .toList();
    if (pts.length < 2) return [step.location, step.location];
    return pts;
  }

  /// Portion de tracé mise en surbrillance (mauve) — mêmes points que le
  /// cadrage, pour rester cohérent avec ce qui est visible.
  List<LatLng> _highlightSegment() => widget.isArrival ? const [] : _junctionPoints();

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // ── Panneau de signalisation (façon panneau autoroutier) ──
        if (!widget.isArrival &&
            (step!.exitNumber != null || step.roadRef != null || step.destinations != null))
          Container(
            width: widget.width,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1B5E20), // vert panneau autoroute
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white, width: 1.5),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4), blurRadius: 6)],
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (step.exitNumber != null || step.roadRef != null)
                Row(children: [
                  if (step.exitNumber != null) ...[
                    const Text('SORTIE', style: TextStyle(color: Colors.white70,
                        fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: .5)),
                    const SizedBox(width: 4),
                    Text('${step.exitNumber}', style: const TextStyle(color: Colors.white,
                        fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                  if (step.roadRef != null) ...[
                    if (step.exitNumber != null) const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: Colors.white,
                          borderRadius: BorderRadius.circular(3)),
                      child: Text(step.roadRef!, style: const TextStyle(
                          color: Color(0xFF1B5E20), fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ]),
              if (step.destinations != null)
                Padding(
                  padding: EdgeInsets.only(top: (step.exitNumber != null || step.roadRef != null) ? 3 : 0),
                  child: Row(children: [
                    const Icon(Icons.arrow_upward, color: Colors.white, size: 14),
                    const SizedBox(width: 4),
                    Expanded(child: Text(step.destinations!,
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12,
                            fontWeight: FontWeight.w600))),
                  ]),
                ),
            ]),
          ),
        if (widget.isArrival)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF2E7D32),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white, width: 1.5)),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.flag, color: Colors.white, size: 16),
              SizedBox(width: 6),
              Text('ARRIVÉE', style: TextStyle(color: Colors.white,
                  fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: .5)),
            ]),
          ),

        // ── Mini-carte zoomée, orientée dans le sens de la marche ──
        Container(
          width: widget.width, height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4),
                blurRadius: 8, offset: const Offset(0, 3))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: FlutterMap(
              mapController: _mc,
              options: MapOptions(
                initialCenter: _center,
                initialZoom: 17,
                initialRotation: -widget.headingDeg,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
                onMapReady: () => WidgetsBinding.instance.addPostFrameCallback((_) => _fit()),
              ),
              children: [
                const AppMapLayer(),
                if (!widget.isArrival)
                  PolylineLayer<Object>(polylines: [
                    Polyline(points: widget.routeGeometry, strokeWidth: 4,
                        color: Colors.white.withOpacity(.6)),
                    Polyline(points: _highlightSegment(), strokeWidth: 6,
                        color: const Color(0xFFAB47BC)),
                  ]),
                MarkerLayer(markers: [
                  if (widget.isArrival)
                    Marker(point: _center, width: 30, height: 30,
                      child: const Icon(Icons.flag_circle, color: Color(0xFF2E7D32), size: 30))
                  else
                    Marker(point: _center, width: 16, height: 16,
                      child: Container(decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle),
                        child: const Padding(padding: EdgeInsets.all(3),
                          child: DecoratedBox(decoration: BoxDecoration(
                              color: Color(0xFFAB47BC), shape: BoxShape.circle))))),
                ]),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
