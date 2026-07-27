import 'discovery_agent.dart';
import 'ai_discovery_agent.dart';
import 'ai_provider.dart';
import 'agent_definition.dart';
import 'gemini_provider.dart';
import 'openai_compatible_provider.dart';
import 'openrouter_provider.dart';
import 'provider_credentials.dart';
import '../html_poi_extractor.dart';

/// Fabrique unique des providers et agents configurés dans le Laboratoire IA.
class ProviderFactory implements AgentProviderFactory {
  final Map<String, String> _credentials;

  const ProviderFactory({Map<String, String> credentials = const {}})
      : _credentials = credentials;

  static Future<ProviderFactory> load() async {
    final credentials = <String, String>{};
    for (final id in ['openrouter', 'gemini', 'mistral', 'groq']) {
      credentials[id] = await ProviderCredentials.load(id);
    }
    return ProviderFactory(credentials: credentials);
  }

  @override
  AiProvider? create(AgentDefinition definition) {
    final providerId = definition.providerId.trim().toLowerCase();
    final key = ((_credentials[providerId] ?? '').trim().isNotEmpty
            ? _credentials[providerId]!
            : (providerId == 'openrouter' ? HtmlPoiExtractor.apiKey : ''))
        .trim();
    if (key.isEmpty) return null;

    switch (providerId) {
      case 'openrouter':
        return OpenRouterProvider(
          model: definition.model,
          apiKey: key,
        );
      case 'gemini':
        return GeminiProvider(
          model: definition.model,
          apiKey: key,
        );
      case 'mistral':
        return OpenAiCompatibleProvider(
          id: 'mistral',
          name: 'Mistral AI',
          model: definition.model,
          apiKey: key,
          baseUrl: 'https://api.mistral.ai/v1',
          freeOnly: false,
        );
      case 'groq':
        return OpenAiCompatibleProvider(
          id: 'groq',
          name: 'Groq',
          model: definition.model,
          apiKey: key,
          baseUrl: 'https://api.groq.com/openai/v1',
          freeOnly: false,
        );
      default:
        return null;
    }
  }

  @override
  DiscoveryAgent? createAgent(AgentDefinition definition) {
    final provider = create(definition);
    if (provider == null) return null;
    return AiDiscoveryAgent(
      provider: provider,
      role: definition.role,
      instructions: definition.instructions,
    );
  }
}
