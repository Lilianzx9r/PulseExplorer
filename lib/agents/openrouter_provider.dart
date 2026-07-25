import 'dart:convert';
import 'package:http/http.dart' as http;

import '../html_poi_extractor.dart';
import 'ai_provider.dart';

/// Provider OpenRouter. En mode freeOnly, les modèles explicitement payants
/// ne doivent pas être sélectionnés par l'interface.
class OpenRouterProvider implements AiProvider {
  @override
  final String model;

  final String apiKey;
  final String baseUrl;
  @override
  final bool freeOnly;

  OpenRouterProvider({
    required this.model,
    String? apiKey,
    this.baseUrl = 'https://openrouter.ai/api/v1',
    this.freeOnly = true,
  }) : apiKey = (apiKey ?? HtmlPoiExtractor.apiKey).trim();

  @override
  String get id => 'openrouter:$model';

  @override
  String get name => 'OpenRouter — $model';

  @override
  Future<String> complete({
    required String systemPrompt,
    required String userPrompt,
  }) async {
    if (apiKey.isEmpty) {
      throw Exception('Clé API OpenRouter absente.');
    }

    final response = await http.post(
      Uri.parse('$baseUrl/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
        'HTTP-Referer': 'https://github.com/gpx-overlay',
        'X-Title': 'PulseExplorer',
      },
      body: jsonEncode({
        'model': model,
        'temperature': 0.2,
        'max_tokens': 2500,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
      }),
    ).timeout(const Duration(seconds: 90));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('OpenRouter ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>? ?? const [];
    if (choices.isEmpty) throw Exception('Réponse IA vide.');

    final message = choices.first['message'] as Map<String, dynamic>?;
    final content = message?['content'];
    if (content is String) return content;
    if (content is List) {
      return content
          .map((e) => e is Map ? e['text'] ?? e.toString() : e.toString())
          .join();
    }
    return content?.toString() ?? '';
  }

  static Future<List<OpenRouterModel>> fetchFreeModels({
    required String apiKey,
    String baseUrl = 'https://openrouter.ai/api/v1',
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) throw Exception('Clé API OpenRouter absente.');

    final response = await http.get(
      Uri.parse('$baseUrl/models'),
      headers: {'Authorization': 'Bearer $key'},
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('OpenRouter ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final raw = data['data'] as List<dynamic>? ?? const [];
    final result = <OpenRouterModel>[];

    for (final item in raw) {
      if (item is! Map) continue;
      final pricing = item['pricing'];
      if (pricing is! Map) continue;
      final prompt = double.tryParse('${pricing['prompt']}');
      final completion = double.tryParse('${pricing['completion']}');
      if (prompt != 0 || completion != 0) continue;

      final id = '${item['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      result.add(OpenRouterModel(
        id: id,
        name: '${item['name'] ?? id}',
        contextLength: int.tryParse('${item['context_length'] ?? 0}') ?? 0,
      ));
    }

    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }
}

class OpenRouterModel {
  final String id;
  final String name;
  final int contextLength;

  const OpenRouterModel({
    required this.id,
    required this.name,
    required this.contextLength,
  });
}
