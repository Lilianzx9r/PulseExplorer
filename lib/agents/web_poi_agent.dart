import '../html_poi_extractor.dart';
import 'agent_result.dart';
import 'discovery_agent.dart';
import 'discovery_request.dart';

/// Agent IA/Web : réutilise le pipeline actuel d'extraction HTML/texte
/// de PulseExplorer et le transforme en agent indépendant.
class WebPoiAgent implements DiscoveryAgent {
  @override
  String get id => 'web_poi';

  @override
  String get name => 'Agent Web / IA';

  @override
  Future<AgentResult> execute(DiscoveryRequest request) async {
    final started = DateTime.now();

    try {
      final input = [
        request.query,
        if (request.context != null && request.context!.trim().isNotEmpty)
          request.context!,
      ].join('\n\n');

      final result = await HtmlPoiExtractor.extract(input);

      return AgentResult(
        agentId: id,
        agentName: name,
        points: result.points,
        duration: DateTime.now().difference(started),
      );
    } catch (e) {
      return AgentResult(
        agentId: id,
        agentName: name,
        points: const [],
        warnings: ['Échec de l’agent Web/IA : $e'],
        duration: DateTime.now().difference(started),
      );
    }
  }
}
