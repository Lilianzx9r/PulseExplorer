import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Stockage générique des clés API par provider (openrouter, gemini, groq,
/// mistral, ...). Remplace la logique historique où seule la clé OpenRouter
/// était persistée (via `HtmlPoiExtractor`).
///
/// Les clés sont conservées localement (SharedPreferences) sous forme d'un
/// unique JSON `{ "providerId": "clé", ... }`.
class ProviderKeyStore {
  static const _prefsKey = 'pulse_explorer.provider_keys.v1';
  static const _baseUrlPrefsKey = 'pulse_explorer.provider_base_urls.v1';

  Future<Map<String, String>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, '$value'));
    } catch (_) {
      // JSON corrompu : on repart d'un état vide plutôt que de planter.
      return {};
    }
  }

  Future<String> loadKey(String providerId) async {
    final all = await loadAll();
    return all[providerId] ?? '';
  }

  Future<bool> hasKey(String providerId) async {
    final key = await loadKey(providerId);
    return key.trim().isNotEmpty;
  }

  Future<void> saveKey(String providerId, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) {
      all.remove(providerId);
    } else {
      all[providerId] = trimmed;
    }
    await prefs.setString(_prefsKey, jsonEncode(all));
  }

  Future<void> clearKey(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAll();
    all.remove(providerId);
    await prefs.setString(_prefsKey, jsonEncode(all));
  }

  /// URL de base personnalisée, utilisée notamment pour les providers
  /// locaux (Ollama, LM Studio) dont l'adresse peut varier selon la machine.
  Future<Map<String, String>> loadAllBaseUrls() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_baseUrlPrefsKey);
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, '$value'));
    } catch (_) {
      return {};
    }
  }

  Future<String?> loadBaseUrl(String providerId) async {
    final all = await loadAllBaseUrls();
    return all[providerId];
  }

  Future<void> saveBaseUrl(String providerId, String baseUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final all = await loadAllBaseUrls();
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      all.remove(providerId);
    } else {
      all[providerId] = trimmed;
    }
    await prefs.setString(_baseUrlPrefsKey, jsonEncode(all));
  }
}
