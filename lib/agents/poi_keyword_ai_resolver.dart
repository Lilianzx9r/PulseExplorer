import 'dart:convert';

import '../overpass_poi_service.dart';
import 'agent_presets.dart';
import 'ai_provider.dart';
import 'configuration_store.dart';
import 'provider_factory.dart';

// ─────────────────────────────────────────────────────────────────────────────
// poi_keyword_ai_resolver.dart
//
// Repli optionnel quand le dictionnaire local (poi_natural_query.dart) ne
// reconnaît aucun terme. Utilise le premier provider IA déjà configuré par
// l'utilisateur (Laboratoire IA), avec un timeout court. Toute absence de
// réseau, de provider configuré, ou erreur quelconque se traduit par un
// simple `null` — l'appelant se rabat alors sur la recherche par nom brute.
// Rien n'est jamais bloquant ni signalé comme une erreur à l'utilisateur.
// ─────────────────────────────────────────────────────────────────────────────

class PoiKeywordAiResolver {
  PoiKeywordAiResolver._();

  static Future<List<String>?> resolveCategoryIds(
    String query, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    try {
      final factory = await ProviderFactory.load();

      // Priorité aux agents que l'utilisateur a lui-même configurés dans le
      // Laboratoire IA (provider/modèle qu'il a testés et qui fonctionnent).
      final userAgents = await AgentConfigurationStore().loadAgents();
      AiProvider? resolvedProvider;
      for (final def in userAgents) {
        if (!def.enabled) continue;
        final p = factory.create(def);
        if (p != null) { resolvedProvider = p; break; }
      }
      // Repli sur les presets par défaut (clé personnelle éventuellement
      // renseignée pour openrouter/gemini/mistral/groq sans agent dédié).
      if (resolvedProvider == null) {
        for (final def in AgentPresets.all) {
          final p = factory.create(def);
          if (p != null) { resolvedProvider = p; break; }
        }
      }

      if (resolvedProvider == null) return null; // pas de provider → repli silencieux

      final validIds = kPoiCategories.map((c) => c.id).join(', ');
      final systemPrompt = '''
Tu classes une requête de recherche de lieux en catégories connues.
Catégories valides (utilise UNIQUEMENT ces identifiants) : $validIds.
Réponds STRICTEMENT avec un tableau JSON d'identifiants (0 à 3 maximum), sans
aucun texte, explication, ni Markdown. Si aucune catégorie ne correspond,
réponds [].
''';

      final raw = await resolvedProvider
          .complete(systemPrompt: systemPrompt, userPrompt: query)
          .timeout(timeout);

      return _parseIds(raw, validIds: kPoiCategories.map((c) => c.id).toSet());
    } catch (_) {
      return null;
    }
  }

  static List<String>? _parseIds(String raw, {required Set<String> validIds}) {
    var text = raw.trim();
    text = text
        .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return null;
    text = text.substring(start, end + 1);

    try {
      final decoded = jsonDecode(text);
      if (decoded is! List) return null;
      final ids = decoded
          .map((e) => e.toString().trim())
          .where((id) => validIds.contains(id))
          .toSet()
          .toList();
      return ids;
    } catch (_) {
      return null;
    }
  }
}
