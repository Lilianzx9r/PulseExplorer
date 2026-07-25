import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'navigation_service.dart';
import 'core/services/map_camera_utils.dart';
import 'route_options.dart';
import 'core/services/vector_map_layer.dart';

// ─────────────────────────────────────────────────────────────────────────────
// route_picker.dart
//
// UI de sélection parmi plusieurs itinéraires + réglages (péages, autoroutes,
// routes sinueuses, ferries).
// ─────────────────────────────────────────────────────────────────────────────

/// Panneau de réglages d'itinéraire (toggles)
class RouteOptionsPanel extends StatelessWidget {
  final RouteOptions options;
  final void Function(RouteOptions) onChanged;
  final bool compact;

  const RouteOptionsPanel({
    super.key, required this.options, required this.onChanged, this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 6, runSpacing: 6, children: [
      _chip('🚫💰 Sans péage', options.avoidTolls,
          (v) => onChanged(options.copyWith(avoidTolls: v))),
      _chip('🚫🛣️ Sans autoroute', options.avoidHighways,
          (v) => onChanged(options.copyWith(avoidHighways: v))),
      _chip('🏍️ Sinueux', options.preferScenic,
          (v) => onChanged(options.copyWith(preferScenic: v))),
      _chip('🚫⛴️ Sans ferry', options.avoidFerries,
          (v) => onChanged(options.copyWith(avoidFerries: v))),
    ]);
  }

  Widget _chip(String label, bool active, void Function(bool) onTap) {
    return GestureDetector(
      onTap: () => onTap(!active),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Colors.teal.withOpacity(.25) : Colors.white10,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? Colors.teal : Colors.white24)),
        child: Text(label, style: TextStyle(
            fontSize: 11, color: active ? Colors.teal : Colors.white60,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }
}

/// Écran de sélection entre plusieurs itinéraires alternatifs
class RoutePickerScreen extends StatefulWidget {
  final LatLng from;
  final LatLng to;
  final String targetName;
  final String profile;
  final RouteOptions initialOptions;

  const RoutePickerScreen({
    super.key, required this.from, required this.to,
    required this.targetName, this.profile = 'walking',
    this.initialOptions = const RouteOptions(),
  });

  @override
  State<RoutePickerScreen> createState() => _RoutePickerScreenState();
}

class _RoutePickerScreenState extends State<RoutePickerScreen> {
  late final MapController _mc;
  late RouteOptions _options;
  List<NavRoute> _routes = [];
  int _selected = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _mc = MapController();
    _options = widget.initialOptions;
    _loadRoutes();
  }

  @override
  void dispose() { _mc.dispose(); super.dispose(); }

  Future<void> _loadRoutes() async {
    setState(() => _loading = true);
    final routes = await NavigationService.routeAlternatives(
      widget.from, widget.to,
      profile: widget.profile, targetName: widget.targetName,
      options: _options,
    );
    if (mounted) {
      setState(() { _routes = routes; _selected = 0; _loading = false; });
      _fitAll();
    }
  }

  void _fitAll() {
    if (_routes.isEmpty) return;
    final pts = _routes.expand((r) => r.geometry).toList();
    if (pts.isEmpty) return;
    // safeFitBounds évite le crash flutter_map sur bounding box dégénérée —
    // voir core/services/map_camera_utils.dart.
    safeFitBounds(_mc, pts, padding: const EdgeInsets.all(48));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1628),
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: Text('Itinéraires vers ${widget.targetName}',
            overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
      ),
      body: Column(children: [
        // Réglages
        Container(
          color: const Color(0xFF0f1e3c),
          padding: const EdgeInsets.all(12),
          child: RouteOptionsPanel(
            options: _options,
            onChanged: (o) { setState(() => _options = o); _loadRoutes(); },
          ),
        ),

        // Carte
        Expanded(flex: 3, child: Stack(children: [
          FlutterMap(
            mapController: _mc,
            options: MapOptions(
              initialCenter: widget.from, initialZoom: 13,
              onMapReady: () => Future.microtask(_fitAll),
            ),
            children: [
              const AppMapLayer(),
              // Tous les tracés (le sélectionné en évidence)
              PolylineLayer<Object>(polylines: [
                for (int i = 0; i < _routes.length; i++)
                  if (i != _selected)
                    Polyline(points: _routes[i].geometry,
                        strokeWidth: 4, color: Colors.grey.withOpacity(.5)),
                if (_routes.isNotEmpty)
                  Polyline(points: _routes[_selected].geometry,
                      strokeWidth: 6, color: Colors.blue, strokeCap: StrokeCap.round),
              ]),
              MarkerLayer(markers: [
                Marker(point: widget.from, width: 30, height: 30,
                  child: Container(decoration: const BoxDecoration(
                      color: Colors.blue, shape: BoxShape.circle),
                    child: const Icon(Icons.person, color: Colors.white, size: 16))),
                Marker(point: widget.to, width: 34, height: 34,
                  child: Container(decoration: const BoxDecoration(
                      color: Colors.red, shape: BoxShape.circle),
                    child: const Icon(Icons.flag, color: Colors.white, size: 18))),
              ]),
            ],
          ),
          if (_loading)
            Container(color: Colors.black45,
              child: const Center(child: CircularProgressIndicator(color: Colors.amber))),
        ])),

        // Liste des itinéraires
        Expanded(flex: 2, child: _routes.isEmpty && !_loading
            ? const Center(child: Text('Aucun itinéraire trouvé',
                style: TextStyle(color: Colors.white54)))
            : ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _routes.length,
                itemBuilder: (ctx, i) => _routeCard(i),
              )),

        // Validation
        Padding(padding: const EdgeInsets.all(12),
          child: SizedBox(width: double.infinity,
            child: FilledButton.icon(
              onPressed: _routes.isEmpty ? null :
                  () => Navigator.pop(context, _routes[_selected]),
              icon: const Icon(Icons.navigation),
              label: const Text('Utiliser cet itinéraire'),
              style: FilledButton.styleFrom(backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 48)),
            ))),
      ]),
    );
  }

  Widget _routeCard(int i) {
    final r = _routes[i];
    final isSel = i == _selected;
    final isFastest = r.totalDurationS == _routes.map((x) => x.totalDurationS).reduce((a,b) => a < b ? a : b);
    return GestureDetector(
      onTap: () => setState(() => _selected = i),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSel ? const Color(0xFF1e3a6e) : const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSel ? Colors.amber : const Color(0xFF0f3460),
              width: isSel ? 2 : 1)),
        child: Row(children: [
          Container(width: 36, height: 36,
            decoration: BoxDecoration(
              color: isSel ? Colors.amber.withOpacity(.2) : Colors.white10,
              shape: BoxShape.circle),
            child: Center(child: Text(r.engine.emoji, style: const TextStyle(fontSize: 18)))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(r.durationLabel, style: TextStyle(
                  color: isSel ? Colors.amber : Colors.white,
                  fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(width: 8),
              Text('· ${r.distanceLabel}', style: const TextStyle(
                  color: Colors.white54, fontSize: 12)),
              if (isFastest) ...[
                const SizedBox(width: 8),
                Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: Colors.green.withOpacity(.2),
                      borderRadius: BorderRadius.circular(4)),
                  child: const Text('Le plus rapide',
                      style: TextStyle(fontSize: 9, color: Colors.greenAccent))),
              ],
            ]),
            const SizedBox(height: 2),
            Text('${r.engine.label}${r.hasTolls ? " · 💰 Péages" : ""}',
                style: const TextStyle(color: Colors.white38, fontSize: 11)),
          ])),
          if (isSel) const Icon(Icons.check_circle, color: Colors.amber),
        ]),
      ),
    );
  }
}
