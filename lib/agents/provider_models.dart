import 'ai_provider.dart';

/// Niveau de coût déclaré par un provider.
/// Il s'agit d'un garde-fou de configuration, pas d'une garantie de facturation.
enum CostMode { freeOnly, freeTier, paidAllowed }

class AiModelInfo {
  final String id;
  final String name;
  final String providerId;
  final CostMode costMode;
  final bool available;

  const AiModelInfo({
    required this.id,
    required this.name,
    required this.providerId,
    required this.costMode,
    this.available = true,
  });

  bool get isFree => costMode == CostMode.freeOnly;
}

class ProviderDefinition {
  final String id;
  final String name;
  final String description;
  final CostMode costMode;
  final bool enabled;

  const ProviderDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.costMode,
    this.enabled = true,
  });
}

/// Catalogue initial de providers. Les modèles sont volontairement configurables
/// et ne sont pas figés dans le code.
class ProviderCatalog {
  static const definitions = <ProviderDefinition>[
    ProviderDefinition(
      id: 'openrouter',
      name: 'OpenRouter',
      description: 'Accès à des modèles gratuits et à openrouter/free.',
      costMode: CostMode.freeOnly,
    ),
    ProviderDefinition(
      id: 'gemini',
      name: 'Google Gemini',
      description: 'API directe avec Free Tier selon le compte et le modèle.',
      costMode: CostMode.freeTier,
    ),
    ProviderDefinition(
      id: 'mistral',
      name: 'Mistral AI',
      description: 'API directe avec mode gratuit selon les conditions du compte.',
      costMode: CostMode.freeTier,
    ),
    ProviderDefinition(
      id: 'groq',
      name: 'Groq',
      description: 'Inference rapide avec limites gratuites selon le compte.',
      costMode: CostMode.freeTier,
    ),
  ];

}
