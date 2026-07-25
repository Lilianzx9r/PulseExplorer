// ─────────────────────────────────────────────────────────────────────────────
// route_options.dart
//
// Préférences d'itinéraire appliquées aux moteurs de routage (OSRM/Valhalla).
// ─────────────────────────────────────────────────────────────────────────────

class RouteOptions {
  final bool avoidTolls;
  final bool avoidHighways;
  final bool preferScenic;   // privilégie routes sinueuses/secondaires (motos, tourisme)
  final bool avoidFerries;

  const RouteOptions({
    this.avoidTolls    = false,
    this.avoidHighways = false,
    this.preferScenic  = false,
    this.avoidFerries  = false,
  });

  RouteOptions copyWith({
    bool? avoidTolls, bool? avoidHighways, bool? preferScenic, bool? avoidFerries,
  }) => RouteOptions(
    avoidTolls:    avoidTolls    ?? this.avoidTolls,
    avoidHighways: avoidHighways ?? this.avoidHighways,
    preferScenic:  preferScenic  ?? this.preferScenic,
    avoidFerries:  avoidFerries  ?? this.avoidFerries,
  );

  bool get hasActiveFilters =>
      avoidTolls || avoidHighways || preferScenic || avoidFerries;

  /// Résumé textuel des options actives, pour affichage
  String get summary {
    final parts = <String>[];
    if (avoidTolls)    parts.add('🚫💰 Sans péage');
    if (avoidHighways) parts.add('🚫🛣️ Sans autoroute');
    if (preferScenic)  parts.add('🏍️ Routes sinueuses');
    if (avoidFerries)  parts.add('🚫⛴️ Sans ferry');
    return parts.isEmpty ? 'Itinéraire standard' : parts.join(' · ');
  }
}

/// Identifie la source d'un itinéraire calculé, pour affichage et choix
enum RouteEngine { osrm, valhalla, offlineGraph, straightLine }

extension RouteEngineLabel on RouteEngine {
  String get label => switch (this) {
    RouteEngine.osrm         => 'OSRM',
    RouteEngine.valhalla     => 'Valhalla',
    RouteEngine.offlineGraph => 'Hors-ligne',
    RouteEngine.straightLine => 'Direct',
  };

  String get emoji => switch (this) {
    RouteEngine.osrm         => '🗺️',
    RouteEngine.valhalla     => '🌍',
    RouteEngine.offlineGraph => '📱',
    RouteEngine.straightLine => '✈️',
  };
}
