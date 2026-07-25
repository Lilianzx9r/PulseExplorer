import '../poi_layer.dart';

/// Résultat standardisé produit par un agent.
class AgentResult {
  final String agentId;
  final String agentName;
  final List<PoiPoint> points;
  final List<String> warnings;
  final Duration duration;

  const AgentResult({
    required this.agentId,
    required this.agentName,
    required this.points,
    this.warnings = const [],
    this.duration = Duration.zero,
  });

  Map<String, dynamic> toJson() => {
        'agentId': agentId,
        'agentName': agentName,
        'points': points.map((p) => p.toJson()).toList(),
        'warnings': warnings,
        'durationMs': duration.inMilliseconds,
      };
}
