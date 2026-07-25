/// Abstraction commune pour les fournisseurs de modèles IA.
abstract class AiProvider {
  String get id;
  String get name;
  String get model;
  bool get freeOnly;

  Future<String> complete({
    required String systemPrompt,
    required String userPrompt,
  });
}
