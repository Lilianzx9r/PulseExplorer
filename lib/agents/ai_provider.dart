/// Abstraction commune pour les fournisseurs de modèles IA.
///
/// Historique : cette classe ne comportait que `complete()`. Elle est
/// maintenant enrichie avec les capacités décrites dans l'architecture cible
/// (connect/test/chat/models/supportsX), sous forme d'une classe abstraite
/// avec implémentations par défaut raisonnables, afin que les providers
/// existants (`extends AiProvider`) n'aient à surcharger que ce qui les
/// distingue réellement.
abstract class AiProvider {
  const AiProvider();

  String get id;
  String get name;
  String get model;
  bool get freeOnly;

  /// Appel simple prompt système + prompt utilisateur → texte.
  /// Reste la méthode historique, utilisée par tous les agents actuels.
  Future<String> complete({
    required String systemPrompt,
    required String userPrompt,
  });

  /// Vérifie que le provider est joignable et correctement configuré
  /// (clé API présente, etc.) sans nécessairement consommer de quota.
  /// Implémentation par défaut : vérifie juste qu'une clé/modèle existent.
  /// Les providers concrets peuvent surcharger pour un vrai ping réseau.
  Future<bool> connect() async => model.trim().isNotEmpty;

  /// Test fonctionnel complet : effectue un appel minimal réel et retourne
  /// vrai si une réponse exploitable a été reçue. Par défaut, s'appuie sur
  /// [complete] avec un prompt de validation neutre.
  Future<ProviderTestOutcome> test() async {
    final started = DateTime.now();
    try {
      final reply = await complete(
        systemPrompt: 'Tu réponds uniquement par le mot OK, sans rien ajouter.',
        userPrompt: 'Réponds uniquement par OK pour valider la connexion.',
      );
      final elapsed = DateTime.now().difference(started);
      final ok = reply.trim().isNotEmpty;
      return ProviderTestOutcome(
        success: ok,
        message: ok ? 'Connexion réussie.' : 'Réponse vide reçue.',
        elapsed: elapsed,
      );
    } catch (e) {
      return ProviderTestOutcome(
        success: false,
        message: '$e',
        elapsed: DateTime.now().difference(started),
      );
    }
  }

  /// Conversation multi-tours simplifiée. Implémentation par défaut :
  /// concatène l'historique en un unique prompt utilisateur et délègue à
  /// [complete]. Les providers avec une vraie API de chat peuvent surcharger.
  Future<String> chat({
    required String systemPrompt,
    required List<ChatMessage> history,
  }) {
    final joined = history
        .map((m) => '${m.role == ChatRole.user ? 'Utilisateur' : 'Assistant'} : ${m.content}')
        .join('\n');
    return complete(systemPrompt: systemPrompt, userPrompt: joined);
  }

  /// Liste des modèles disponibles pour ce provider. Par défaut, renvoie
  /// uniquement le modèle courant : les providers avec un catalogue
  /// dynamique (ex. OpenRouter) surchargent cette méthode.
  Future<List<String>> models() async => [model];

  // Capacités déclarées. Par défaut toutes désactivées : chaque provider
  // concret surcharge celles qu'il supporte réellement. Ce sont des
  // indications pour l'UI (Laboratoire IA) et pour le choix d'un provider
  // adapté à une tâche donnée, pas des garanties absolues.
  bool supportsVision() => false;
  bool supportsTools() => false;
  bool supportsStreaming() => false;
  bool supportsJson() => false;
  bool supportsFunctionCalling() => false;
  bool supportsEmbeddings() => false;
  bool supportsReasoning() => false;
}

enum ChatRole { user, assistant }

class ChatMessage {
  final ChatRole role;
  final String content;

  const ChatMessage({required this.role, required this.content});
}

class ProviderTestOutcome {
  final bool success;
  final String message;
  final Duration elapsed;

  const ProviderTestOutcome({
    required this.success,
    required this.message,
    required this.elapsed,
  });
}
