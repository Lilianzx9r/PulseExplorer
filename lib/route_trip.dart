import 'package:latlong2/latlong.dart';
import 'poi_layer.dart';
import 'gpx_parser.dart';
import 'navigation_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// route_trip.dart
//
// Itinéraire multi-étapes : liste ordonnée de points à visiter, avec suivi
// de validation pendant la navigation.
//
// Une étape (TripStep) peut désormais provenir de 3 sources :
//   - une adresse saisie librement (TripStep.fromPoint)
//   - un POI existant (TripStep.fromPoi)
//   - un point d'une trace GPX importée (TripStep.fromGpxPoint) — AJOUTÉ,
//     absent avant la refonte : seuls les POI pouvaient alimenter une étape,
//     alors que la planification d'itinéraire (voir maquette "Nouveau
//     parcours") doit pouvoir piocher un point directement dans un GPX
//     chargé (ex: reprendre le sommet d'une trace de rando comme étape).
// ─────────────────────────────────────────────────────────────────────────────

enum TripStepStatus { pending, active, validated, skipped }

class TripStep {
  final String id;
  String name;
  double lat, lon;
  TripStepStatus status;
  final PoiPoint? sourcePoi;       // si l'étape vient d'un POI existant
  final String? sourceGpxFileName; // si l'étape vient d'un point de trace GPX
  final int? sourceGpxPointIndex;  // index du point dans la trace d'origine

  TripStep({
    required this.id, required this.name,
    required this.lat, required this.lon,
    this.status = TripStepStatus.pending,
    this.sourcePoi,
    this.sourceGpxFileName,
    this.sourceGpxPointIndex,
  });

  LatLng get position => LatLng(lat, lon);

  /// true si l'étape vient d'un dossier POI plutôt que d'une saisie libre.
  bool get isFromPoi => sourcePoi != null;

  /// true si l'étape vient d'une trace GPX plutôt que d'une saisie libre.
  bool get isFromGpx => sourceGpxFileName != null;

  factory TripStep.fromPoi(PoiPoint poi) => TripStep(
    id: '${poi.name}_${poi.lat}_${poi.lon}_${DateTime.now().microsecondsSinceEpoch}',
    name: poi.name, lat: poi.lat, lon: poi.lon, sourcePoi: poi,
  );

  factory TripStep.fromPoint(String name, LatLng point) => TripStep(
    id: '${name}_${point.latitude}_${point.longitude}_${DateTime.now().microsecondsSinceEpoch}',
    name: name, lat: point.latitude, lon: point.longitude,
  );

  /// Crée une étape à partir d'un point d'une trace GPX chargée.
  /// [gpxFileName] identifie la trace d'origine (GpxTrack.fileName),
  /// [pointIndex] sa position dans GpxData.points, pour pouvoir retrouver
  /// le contexte (ex: rafraîchir l'étape si la trace est re-importée).
  factory TripStep.fromGpxPoint(
    String gpxFileName,
    GpxPoint point,
    int pointIndex, {
    String? label,
  }) =>
      TripStep(
        id: '${gpxFileName}_${pointIndex}_${DateTime.now().microsecondsSinceEpoch}',
        name: label ?? point.name ?? 'Point GPX ${pointIndex + 1}',
        lat: point.lat,
        lon: point.lon,
        sourceGpxFileName: gpxFileName,
        sourceGpxPointIndex: pointIndex,
      );
}

/// Itinéraire complet : liste ordonnée d'étapes
class RouteTrip {
  final List<TripStep> steps;
  int currentIndex; // index de l'étape active dans la navigation

  RouteTrip({List<TripStep>? steps, this.currentIndex = 0})
      : steps = steps ?? [];

  bool get isEmpty => steps.isEmpty;
  bool get isNotEmpty => steps.isNotEmpty;
  int get length => steps.length;

  TripStep? get currentStep =>
      currentIndex >= 0 && currentIndex < steps.length ? steps[currentIndex] : null;

  TripStep? get nextStep =>
      currentIndex + 1 < steps.length ? steps[currentIndex + 1] : null;

  bool get isLastStep => currentIndex >= steps.length - 1;
  bool get isComplete => steps.isNotEmpty &&
      steps.every((s) => s.status == TripStepStatus.validated || s.status == TripStepStatus.skipped);

  void addStep(TripStep step) {
    steps.add(step);
  }

  void removeAt(int index) {
    if (index < 0 || index >= steps.length) return;
    steps.removeAt(index);
    if (currentIndex >= steps.length) currentIndex = steps.length - 1;
  }

  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex -= 1;
    final item = steps.removeAt(oldIndex);
    steps.insert(newIndex, item);
  }

  /// Valide l'étape courante et avance à la suivante
  void validateCurrent() {
    final s = currentStep;
    if (s != null) s.status = TripStepStatus.validated;
    if (currentIndex < steps.length - 1) currentIndex++;
  }

  /// Marque l'étape courante comme "ratée" (éloignement détecté)
  void skipCurrent() {
    final s = currentStep;
    if (s != null) s.status = TripStepStatus.skipped;
    if (currentIndex < steps.length - 1) currentIndex++;
  }

  void reset() {
    currentIndex = 0;
    for (final s in steps) {
      s.status = TripStepStatus.pending;
    }
  }

  double get totalDistanceM {
    double total = 0;
    for (int i = 0; i < steps.length - 1; i++) {
      total += NavigationService.distanceM(steps[i].position, steps[i + 1].position);
    }
    return total;
  }

  // ── Persistance ────────────────────────────────────────────────────────────
  Map<String, dynamic> toJson() => {
    'steps': steps.map((s) => {
      'id': s.id, 'name': s.name, 'lat': s.lat, 'lon': s.lon,
      if (s.sourceGpxFileName != null) 'sourceGpxFileName': s.sourceGpxFileName,
      if (s.sourceGpxPointIndex != null) 'sourceGpxPointIndex': s.sourceGpxPointIndex,
    }).toList(),
    'currentIndex': currentIndex,
  };

  factory RouteTrip.fromJson(Map<String, dynamic> d) {
    final steps = (d['steps'] as List).map((s) => TripStep(
      id: s['id'] as String,
      name: s['name'] as String,
      lat: (s['lat'] as num).toDouble(),
      lon: (s['lon'] as num).toDouble(),
      sourceGpxFileName: s['sourceGpxFileName'] as String?,
      sourceGpxPointIndex: s['sourceGpxPointIndex'] as int?,
    )).toList();
    return RouteTrip(steps: steps, currentIndex: d['currentIndex'] as int? ?? 0);
  }
}
