import 'ai_provider.dart';
import 'gemini_provider.dart';
import 'openai_compatible_provider.dart';
import 'openrouter_provider.dart';

/// Résultat d'un test de connexion à un provider IA.
class ProviderTestResult {
  final bool success;
  final String message;
  final Duration elapsed;

  const ProviderTestResult({
    required this.success,
    required this.message,
    required this.elapsed,
  });
}

/// Providers dont l'exécution est locale : aucune clé API n'est requise,
/// mais une URL de base (modifiable) est nécessaire.
const Set<String> kLocalProviders = {'ollama', 'lmstudio'};

/// Modèle de test par défaut pour chaque provider connu.
const Map<String, String> kDefaultTestModel = {
  'openrouter': 'openrouter/free',
  'gemini': 'gemini-1.5-flash',
  'groq': 'llama-3.1-8b-instant',
  'mistral': 'mistral-small-latest',
  'deepseek': 'deepseek-chat',
  'together': 'meta-llama/Llama-3.3-70B-Instruct-Turbo-Free',
  'fireworks': 'accounts/fireworks/models/llama-v3p1-8b-instruct',
  'cerebras': 'llama3.1-8b',
  'sambanova': 'Meta-Llama-3.1-8B-Instruct',
  'ollama': 'llama3.1',
  'lmstudio': 'local-model',
};

/// URL de base par défaut pour les providers compatibles OpenAI.
const Map<String, String> kDefaultBaseUrl = {
  'groq': 'https://api.groq.com/openai/v1',
  'mistral': 'https://api.mistral.ai/v1',
  'deepseek': 'https://api.deepseek.com/v1',
  'together': 'https://api.together.xyz/v1',
  'fireworks': 'https://api.fireworks.ai/inference/v1',
  'cerebras': 'https://api.cerebras.ai/v1',
  'sambanova': 'https://api.sambanova.ai/v1',
  'ollama': 'http://localhost:11434/v1',
  'lmstudio': 'http://localhost:1234/v1',
};

/// Construit un [AiProvider] et exécute un appel minimal pour valider une
/// clé API (ou une URL locale). Le test n'est JAMAIS déclenché
/// automatiquement à la saisie : il doit être lancé explicitement (bouton
/// "Tester la connexion"), afin d'éviter les erreurs affichées
/// prématurément pendant que l'utilisateur tape encore sa clé.
class ProviderTestService {
  const ProviderTestService();

  AiProvider? buildProvider({
    required String providerId,
    required String apiKey,
    required String model,
    String? baseUrl,
  }) {
    final key = apiKey.trim();
    final isLocal = kLocalProviders.contains(providerId);
    if (!isLocal && key.isEmpty) return null;

    final effectiveModel =
        model.trim().isNotEmpty ? model.trim() : kDefaultTestModel[providerId];
    if (effectiveModel == null) return null;
    final effectiveBaseUrl = (baseUrl?.trim().isNotEmpty ?? false)
        ? baseUrl!.trim()
        : kDefaultBaseUrl[providerId];

    switch (providerId) {
      case 'openrouter':
        return OpenRouterProvider(model: effectiveModel, apiKey: key);
      case 'gemini':
        return GeminiProvider(model: effectiveModel, apiKey: key);
      case 'groq':
      case 'mistral':
      case 'deepseek':
      case 'together':
      case 'fireworks':
      case 'cerebras':
      case 'sambanova':
      case 'ollama':
      case 'lmstudio':
        if (effectiveBaseUrl == null) return null;
        return OpenAiCompatibleProvider(
          id: '$providerId:$effectiveModel',
          name: '$providerId — $effectiveModel',
          model: effectiveModel,
          // Les providers locaux n'exigent pas de clé : on passe une
          // valeur non vide neutre pour satisfaire l'API HTTP (souvent
          // ignorée par le serveur local).
          apiKey: key.isEmpty && isLocal ? 'local' : key,
          baseUrl: effectiveBaseUrl,
        );
      default:
        return null;
    }
  }

  Future<ProviderTestResult> test({
    required String providerId,
    required String apiKey,
    required String model,
    String? baseUrl,
  }) async {
    final stopwatch = Stopwatch()..start();
    final isLocal = kLocalProviders.contains(providerId);

    if (!isLocal && apiKey.trim().isEmpty) {
      stopwatch.stop();
      return ProviderTestResult(
        success: false,
        message: 'Saisissez une clé API avant de tester la connexion.',
        elapsed: stopwatch.elapsed,
      );
    }

    final provider = buildProvider(
      providerId: providerId,
      apiKey: apiKey,
      model: model,
      baseUrl: baseUrl,
    );
    if (provider == null) {
      stopwatch.stop();
      return ProviderTestResult(
        success: false,
        message: 'Provider "$providerId" inconnu ou configuration incomplète.',
        elapsed: stopwatch.elapsed,
      );
    }

    try {
      final outcome = await provider.test().timeout(const Duration(seconds: 30));
      stopwatch.stop();
      return ProviderTestResult(
        success: outcome.success,
        message: outcome.success
            ? 'Connexion réussie (${stopwatch.elapsedMilliseconds} ms).'
            : _friendlyError(outcome.message),
        elapsed: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      return ProviderTestResult(
        success: false,
        message: _friendlyError(e),
        elapsed: stopwatch.elapsed,
      );
    }
  }

  String _friendlyError(Object e) {
    final raw = '$e';
    if (raw.contains('401') || raw.contains('403')) {
      return 'Clé API refusée (401/403). Vérifiez la clé saisie.';
    }
    if (raw.contains('429')) {
      return 'Quota atteint (429). Réessayez plus tard.';
    }
    if (raw.contains('TimeoutException')) {
      return 'Délai dépassé : le provider n\'a pas répondu à temps (vérifiez qu\'il est bien lancé si local).';
    }
    if (raw.contains('SocketException') || raw.contains('Connection refused')) {
      return 'Connexion impossible : vérifiez l\'URL / que le serveur local est démarré.';
    }
    return raw.replaceFirst('Exception: ', '');
  }
}
