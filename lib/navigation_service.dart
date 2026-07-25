import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'offline_route_cache.dart';
import 'offline_graph.dart';
import 'route_options.dart';

// ─────────────────────────────────────────────────────────────────────────────
// navigation_service.dart
//
// Calcul d'itinéraires multi-moteurs :
//   - OSRM (router.project-osrm.org) — alternatives natives, gratuit, sans clé
//   - Valhalla (valhalla1.openstreetmap.de, démo publique FOSSGIS) — péages,
//     préférence routes sinueuses via use_highways/use_trails, gratuit, sans clé
//   - Graphe local A* hors-ligne
//   - Ligne droite (fallback ultime)
//
// smartRoute() retourne UN itinéraire (le meilleur disponible, pour usage
// simple). routeAlternatives() retourne PLUSIEURS itinéraires combinant les
// moteurs, pour proposer un choix à l'utilisateur.
// ─────────────────────────────────────────────────────────────────────────────

OfflineGraph? _cachedGraph;
String? _cachedGraphProfile;

/// Voie de circulation à l'approche d'une manœuvre (issu de
/// `intersections[].lanes` OSRM) — permet d'afficher "prenez la voie de
/// gauche/droite" quand plusieurs voies existent avec des directions
/// différentes.
class LaneInfo {
  /// Directions autorisées depuis cette voie (ex: ['left'], ['straight'],
  /// ['straight','right']).
  final List<String> indications;
  /// true si c'est une voie à emprunter pour suivre l'itinéraire calculé.
  final bool valid;
  const LaneInfo({required this.indications, required this.valid});
}

class NavStep {
  final String instruction;
  final double distanceM;
  final double durationS;
  final LatLng location;
  final String? maneuver;
  /// Sous-type de la manœuvre (ex: 'left', 'right', 'slight left'...) —
  /// nécessaire pour choisir la bonne icône de virage (maneuverIcon en a
  /// besoin en plus de `maneuver`, mais n'était jusqu'ici jamais transmis).
  final String? modifier;
  /// Numéro de route (ex: "A6", "I-64"), si l'itinéraire quitte/rejoint une
  /// route numérotée à cette manœuvre.
  final String? roadRef;
  /// Texte de panneau directionnel façon autoroute (ex: "Kingshighway
  /// Blvd"), quand OSRM le fournit (`step.destinations`).
  final String? destinations;
  /// Numéro de sortie au rond-point (ex: 3ᵉ sortie), si la manœuvre en est
  /// une et que la donnée est disponible (OSRM `maneuver.exit`).
  final int? exitNumber;
  /// Voies de circulation à l'approche de cette manœuvre, dans l'ordre
  /// gauche → droite ; null/vide si l'info n'est pas disponible (Valhalla,
  /// graphe hors-ligne) ou qu'il n'y a qu'une seule voie.
  final List<LaneInfo>? lanes;
  const NavStep({required this.instruction, required this.distanceM,
      required this.durationS, required this.location, this.maneuver,
      this.modifier, this.roadRef, this.destinations,
      this.exitNumber, this.lanes});

  /// true pour les manœuvres "complexes" où un zoom sur le carrefour aide
  /// vraiment (sortie d'autoroute, bifurcation, rond-point, ou plusieurs
  /// voies) — par opposition à un simple virage sur route classique.
  bool get isComplexJunction =>
      maneuver == 'off ramp' || maneuver == 'on ramp' || maneuver == 'fork' ||
      maneuver == 'roundabout' || maneuver == 'rotary' ||
      maneuver == 'exit roundabout' || maneuver == 'exit rotary' ||
      (lanes != null && lanes!.length > 1);
}

class NavRoute {
  final List<LatLng> geometry;
  final List<NavStep> steps;
  final double totalDistanceM;
  final double totalDurationS;
  final bool isOffline;
  final bool isGraphRoute;
  final RouteEngine engine;
  final bool hasTolls; // si l'engine a pu déterminer la présence de péages

  const NavRoute({
    required this.geometry, required this.steps,
    required this.totalDistanceM, required this.totalDurationS,
    required this.isOffline, this.isGraphRoute = false,
    this.engine = RouteEngine.osrm, this.hasTolls = false,
  });

  String get durationLabel {
    if (totalDurationS < 60) return '${totalDurationS.round()} s';
    if (totalDurationS < 3600) return '${(totalDurationS / 60).round()} min';
    final h = (totalDurationS / 3600).floor();
    final m = ((totalDurationS % 3600) / 60).round();
    return '${h}h${m.toString().padLeft(2, '0')}';
  }
  String get distanceLabel => totalDistanceM < 1000
      ? '${totalDistanceM.round()} m'
      : '${(totalDistanceM / 1000).toStringAsFixed(1)} km';
  String get modeLabel => isGraphRoute
      ? '📱 Hors-ligne' : isOffline ? '✈ Direct' : '${engine.emoji} ${engine.label}';
}

class NavigationService {
  NavigationService._();

  static double distanceM(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = _rad(b.latitude - a.latitude);
    final dLon = _rad(b.longitude - a.longitude);
    final h = math.sin(dLat/2)*math.sin(dLat/2) +
        math.cos(_rad(a.latitude))*math.cos(_rad(b.latitude))*
        math.sin(dLon/2)*math.sin(dLon/2);
    // Clamp indispensable : par erreur d'arrondi flottant, `h` peut sortir
    // très légèrement de [0, 1] (ex: -1e-17 quand a == b), ce qui rend
    // math.sqrt(h) NaN et fait planter tout .round()/.toInt() en aval
    // ("Unsupported operation: Infinity or NaN toInt") — typiquement au
    // lancement d'une navigation dont le point de départ est identique à
    // la première étape (pas de GPS).
    final hClamped = h.clamp(0.0, 1.0);
    return 2 * R * math.asin(math.sqrt(hClamped));
  }

  static double bearingDeg(LatLng from, LatLng to) {
    final dLon = _rad(to.longitude - from.longitude);
    final y = math.sin(dLon) * math.cos(_rad(to.latitude));
    final x = math.cos(_rad(from.latitude)) * math.sin(_rad(to.latitude)) -
        math.sin(_rad(from.latitude)) * math.cos(_rad(to.latitude)) * math.cos(dLon);
    return (_deg(math.atan2(y, x)) + 360) % 360;
  }

  static NavRoute straightLine(LatLng from, LatLng to, String targetName) {
    final dist = distanceM(from, to);
    final bear = bearingDeg(from, to);
    final dur  = dist / (dist > 5000 ? 4.0 : 3.5);
    return NavRoute(
      geometry: [from, to],
      steps: [
        NavStep(instruction: 'Direction ${_bearingLabel(bear)} vers $targetName',
            distanceM: dist, durationS: dur, location: from, maneuver: 'depart'),
        NavStep(instruction: 'Arrivée : $targetName',
            distanceM: 0, durationS: 0, location: to, maneuver: 'arrive'),
      ],
      totalDistanceM: dist, totalDurationS: dur, isOffline: true,
      engine: RouteEngine.straightLine,
    );
  }

  /// Calcule le meilleur itinéraire unique disponible (usage simple)
  static Future<NavRoute> smartRoute(LatLng from, LatLng to,
      {String profile = 'walking', String targetName = 'destination',
       RouteOptions options = const RouteOptions()}) async {
    final cached = await OfflineRouteCache.get(from, to, profile);
    if (cached != null && !options.hasActiveFilters) return cached;

    final graph = await _tryOfflineGraph(from, to, profile, targetName);
    if (graph != null) return graph;

    final online = await osrmRoute(from, to, profile: profile,
        targetName: targetName, options: options);
    if (online != null) {
      if (!options.hasActiveFilters) await OfflineRouteCache.put(from, to, profile, online);
      return online;
    }

    return straightLine(from, to, targetName);
  }

  /// Calcule PLUSIEURS itinéraires alternatifs en combinant les moteurs
  /// disponibles — pour proposer un choix à l'utilisateur.
  static Future<List<NavRoute>> routeAlternatives(LatLng from, LatLng to,
      {String profile = 'walking', String targetName = 'destination',
       RouteOptions options = const RouteOptions()}) async {
    final results = <NavRoute>[];

    // OSRM avec alternatives natives
    final osrmRoutes = await osrmRouteAlternatives(from, to,
        profile: profile, targetName: targetName, options: options);
    results.addAll(osrmRoutes);

    // Valhalla — moteur indépendant, donne souvent un chemin différent,
    // et c'est le seul à supporter nativement les options péage/sinuosité
    final valhallaR = await valhallaRoute(from, to,
        profile: profile, targetName: targetName, options: options);
    if (valhallaR != null) results.add(valhallaR);

    // Fallback si rien n'a fonctionné
    if (results.isEmpty) {
      final graph = await _tryOfflineGraph(from, to, profile, targetName);
      if (graph != null) results.add(graph);
    }
    if (results.isEmpty) {
      results.add(straightLine(from, to, targetName));
    }

    // Dédupliquer les routes quasi-identiques (distance proche à <3%)
    final unique = <NavRoute>[];
    for (final r in results) {
      final dup = unique.any((u) =>
          (u.totalDistanceM - r.totalDistanceM).abs() / r.totalDistanceM < 0.03);
      if (!dup) unique.add(r);
    }
    unique.sort((a, b) => a.totalDurationS.compareTo(b.totalDurationS));
    return unique;
  }

  static Future<NavRoute?> _tryOfflineGraph(
      LatLng from, LatLng to, String profile, String targetName) async {
    try {
      if (_cachedGraph == null || _cachedGraphProfile != profile) {
        final loaded = await OfflineGraph.load(profile);
        if (loaded != null) { _cachedGraph = loaded; _cachedGraphProfile = profile; }
      }
      final g = _cachedGraph;
      if (g == null) return null;
      if (!g.coversPoint(from.latitude, from.longitude) ||
          !g.coversPoint(to.latitude, to.longitude)) return null;
      return g.route(from, to, profile, targetName);
    } catch (_) { return null; }
  }

  static void invalidateGraphCache() {
    _cachedGraph = null; _cachedGraphProfile = null;
  }

  // ── OSRM ──────────────────────────────────────────────────────────────────
  static const _osrmBase = 'https://router.project-osrm.org/route/v1';

  static Future<NavRoute?> osrmRoute(LatLng from, LatLng to,
      {String profile = 'walking', String targetName = 'destination',
       RouteOptions options = const RouteOptions()}) async {
    final routes = await osrmRouteAlternatives(from, to,
        profile: profile, targetName: targetName, options: options, maxAlternatives: 1);
    return routes.isEmpty ? null : routes.first;
  }

  /// OSRM avec alternatives natives (`alternatives=true`).
  /// Note : OSRM démo public ne supporte pas nativement l'évitement péages/
  /// autoroutes — ces options ne sont appliquées que par Valhalla. OSRM
  /// reste utile pour la vitesse et la fiabilité du tracé principal.
  static Future<List<NavRoute>> osrmRouteAlternatives(LatLng from, LatLng to,
      {String profile = 'walking', String targetName = 'destination',
       RouteOptions options = const RouteOptions(), int maxAlternatives = 3}) async {
    try {
      final url = Uri.parse(
        '$_osrmBase/$profile/${from.longitude},${from.latitude};'
        '${to.longitude},${to.latitude}'
        '?overview=full&geometries=geojson&steps=true&annotations=false'
        '&alternatives=${maxAlternatives > 1}');
      final resp = await http.get(url, headers: {'User-Agent': 'PulseGpx/1.0'})
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return [];
      final data = json.decode(resp.body) as Map;
      if (data['code'] != 'Ok') return [];

      final routes = (data['routes'] as List).take(maxAlternatives);
      final results = <NavRoute>[];
      for (final route in routes) {
        final r = route as Map;
        final coords = (r['geometry']['coordinates'] as List)
            .map((c) => LatLng((c as List)[1].toDouble(), c[0].toDouble())).toList();
        final steps = <NavStep>[];
        for (final leg in (r['legs'] as List)) {
          for (final step in (leg['steps'] as List)) {
            final m = step['maneuver'] as Map;
            final loc = (m['location'] as List);
            // Numéro de sortie rond-point, si présent (OSRM ne le fournit
            // que pour les manœuvres roundabout/rotary).
            final exitRaw = m['exit'];
            final exitNumber = exitRaw is num ? exitRaw.toInt() : null;
            // Voies de circulation : OSRM les donne par intersection ; on
            // prend la DERNIÈRE intersection du pas, la plus proche du
            // point de manœuvre, qui est celle pertinente pour "quelle
            // voie prendre avant de tourner".
            List<LaneInfo>? lanes;
            final intersections = step['intersections'] as List?;
            if (intersections != null && intersections.isNotEmpty) {
              final lastInter = intersections.last as Map;
              final lanesRaw = lastInter['lanes'] as List?;
              if (lanesRaw != null && lanesRaw.length > 1) {
                lanes = lanesRaw.map((l) {
                  final lm = l as Map;
                  return LaneInfo(
                    indications: (lm['indications'] as List? ?? [])
                        .map((e) => e.toString()).toList(),
                    valid: lm['valid'] == true,
                  );
                }).toList();
              }
            }
            steps.add(NavStep(
              instruction: _osrmInstruction(step, targetName),
              distanceM:   (step['distance'] as num).toDouble(),
              durationS:   (step['duration'] as num).toDouble(),
              location:    LatLng(loc[1].toDouble(), loc[0].toDouble()),
              maneuver:    m['type']?.toString(),
              modifier:    m['modifier']?.toString(),
              roadRef:     (step['ref'] as String?)?.isNotEmpty == true ? step['ref'] as String : null,
              destinations: (step['destinations'] as String?)?.isNotEmpty == true
                  ? step['destinations'] as String : null,
              exitNumber:  exitNumber,
              lanes:       lanes,
            ));
          }
        }
        results.add(NavRoute(geometry: coords, steps: steps,
            totalDistanceM: (r['distance'] as num).toDouble(),
            totalDurationS: (r['duration'] as num).toDouble(),
            isOffline: false, engine: RouteEngine.osrm));
      }
      return results;
    } catch (_) { return []; }
  }

  // ── Valhalla (démo publique FOSSGIS, gratuit, sans clé) ────────────────────
  static const _valhallaBase = 'https://valhalla1.openstreetmap.de/route';

  static Future<NavRoute?> valhallaRoute(LatLng from, LatLng to,
      {String profile = 'walking', String targetName = 'destination',
       RouteOptions options = const RouteOptions()}) async {
    try {
      // Mapping profil PulseGpx → costing Valhalla
      final costing = switch(profile) {
        'driving' => 'auto',
        'cycling' => 'bicycle',
        _         => 'pedestrian',
      };

      final costingOptions = <String, dynamic>{};
      if (costing == 'auto') {
        costingOptions['auto'] = {
          if (options.avoidTolls) 'toll_booth_penalty': 3600.0,
          if (options.avoidHighways) 'use_highways': 0.0,
          if (options.avoidFerries) 'use_ferry': 0.0,
          if (options.preferScenic) ...{
            'use_highways': 0.05,
            'use_tolls': options.avoidTolls ? 0.0 : 0.5,
          },
        };
      } else if (costing == 'bicycle') {
        costingOptions['bicycle'] = {
          if (options.preferScenic) 'use_roads': 0.2,
          if (options.avoidFerries) 'use_ferry': 0.0,
        };
      }

      final body = json.encode({
        'locations': [
          {'lat': from.latitude, 'lon': from.longitude},
          {'lat': to.latitude, 'lon': to.longitude},
        ],
        'costing': costing,
        if (costingOptions.isNotEmpty) 'costing_options': costingOptions,
        'units': 'kilometers',
        'language': 'fr-FR',
      });

      final resp = await http.post(
        Uri.parse(_valhallaBase),
        headers: {'Content-Type': 'application/json', 'User-Agent': 'PulseGpx/1.0'},
        body: body,
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) return null;
      final data = json.decode(resp.body) as Map;
      final trip = data['trip'] as Map?;
      if (trip == null || trip['status'] != 0) return null;

      final legs = trip['legs'] as List;
      final geometry = <LatLng>[];
      final steps = <NavStep>[];
      bool hasTolls = false;

      for (final leg in legs) {
        final shape = leg['shape']?.toString() ?? '';
        geometry.addAll(_decodePolyline6(shape));

        final maneuvers = leg['maneuvers'] as List? ?? [];
        for (final m in maneuvers) {
          final mm = m as Map;
          final instr = mm['instruction']?.toString() ?? 'Continuez';
          final dist = ((mm['length'] as num?) ?? 0).toDouble() * 1000; // km → m
          final dur  = ((mm['time'] as num?) ?? 0).toDouble();
          final beginIdx = (mm['begin_shape_index'] as num?)?.toInt() ?? 0;
          final loc = beginIdx < geometry.length ? geometry[beginIdx] : (from);
          if (mm['toll'] == true) hasTolls = true;
          steps.add(NavStep(
            instruction: instr, distanceM: dist, durationS: dur,
            location: loc, maneuver: _valhallaManeuverType(mm['type']),
          ));
        }
      }

      final summary = trip['summary'] as Map;
      return NavRoute(
        geometry: geometry, steps: steps,
        totalDistanceM: (summary['length'] as num).toDouble() * 1000,
        totalDurationS: (summary['time'] as num).toDouble(),
        isOffline: false, engine: RouteEngine.valhalla, hasTolls: hasTolls,
      );
    } catch (_) {
      return null;
    }
  }

  /// Décodage polyline précision 6 (format Valhalla)
  static List<LatLng> _decodePolyline6(String encoded) {
    final points = <LatLng>[];
    int index = 0, lat = 0, lon = 0;
    while (index < encoded.length) {
      int shift = 0, result = 0, b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      shift = 0; result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlon = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lon += dlon;

      points.add(LatLng(lat / 1e6, lon / 1e6));
    }
    return points;
  }

  static String? _valhallaManeuverType(dynamic type) {
    final t = (type as num?)?.toInt() ?? 0;
    // Mapping simplifié des types de manœuvre Valhalla → icônes communes
    return switch (t) {
      1       => 'depart',
      4       => 'arrive',
      15 || 16 => 'roundabout',
      9 || 19  => 'turn-right',
      8 || 20  => 'turn-left',
      _        => 'straight',
    };
  }

  static double _rad(double d) => d * math.pi / 180;
  static double _deg(double r) => r * 180 / math.pi;

  static String _bearingLabel(double b) {
    const d = ['N','NE','E','SE','S','SO','O','NO'];
    return d[((b + 22.5) / 45).floor() % 8];
  }

  static String _osrmInstruction(Map step, String targetName) {
    final type = step['maneuver']?['type'] ?? '';
    final mod  = step['maneuver']?['modifier'] ?? '';
    final name = step['name']?.toString() ?? '';
    final dist = (step['distance'] as num?)?.toDouble() ?? 0;
    final ds   = dist < 1000 ? '${dist.round()} m' : '${(dist/1000).toStringAsFixed(1)} km';
    if (type == 'depart') return 'Départ${name.isNotEmpty ? " sur $name" : ""}';
    if (type == 'arrive') return 'Arrivée : $targetName';
    if (type == 'turn') {
      final dir = switch(mod) {
        'left'         => 'Tournez à gauche',
        'right'        => 'Tournez à droite',
        'slight left'  => 'Légèrement à gauche',
        'slight right' => 'Légèrement à droite',
        'sharp left'   => 'Virage serré à gauche',
        'sharp right'  => 'Virage serré à droite',
        'uturn'        => 'Demi-tour',
        _              => 'Continuez tout droit',
      };
      return '$dir${name.isNotEmpty ? " sur $name" : ""} ($ds)';
    }
    if (type == 'roundabout' || type == 'rotary') {
      final exit = step['maneuver']?['exit']?.toString() ?? '';
      return 'Rond-point${exit.isNotEmpty ? ", sortie $exit" : ""}${name.isNotEmpty ? " vers $name" : ""} ($ds)';
    }
    return 'Continuez${name.isNotEmpty ? " sur $name" : ""} ($ds)';
  }

  static IconData maneuverIcon(String? maneuver, String? modifier) {
    if (maneuver == 'arrive')   return Icons.flag;
    if (maneuver == 'depart')   return Icons.navigation;
    if (maneuver == 'roundabout' || maneuver == 'rotary') return Icons.rotate_right;
    if (modifier == 'left'  || modifier == 'sharp left')  return Icons.turn_left;
    if (modifier == 'right' || modifier == 'sharp right') return Icons.turn_right;
    if (modifier == 'slight left')  return Icons.turn_slight_left;
    if (modifier == 'slight right') return Icons.turn_slight_right;
    if (modifier == 'uturn')        return Icons.u_turn_left;
    if (maneuver == 'turn-left')    return Icons.turn_left;
    if (maneuver == 'turn-right')   return Icons.turn_right;
    return Icons.straight;
  }
}
