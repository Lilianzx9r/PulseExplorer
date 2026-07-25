import '../poi_layer.dart';

/// Opinion d’un agent sur un POI fusionné.
class AgentOpinion {
  final String agentId;
  final String agentName;
  final String reason;

  const AgentOpinion({
    required this.agentId,
    required this.agentName,
    this.reason = '',
  });
}

/// POI fusionné provenant d’un ou plusieurs agents.
class ConsensusPoi {
  final PoiPoint point;
  final List<AgentOpinion> opinions;

  const ConsensusPoi({
    required this.point,
    required this.opinions,
  });

  int get agentCount => opinions.length;

  double get confidence {
    if (agentCount >= 3) return 1.0;
    if (agentCount == 2) return 0.85;
    return 0.55;
  }
}
