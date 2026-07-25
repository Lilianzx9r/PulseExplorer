import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'core/services/map_camera_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
// map_orientation_button.dart
//
// Bouton cyclique pour changer l'orientation de la carte :
//   Nord (rotation fixe 0°) → Cap (rotation = direction de déplacement)
//   → Vue globale (zoom ajusté pour tout voir) → Nord → ...
// ─────────────────────────────────────────────────────────────────────────────

enum MapOrientationMode { north, heading, overview }

class MapOrientationController {
  MapOrientationMode mode = MapOrientationMode.north;
  final MapController mapController;
  /// Pour le mode "Vue globale" : tous les points à inclure dans le cadrage
  List<LatLng> Function()? overviewPoints;

  MapOrientationController(this.mapController, {this.overviewPoints});

  /// Fait défiler vers le mode suivant
  MapOrientationMode cycle() {
    mode = switch (mode) {
      MapOrientationMode.north     => MapOrientationMode.heading,
      MapOrientationMode.heading   => MapOrientationMode.overview,
      MapOrientationMode.overview  => MapOrientationMode.north,
    };
    return mode;
  }

  /// Applique le mode courant à la carte (à appeler à chaque update GPS ou tap)
  void apply({
    required LatLng userPosition,
    double? userHeading,
    double zoomForFollow = 17,
  }) {
    switch (mode) {
      case MapOrientationMode.north:
        mapController.moveAndRotate(userPosition, zoomForFollow, 0);
        break;
      case MapOrientationMode.heading:
        // Rotation de la carte = -cap (pour que "devant" soit en haut)
        final rot = userHeading != null ? -userHeading : 0.0;
        mapController.moveAndRotate(userPosition, zoomForFollow, rot);
        break;
      case MapOrientationMode.overview:
        final pts = overviewPoints?.call() ?? [userPosition];
        if (pts.length < 2) {
          mapController.moveAndRotate(userPosition, zoomForFollow, 0);
          return;
        }
        mapController.rotate(0);
        // safeFitBounds évite le crash flutter_map sur bounding box
        // dégénérée — voir core/services/map_camera_utils.dart.
        safeFitBounds(mapController, pts, padding: const EdgeInsets.all(56));
        break;
    }
  }
}

/// Bouton flottant cyclique
class MapOrientationButton extends StatelessWidget {
  final MapOrientationMode mode;
  final VoidCallback onTap;

  const MapOrientationButton({super.key, required this.mode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (mode) {
      MapOrientationMode.north    => (Icons.explore, 'Nord', Colors.blue),
      MapOrientationMode.heading  => (Icons.navigation, 'Cap', Colors.green),
      MapOrientationMode.overview => (Icons.fit_screen, 'Vue globale', Colors.orange),
    };

    return Tooltip(
      message: 'Orientation : $label (tap pour changer)',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0f1e3c).withOpacity(.95),
            shape: BoxShape.circle,
            border: Border.all(color: color.withOpacity(.6), width: 1.5),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.3),
                blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: Icon(icon, color: color, size: 22),
        ),
      ),
    );
  }
}

/// Petite étiquette texte affichant le mode courant (optionnelle, sous le bouton)
class MapOrientationLabel extends StatelessWidget {
  final MapOrientationMode mode;
  const MapOrientationLabel({super.key, required this.mode});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (mode) {
      MapOrientationMode.north    => ('NORD', Colors.blue),
      MapOrientationMode.heading  => ('CAP', Colors.green),
      MapOrientationMode.overview => ('VUE', Colors.orange),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(.2),
        borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(
          fontSize: 9, color: color, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
    );
  }
}
