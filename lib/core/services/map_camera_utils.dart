import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// ─────────────────────────────────────────────────────────────────────────────
// map_camera_utils.dart
//
// `MapController.fitCamera(CameraFit.bounds(...))` plante avec
// "Unsupported operation: Infinity or NaN toInt" quand la bounding box est
// dégénérée (largeur ET hauteur ~0 dans la formule interne de calcul du
// zoom — cas fréquent : un seul point, ou un itinéraire dont le départ et
// l'arrivée sont identiques, par ex. avec le point de départ implicite
// utilisé quand le GPS n'est pas disponible).
//
// Ce bug se reproduisait à l'identique dans 5 endroits différents de l'app
// (navigation_panel.dart, route_picker.dart, trip_editor_screen.dart,
// trip_navigation_screen.dart, map_orientation_button.dart) — chacun avec
// sa propre boucle min/max lat/lon et son propre appel fitCamera. Cette
// fonction centralise le calcul ET le contournement du bug, pour ne plus
// avoir à le corriger séparément à chaque nouvel écran cartographique.
// ─────────────────────────────────────────────────────────────────────────────

/// Cadre la carte sur l'ensemble des [points] fournis, avec repli sûr si la
/// bounding box est dégénérée (un seul point distinct, ou tous les points
/// identiques/quasi identiques).
void safeFitBounds(
  MapController controller,
  List<LatLng> points, {
  EdgeInsets padding = const EdgeInsets.all(48),
  double fallbackZoom = 16,
}) {
  if (points.isEmpty) return;
  if (points.length == 1) {
    controller.move(points.first, fallbackZoom);
    return;
  }

  double minLat = points.first.latitude, maxLat = points.first.latitude;
  double minLon = points.first.longitude, maxLon = points.first.longitude;
  for (final p in points) {
    if (p.latitude < minLat) minLat = p.latitude;
    if (p.latitude > maxLat) maxLat = p.latitude;
    if (p.longitude < minLon) minLon = p.longitude;
    if (p.longitude > maxLon) maxLon = p.longitude;
  }

  // ~0.0002° ≈ 20 m : en dessous, la bounding box est considérée dégénérée.
  const epsilon = 0.0002;
  if ((maxLat - minLat).abs() < epsilon && (maxLon - minLon).abs() < epsilon) {
    controller.move(LatLng((minLat + maxLat) / 2, (minLon + maxLon) / 2), fallbackZoom);
    return;
  }

  controller.fitCamera(CameraFit.bounds(
    bounds: LatLngBounds(LatLng(minLat, minLon), LatLng(maxLat, maxLon)),
    padding: padding,
  ));
}
