import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider_models.dart';

/// Récupère les modèles réellement disponibles auprès des providers configurés.
/// Les résultats sont filtrés pour privilégier les modèles utilisables en chat.
class ModelCatalogService {
  static const _openRouterBase = 'https://openrouter.ai/api/v1';
  static const _geminiBase = 'https://generativelanguage.googleapis.com/v1beta';
  static const _mistralBase = 'https://api.mistral.ai/v1';
  static const _groqBase = 'https://api.groq.com/openai/v1';

  final http.Client _client;

  ModelCatalogService({http.Client? client}) : _client = client ?? http.Client();

  Future<List<AiModelInfo>> fetchModels({
    required String providerId,
    required String apiKey,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) throw Exception('Clé API absente pour $providerId.');

    switch (providerId.toLowerCase()) {
      case 'openrouter':
        return _fetchOpenRouter(key);
      case 'gemini':
        return _fetchGemini(key);
      case 'mistral':
        return _fetchMistral(key);
      case 'groq':
        return _fetchGroq(key);
      default:
        throw Exception('Provider inconnu : $providerId');
    }
  }

  Future<List<AiModelInfo>> _fetchOpenRouter(String apiKey) async {
    final response = await _client.get(
      Uri.parse('$_openRouterBase/models'),
      headers: {'Authorization': 'Bearer $apiKey'},
    ).timeout(const Duration(seconds: 30));
    _check(response, 'OpenRouter');

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final raw = data['data'] as List<dynamic>? ?? const [];
    final result = <AiModelInfo>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final id = '${item['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      final pricing = item['pricing'];
      if (pricing is! Map) continue;
      final prompt = double.tryParse('${pricing['prompt']}') ?? 1;
      final completion = double.tryParse('${pricing['completion']}') ?? 1;
      if (prompt != 0 || completion != 0) continue;
      result.add(AiModelInfo(
        id: id,
        name: '${item['name'] ?? id}',
        providerId: 'openrouter',
        costMode: CostMode.freeOnly,
      ));
    }
    return _sort(result);
  }

  Future<List<AiModelInfo>> _fetchGemini(String apiKey) async {
    final result = <AiModelInfo>[];
    String? pageToken;
    do {
      final query = <String, String>{'pageSize': '1000', 'key': apiKey};
      if (pageToken != null && pageToken!.isNotEmpty) query['pageToken'] = pageToken!;
      final response = await _client.get(
        Uri.parse('$_geminiBase/models').replace(queryParameters: query),
      ).timeout(const Duration(seconds: 30));
      _check(response, 'Gemini');
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final raw = data['models'] as List<dynamic>? ?? const [];
      for (final item in raw) {
        if (item is! Map) continue;
        final supported = (item['supportedGenerationMethods'] as List<dynamic>? ?? const [])
            .map((e) => '$e')
            .toSet();
        if (!supported.contains('generateContent')) continue;
        final resourceName = '${item['name'] ?? ''}'.trim();
        if (resourceName.isEmpty) continue;
        final id = resourceName.startsWith('models/')
            ? resourceName.substring('models/'.length)
            : resourceName;
        result.add(AiModelInfo(
          id: id,
          name: '${item['displayName'] ?? id}',
          providerId: 'gemini',
          costMode: CostMode.freeTier,
        ));
      }
      pageToken = '${data['nextPageToken'] ?? ''}'.trim();
    } while (pageToken != null && pageToken!.isNotEmpty);
    return _sort(result);
  }

  Future<List<AiModelInfo>> _fetchMistral(String apiKey) async {
    final response = await _client.get(
      Uri.parse('$_mistralBase/models'),
      headers: {'Authorization': 'Bearer $apiKey'},
    ).timeout(const Duration(seconds: 30));
    _check(response, 'Mistral');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final raw = data['data'] as List<dynamic>? ?? const [];
    final result = <AiModelInfo>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final capabilities = item['capabilities'];
      if (capabilities is Map && capabilities['completion_chat'] != true) continue;
      final id = '${item['id'] ?? ''}'.trim();
      if (id.isEmpty || item['archived'] == true) continue;
      result.add(AiModelInfo(
        id: id,
        name: id,
        providerId: 'mistral',
        costMode: CostMode.freeTier,
      ));
    }
    return _sort(result);
  }

  Future<List<AiModelInfo>> _fetchGroq(String apiKey) async {
    final response = await _client.get(
      Uri.parse('$_groqBase/models'),
      headers: {'Authorization': 'Bearer $apiKey'},
    ).timeout(const Duration(seconds: 30));
    _check(response, 'Groq');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final raw = data['data'] as List<dynamic>? ?? const [];
    final result = <AiModelInfo>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final id = '${item['id'] ?? ''}'.trim();
      if (id.isEmpty || item['active'] == false || _isNonChatGroqModel(id)) continue;
      result.add(AiModelInfo(
        id: id,
        name: id,
        providerId: 'groq',
        costMode: CostMode.freeTier,
      ));
    }
    return _sort(result);
  }

  bool _isNonChatGroqModel(String id) {
    final value = id.toLowerCase();
    return value.contains('whisper') ||
        value.contains('guard') ||
        value.contains('safeguard') ||
        value.contains('speech') ||
        value.contains('tts') ||
        value.contains('embedding');
  }

  List<AiModelInfo> _sort(List<AiModelInfo> models) {
    final unique = <String, AiModelInfo>{};
    for (final model in models) {
      unique[model.id] = model;
    }
    final result = unique.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  void _check(http.Response response, String provider) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('$provider ${response.statusCode}: ${response.body}');
    }
  }

  void dispose() => _client.close();
}
