import 'discovery_request.dart';
import 'agent_result.dart';

/// Contrat commun de tous les agents de découverte.
abstract class DiscoveryAgent {
  String get id;
  String get name;

  Future<AgentResult> execute(DiscoveryRequest request);
}
