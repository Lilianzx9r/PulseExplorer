import 'ai_provider.dart';
import 'discovery_agent.dart';

class AgentDefinition {
  final String id;
  final String name;
  final String description;
  final String role;
  final String instructions;
  final String providerId;
  final String model;
  final bool enabled;

  const AgentDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.role,
    required this.instructions,
    required this.providerId,
    required this.model,
    this.enabled = true,
  });

  AgentDefinition copyWith({
    String? name,
    String? description,
    String? role,
    String? instructions,
    String? providerId,
    String? model,
    bool? enabled,
  }) => AgentDefinition(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        role: role ?? this.role,
        instructions: instructions ?? this.instructions,
        providerId: providerId ?? this.providerId,
        model: model ?? this.model,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'role': role,
        'instructions': instructions,
        'providerId': providerId,
        'model': model,
        'enabled': enabled,
      };

  factory AgentDefinition.fromJson(Map<String, dynamic> json) => AgentDefinition(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        description: '${json['description'] ?? ''}',
        role: '${json['role'] ?? ''}',
        instructions: '${json['instructions'] ?? ''}',
        providerId: '${json['providerId'] ?? 'openrouter'}',
        model: '${json['model'] ?? 'openrouter/free'}',
        enabled: json['enabled'] != false,
      );
}

abstract class AgentProviderFactory {
  AiProvider? create(AgentDefinition definition);
  DiscoveryAgent? createAgent(AgentDefinition definition);
}
