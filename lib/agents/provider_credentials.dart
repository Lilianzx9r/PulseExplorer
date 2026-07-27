import 'package:shared_preferences/shared_preferences.dart';

/// Stockage local des clés API utilisées par les providers IA.
/// Les clés restent sur l'appareil et ne sont jamais envoyées à PulseExplorer.
class ProviderCredentials {
  static const _openRouterKey = 'pulse_explorer.provider.openrouter.api_key';
  static const _geminiKey = 'pulse_explorer.provider.gemini.api_key';
  static const _mistralKey = 'pulse_explorer.provider.mistral.api_key';
  static const _groqKey = 'pulse_explorer.provider.groq.api_key';

  static Future<String> load(String providerId) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_keyFor(providerId)) ?? '').trim();
  }

  static Future<void> save(String providerId, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyFor(providerId), apiKey.trim());
  }

  static Future<bool> hasKey(String providerId) async => (await load(providerId)).isNotEmpty;

  static String _keyFor(String providerId) {
    switch (providerId) {
      case 'openrouter':
        return _openRouterKey;
      case 'gemini':
        return _geminiKey;
      case 'mistral':
        return _mistralKey;
      case 'groq':
        return _groqKey;
      default:
        return 'pulse_explorer.provider.$providerId.api_key';
    }
  }
}
