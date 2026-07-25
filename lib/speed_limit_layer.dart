import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'speed_limit_service.dart';
import 'app_dirs.dart';

// ─────────────────────────────────────────────────────────────────────────────
// speed_limit_layer.dart
//
// Affichage des limitations de vitesse : couche carte (segments colorés)
// + indicateur rond façon panneau routier pendant la navigation.
//
// Réglage d'affichage persisté via AppDirs.save/loadSpeedLimitPrefs — voir
// speed_camera_layer.dart pour la même logique côté radars.
// ─────────────────────────────────────────────────────────────────────────────

class SpeedLimitController extends ChangeNotifier {
  bool _layerEnabled = false;
  List<SpeedLimitSegment> segments = [];
  SpeedLimitSegment? _current;

  bool get layerEnabled => _layerEnabled;
  SpeedLimitSegment? get current => _current;

  /// Charge le réglage persisté (affichage de la couche). À appeler une
  /// fois à la création du contrôleur.
  Future<void> loadPrefs() async {
    _layerEnabled = await AppDirs.loadSpeedLimitPrefs();
    notifyListeners();
  }

  void setLayerEnabled(bool v) {
    _layerEnabled = v;
    notifyListeners();
    AppDirs.saveSpeedLimitPrefs(layerEnabled: v);
  }

  void setSegments(List<SpeedLimitSegment> s) { segments = s; notifyListeners(); }

  /// À appeler à chaque update GPS pour rafraîchir l'indicateur dynamique
  void updateCurrentPosition(LatLng position) {
    final found = SpeedLimitService.nearestSegment(position, segments);
    if (found?.maxSpeedKmh != _current?.maxSpeedKmh ||
        found?.roadName != _current?.roadName) {
      _current = found;
      notifyListeners();
    }
  }
}

/// Couleur selon la valeur de limitation (convention proche panneaux réels)
Color _speedColor(int? kmh) {
  if (kmh == null) return Colors.grey;
  if (kmh <= 30) return Colors.blue;
  if (kmh <= 50) return Colors.green;
  if (kmh <= 90) return Colors.orange;
  return Colors.red;
}

/// Couche de segments colorés sur la carte
class SpeedLimitMapLayer extends StatelessWidget {
  final List<SpeedLimitSegment> segments;
  const SpeedLimitMapLayer({super.key, required this.segments});

  @override
  Widget build(BuildContext context) {
    return PolylineLayer<Object>(polylines: [
      for (final seg in segments)
        if (seg.maxSpeedKmh != null)
          Polyline(
            points: seg.points,
            strokeWidth: 3,
            color: _speedColor(seg.maxSpeedKmh).withOpacity(.6),
          ),
    ]);
  }
}

/// Panneau rond façon panneau routier — limite du segment courant
class SpeedLimitSign extends StatelessWidget {
  final int? maxSpeedKmh;
  const SpeedLimitSign({super.key, this.maxSpeedKmh});

  @override
  Widget build(BuildContext context) {
    if (maxSpeedKmh == null) return const SizedBox();
    return Container(
      width: 56, height: 56,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.red, width: 5),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4),
            blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: Center(child: Text('$maxSpeedKmh',
          style: const TextStyle(color: Colors.black,
              fontWeight: FontWeight.bold, fontSize: 20))),
    );
  }
}

/// Dialog paramètres limitations de vitesse
class SpeedLimitSettingsDialog extends StatelessWidget {
  final SpeedLimitController controller;
  const SpeedLimitSettingsDialog({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.speed, color: Colors.orange),
          SizedBox(width: 8),
          Text('Limitations de vitesse', style: TextStyle(fontSize: 16)),
        ]),
        content: SizedBox(width: 340, child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Afficher sur la carte', style: TextStyle(fontSize: 13)),
              subtitle: const Text('Segments colorés par limite (données OpenStreetMap)',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              value: controller.layerEnabled,
              onChanged: (v) => controller.setLayerEnabled(v),
            ),
            const SizedBox(height: 8),
            const Text('Légende :', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 10, runSpacing: 6, children: [
              _legendDot(Colors.blue, '≤30 km/h'),
              _legendDot(Colors.green, '≤50 km/h'),
              _legendDot(Colors.orange, '≤90 km/h'),
              _legendDot(Colors.red, '>90 km/h'),
            ]),
            const SizedBox(height: 10),
            Text('L\'indicateur dynamique (panneau rond) s\'affiche automatiquement '
                'pendant la navigation, sur le segment où vous vous trouvez.',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
          ],
        )),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer')),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
    const SizedBox(width: 4),
    Text(label, style: const TextStyle(fontSize: 11)),
  ]);
}
