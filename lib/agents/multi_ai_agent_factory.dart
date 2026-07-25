import 'ai_discovery_agent.dart';
import 'ai_provider.dart';

class MultiAiAgentFactory {
  static AiDiscoveryAgent general(AiProvider provider) =>
      AiDiscoveryAgent(
        provider: provider,
        role: 'exploration générale',
        instructions:
            'Identifie les lieux les plus intéressants et variés pour un voyageur.',
      );

  static AiDiscoveryAgent motorcycling(AiProvider provider) =>
      AiDiscoveryAgent(
        provider: provider,
        role: 'voyage à moto et routes panoramiques',
        instructions:
            'Recherche cols, routes panoramiques, gorges, points de vue et étapes particulièrement intéressantes pour un road-trip à moto.',
      );

  static AiDiscoveryAgent nature(AiProvider provider) =>
      AiDiscoveryAgent(
        provider: provider,
        role: 'nature et paysages',
        instructions:
            'Recherche gorges, cascades, lacs, belvédères, grottes, sommets et sites naturels accessibles depuis la route ou après une courte marche.',
      );

  static AiDiscoveryAgent heritage(AiProvider provider) =>
      AiDiscoveryAgent(
        provider: provider,
        role: 'villages et patrimoine',
        instructions:
            'Recherche villages remarquables, châteaux, monuments, patrimoine historique et lieux culturels.',
      );
}
