import 'dart:convert';

import '../poi_layer.dart';
import 'agent_result.dart';
import 'ai_provider.dart';
import 'discovery_agent.dart';
import 'discovery_request.dart';

/// Agent IA spécialisé. Plusieurs instances peuvent utiliser des modèles
/// différents et recevoir exactement la même requête.
class AiDiscoveryAgent implements DiscoveryAgent {
  final AiProvider provider;
  final String role;
  final String instructions;

  AiDiscoveryAgent({
    required this.provider,
    required this.role,
    required this.instructions,
  });

  @override
  String get id => '${provider.id}:$role';

  @override
  String get name => '${provider.name} — $role';

  @override
  Future<AgentResult> execute(DiscoveryRequest request) async {
    final started = DateTime.now();

    final systemPrompt = '''
Tu es un agent de découverte touristique spécialisé dans : $role.

$instructions

Tu dois être prudent :
- ne fabrique pas de coordonnées précises ;
- si tu ne connais pas les coordonnées, utilise 0 ;
- privilégie les lieux réellement existants ;
- réponds en français.
''';

    final contextBlock = request.context?.trim().isNotEmpty == true
        ? 'Contexte :\\n${request.context}'
        : '';

    final userPrompt = '''
Requête utilisateur :
${request.query}

Centres d'intérêt :
${request.interests.isEmpty ? 'non précisés' : request.interests.join(', ')}

$contextBlock

Retourne UNIQUEMENT un tableau JSON valide, sans Markdown, avec au maximum 20 objets :
[
  {
    "name": "Nom du lieu",
    "description": "Pourquoi ce lieu est pertinent",
    "type": "nature|village|patrimoine|route|point_de_vue|autre",
    "lat": 0.0,
    "lon": 0.0
  }
]

Si tu ne trouves aucun lieu pertinent, retourne [].
''';

    try {
      final raw = await provider.complete(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
      );

      return AgentResult(
        agentId: id,
        agentName: name,
        points: _parsePoints(raw),
        duration: DateTime.now().difference(started),
      );
    } catch (e) {
      return AgentResult(
        agentId: id,
        agentName: name,
        points: const [],
        warnings: ['$name : $e'],
        duration: DateTime.now().difference(started),
      );
    }
  }

  List<PoiPoint> _parsePoints(String raw) {
    var text = raw.trim();

    text = text
        .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();

    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start >= 0 && end > start) {
      text = text.substring(start, end + 1);
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return const [];
    }

    if (decoded is! List) return const [];

    final points = <PoiPoint>[];
    for (final item in decoded) {
      if (item is! Map) continue;

      final name = (item['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;

      points.add(
        PoiPoint(
          name: name,
          description: (item['description'] ?? '').toString().trim(),
          type: (item['type'] ?? 'autre').toString().trim(),
          lat: _number(item['lat']),
          lon: _number(item['lon']),
        ),
      );
    }
    return points;
  }

  double _number(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0.0;
  }
}
