import '../poi_layer.dart';
import 'agent_result.dart';
import 'discovery_agent.dart';
import 'discovery_request.dart';
import 'poi_consensus.dart';

/// Orchestre plusieurs agents indépendants puis fusionne leurs résultats.
class AgentManager {
  final List<DiscoveryAgent> agents;

  const AgentManager(this.agents);

  Future<DiscoveryRunResult> discover(
    DiscoveryRequest request, {
    bool parallel = true,
  }) async {
    final results = parallel
        ? await Future.wait(agents.map((a) => a.execute(request)))
        : await _runSequentially(request);

    final warnings = results.expand((r) => r.warnings).toList();
    final consensus = _merge(results);

    return DiscoveryRunResult(
      request: request,
      agentResults: results,
      pois: consensus,
      warnings: warnings,
    );
  }

  Future<List<AgentResult>> _runSequentially(
      DiscoveryRequest request) async {
    final results = <AgentResult>[];
    for (final agent in agents) {
      results.add(await agent.execute(request));
    }
    return results;
  }

  List<ConsensusPoi> _merge(List<AgentResult> results) {
    final groups = <String, _PoiGroup>{};

    for (final result in results) {
      for (final point in result.points) {
        final key = _canonicalKey(point);
        final group = groups.putIfAbsent(
          key,
          () => _PoiGroup(point: point),
        );
        if (!group.opinions.any((o) => o.agentId == result.agentId)) {
          group.opinions.add(
            AgentOpinion(
              agentId: result.agentId,
              agentName: result.agentName,
              reason: point.description ?? '',
            ),
          );
        }

        // Préfère une description non vide et un type renseigné.
        if ((group.point.description ?? '').isEmpty &&
            (point.description ?? '').isNotEmpty) {
          group.point = group.point.copyWith(description: point.description);
        }
        if ((group.point.type ?? '').isEmpty && (point.type ?? '').isNotEmpty) {
          group.point = group.point.copyWith(type: point.type);
        }
      }
    }

    return groups.values
        .map((g) => ConsensusPoi(point: g.point, opinions: g.opinions))
        .toList();
  }

  String _canonicalKey(PoiPoint p) {
    final normalizedName = p.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9à-ÿ]+'), ' ')
        .trim();

    // Pour les lieux géolocalisés, la proximité est un bon complément au nom.
    if (p.lat != 0.0 || p.lon != 0.0) {
      final lat = (p.lat * 1000).round();
      final lon = (p.lon * 1000).round();
      return '$normalizedName|$lat|$lon';
    }
    return normalizedName;
  }
}

class _PoiGroup {
  PoiPoint point;
  final List<AgentOpinion> opinions = [];

  _PoiGroup({required this.point});
}

class DiscoveryRunResult {
  final DiscoveryRequest request;
  final List<AgentResult> agentResults;
  final List<ConsensusPoi> pois;
  final List<String> warnings;

  const DiscoveryRunResult({
    required this.request,
    required this.agentResults,
    required this.pois,
    this.warnings = const [],
  });

  List<PoiPoint> get points => pois.map((p) => p.point).toList();
}
