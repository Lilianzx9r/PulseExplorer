import 'dart:convert';
import 'package:http/http.dart' as http;

import 'ai_provider.dart';

class GeminiProvider implements AiProvider {
  @override
  final String model;
  final String apiKey;
  @override
  final bool freeOnly;

  const GeminiProvider({
    required this.model,
    required this.apiKey,
    this.freeOnly = false,
  });

  @override
  String get id => 'gemini:$model';

  @override
  String get name => 'Google Gemini — $model';

  @override
  Future<String> complete({
    required String systemPrompt,
    required String userPrompt,
  }) async {
    if (apiKey.trim().isEmpty) throw Exception('Clé Gemini absente.');
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=${Uri.encodeQueryComponent(apiKey.trim())}',
    );
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'systemInstruction': {
          'parts': [{'text': systemPrompt}],
        },
        'contents': [
          {
            'role': 'user',
            'parts': [{'text': userPrompt}],
          },
        ],
      }),
    ).timeout(const Duration(seconds: 90));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Gemini ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List<dynamic>? ?? const [];
    if (candidates.isEmpty) throw Exception('Réponse Gemini vide.');
    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>? ?? const [];
    return parts.map((p) => '${p['text'] ?? ''}').join();
  }
}
