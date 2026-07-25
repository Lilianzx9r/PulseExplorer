import 'dart:convert';
import 'package:http/http.dart' as http;

import 'ai_provider.dart';

/// Provider générique pour les APIs compatibles OpenAI.
/// Il permet de tester Groq et Mistral sans multiplier le code HTTP.
class OpenAiCompatibleProvider implements AiProvider {
  @override
  final String id;
  @override
  final String name;
  @override
  final String model;
  final String apiKey;
  final String baseUrl;
  @override
  final bool freeOnly;

  const OpenAiCompatibleProvider({
    required this.id,
    required this.name,
    required this.model,
    required this.apiKey,
    required this.baseUrl,
    this.freeOnly = false,
  });

  @override
  Future<String> complete({
    required String systemPrompt,
    required String userPrompt,
  }) async {
    if (apiKey.trim().isEmpty) throw Exception('Clé API absente pour $name.');

    final response = await http.post(
      Uri.parse('$baseUrl/chat/completions'),
      headers: {
        'Authorization': 'Bearer ${apiKey.trim()}',
        'Content-Type': 'application/json',
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
      throw Exception('$name ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>? ?? const [];
    if (choices.isEmpty) throw Exception('Réponse IA vide.');
    final message = choices.first['message'] as Map<String, dynamic>?;
    return '${message?['content'] ?? ''}';
  }
}
