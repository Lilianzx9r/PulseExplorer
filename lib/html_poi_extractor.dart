import 'dart:convert';
import 'package:http/http.dart' as http;
import 'poi_layer.dart';
import 'app_dirs.dart';
import 'poi_ai_common.dart';
import 'core/services/geocoding_service.dart';
import 'core/services/poi_enrichment_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  ETAPE 1 : extraction locale des fragments geographiques
// ─────────────────────────────────────────────────────────────────────────────

class LocalGeoExtractor {

  static String stripHtml(String html) {
    var t = html
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>',  dotAll: true), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&amp;',  '&').replaceAll('&lt;',   '<')
        .replaceAll('&gt;',   '>').replaceAll('&nbsp;', ' ')
        .replaceAll('&#39;',  "'").replaceAll('&quot;', '"')
        .replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  static GeoFragments extract(String rawText) {
    final text = rawText.length > 50000 ? rawText.substring(0, 50000) : rawText;
    final coords    = _extractCoords(text);
    final addresses = _extractAddresses(text);
    final geoNames  = _extractGeoNames(text);
    final sentences = _extractGeoSentences(text, geoNames);
    return GeoFragments(coords: coords, addresses: addresses,
        geoNames: geoNames, sentences: sentences);
  }

  static List<CoordFragment> _extractCoords(String text) {
    final results = <CoordFragment>[];
    final patterns = [
      // 48.8566, 2.3522
      RegExp(r'(-?\d{1,3}\.\d{4,8})[,\s]+(-?\d{1,3}\.\d{4,8})'),
      // lat: 48.8566 lon: 2.3522
      RegExp(r'lat[itude]*[\s:=]+(-?\d{1,3}\.\d+)[\s,;]+lon[gitude]*[\s:=]+(-?\d{1,3}\.\d+)',
          caseSensitive: false),
    ];
    for (final p in patterns) {
      for (final m in p.allMatches(text)) {
        try {
          final lat = double.parse(m.group(1)!);
          final lon = double.parse(m.group(2)!);
          if (lat < -90 || lat > 90 || lon < -180 || lon > 180) continue;
          final start   = (m.start - 50).clamp(0, text.length);
          final context = text.substring(start, m.end).trim();
          results.add(CoordFragment(lat: lat, lon: lon, context: context));
        } catch (_) {}
      }
    }
    return results;
  }

  static List<String> _extractAddresses(String text) {
    final results = <String>{};
    // Numero + rue (ASCII only pour eviter problemes encodage)
    final reStreet = RegExp(
        r'\d{1,4}[\s,]+(?:rue|avenue|boulevard|allee|chemin|route|impasse|place|'
        r'calle|carrer|via|piazza|strada|road|street|lane|drive|way)'
        r'[^.!?\n]{3,50}',
        caseSensitive: false);
    for (final m in reStreet.allMatches(text)) {
      results.add(m.group(0)!.trim());
    }
    // Code postal + ville
    final rePostal = RegExp(r'\b(\d{4,5})\s+([A-Za-z][A-Za-z\s\-]{2,30})\b');
    for (final m in rePostal.allMatches(text)) {
      final candidate = m.group(0)!.trim();
      if (candidate.length > 5) results.add(candidate);
    }
    return results.take(20).toList();
  }

  static List<String> _extractGeoNames(String text) {
    final results = <String>{};
    // Mots-cles geographiques (ASCII uniquement dans le pattern)
    final reKeyword = RegExp(
        r'(?:col|lac|mont|sierra|pico|embalse|puerto|pass|peak|lake|mount|'
        r'valley|town|city|village|gorge|canyon)\s+'
        r'(?:de|du|del|di|of|la|le|les|el|los|las)?\s*'
        r'([A-Z][a-zA-Z\s\-]{2,30})',
        caseSensitive: false);
    for (final m in reKeyword.allMatches(text)) {
      final name = m.group(1)?.trim();
      if (name != null && name.length > 2) results.add(name);
    }
    // Noms propres apres ponctuation
    final reProper = RegExp(r'(?:[,;()\n])\s*([A-Z][a-zA-Z\-]{2,}(?:\s+[A-Z][a-zA-Z\-]{1,})*)');
    for (final m in reProper.allMatches(text)) {
      final name = m.group(1)?.trim();
      if (name != null && name.length > 3 && !_isCommonWord(name)) {
        results.add(name);
      }
    }
    return results.take(30).toList();
  }

  static List<String> _extractGeoSentences(String text, List<String> geoNames) {
    final sentences = text.split(RegExp(r'[.!?\n]'));
    // Mots-cles geographiques en ASCII
    final geoKeywords = RegExp(
        r'\b(hotel|auberge|camping|refuge|restaurant|col|montagne|lac|'
        r'riviere|gorge|canyon|chateau|eglise|'
        r'km|kilometre|altitude|coordonnees|GPS)\b',
        caseSensitive: false);
    final results = <String>[];
    for (final s in sentences) {
      final trimmed = s.trim();
      if (trimmed.length < 10 || trimmed.length > 300) continue;
      if (geoKeywords.hasMatch(trimmed)) {
        results.add(trimmed);
      } else if (geoNames.any((n) => trimmed.contains(n))) {
        results.add(trimmed);
      }
    }
    return results.take(40).toList();
  }

  static bool _isCommonWord(String w) {
    const common = {'Le', 'La', 'Les', 'Un', 'Une', 'Des', 'Du', 'De',
        'Et', 'Ou', 'Pour', 'Dans', 'Sur', 'Avec', 'Par', 'En',
        'Ce', 'Se', 'Il', 'Elle', 'Ils', 'Nous', 'Vous'};
    return common.contains(w);
  }
}

class CoordFragment {
  final double lat, lon;
  final String context;
  CoordFragment({required this.lat, required this.lon, required this.context});
}

class GeoFragments {
  final List<CoordFragment> coords;
  final List<String>        addresses;
  final List<String>        geoNames;
  final List<String>        sentences;

  GeoFragments({required this.coords, required this.addresses,
      required this.geoNames, required this.sentences});

  bool get isEmpty => coords.isEmpty && addresses.isEmpty &&
      geoNames.isEmpty && sentences.isEmpty;

  String get summary =>
      '${coords.length} coords GPS, ${addresses.length} adresses, '
      '${geoNames.length} noms geo, ${sentences.length} phrases';

  String toCompactText() {
    final buf = StringBuffer();
    if (coords.isNotEmpty) {
      buf.writeln('=COORDONNEES GPS=');
      for (final c in coords) buf.writeln('${c.lat},${c.lon} [${c.context}]');
    }
    if (addresses.isNotEmpty) {
      buf.writeln('=ADRESSES=');
      buf.writeln(addresses.join('\n'));
    }
    if (geoNames.isNotEmpty) {
      buf.writeln('=NOMS GEOGRAPHIQUES=');
      buf.writeln(geoNames.join(', '));
    }
    if (sentences.isNotEmpty) {
      buf.writeln('=PHRASES GEOGRAPHIQUES=');
      buf.writeln(sentences.join('\n'));
    }
    return buf.toString().trim();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  ETAPE 2 : finalisation via OpenRouter
// ─────────────────────────────────────────────────────────────────────────────

class HtmlPoiExtractor {

  /// Nettoie le HTML/texte brut — utilisé pour préparer le texte avant copie
  /// vers un agent IA externe (même nettoyage que pour l'IA interne).
  static String stripHtmlForPrompt(String input) => LocalGeoExtractor.stripHtml(input);

  static const List<({String id, String label})> kFreeModels = [
    // ★★★★★ Excellent extraction POI + géolocalisation web
    (id: 'meta-llama/llama-3.3-70b-instruct:free',
     label: 'Llama 3.3 70B (Meta) ★★★★★'),
    (id: 'google/gemma-3-27b-it:free',
     label: 'Gemma 3 27B (Google) ★★★★★'),
    // ★★★★☆ Très bon, excellent en français
    (id: 'mistralai/mistral-small-3.2-24b-instruct:free',
     label: 'Mistral Small 3.2 24B ★★★★☆'),
    (id: 'qwen/qwen3-235b-a22b:free',
     label: 'Qwen3 235B ★★★★☆'),
    (id: 'deepseek/deepseek-v3:free',
     label: 'DeepSeek V3 ★★★★☆'),
    // ★★★☆☆ Correct, peut halluciner les coords
    (id: 'deepseek/deepseek-r1:free',
     label: 'DeepSeek R1 ★★★☆☆'),
    (id: 'qwen/qwen3-30b-a3b:free',
     label: 'Qwen3 30B MoE ★★★☆☆'),
    (id: 'microsoft/phi-4-reasoning-plus:free',
     label: 'Phi-4 Reasoning ★★★☆☆'),
    // ★★☆☆☆ Rapide mais moins précis sur les coords
    (id: 'qwen/qwen3-8b:free',
     label: 'Qwen3 8B ★★☆☆☆ (rapide)'),
    (id: 'google/gemma-3n-e4b-it:free',
     label: 'Gemma 3n 4B ★★☆☆☆ (rapide)'),
  ];

  static String _selectedModel = kFreeModels.first.id;
  static String get selectedModel => _selectedModel;
  static String apiKey              = '';
  static String? _customPrompt;      // prompt personnalisé (remplace le défaut)
  static String? _editedDefaultPrompt; // prompt par défaut modifié par l'utilisateur
  static String  lastInputText = '';

  static void setModel(String modelId) { _selectedModel = modelId; _savePrefs(); }
  static void setApiKey(String key)    { apiKey = key.trim(); _savePrefs(); }
  static bool get hasApiKey            => apiKey.isNotEmpty;

  /// Dernière requête d'exploration mémorisée.
  static String get lastRequest => lastInputText;

  /// Mémorise la dernière requête et la persiste dans les préférences.
  static void setLastRequest(String value) {
    lastInputText = value;
    _savePrefs();
  }

  /// Charger les préférences au démarrage (appeler depuis main())
  static Future<void> loadPrefs() async {
    final prefs = await AppDirs.loadAiPrefs();
    if (prefs['apiKey']?.isNotEmpty == true)              apiKey               = prefs['apiKey']!;
    if (prefs['model']?.isNotEmpty == true)               _selectedModel        = prefs['model']!;
    if (prefs['customPrompt']?.isNotEmpty == true)        _customPrompt         = prefs['customPrompt'];
    if (prefs['editedDefaultPrompt']?.isNotEmpty == true) _editedDefaultPrompt  = prefs['editedDefaultPrompt'];
    if (prefs['lastInputText']?.isNotEmpty == true)       lastInputText         = prefs['lastInputText']!;
  }

  static Future<void> _savePrefs() => AppDirs.saveAiPrefs(
    apiKey:              apiKey,
    model:               _selectedModel,
    customPrompt:        _customPrompt,
    editedDefaultPrompt: _editedDefaultPrompt,
    lastInputText:       lastInputText,
  );

  /// Prompt par défaut — peut être modifié par l'utilisateur et persiste
  static String get editedDefaultPrompt => _editedDefaultPrompt ?? _builtinDefaultPrompt;
  static void setEditedDefaultPrompt(String? p) {
    _editedDefaultPrompt = (p?.trim().isEmpty ?? true) ? null : p?.trim();
    _savePrefs();
  }
  static bool get hasEditedDefaultPrompt => _editedDefaultPrompt != null;

  static String get _builtinDefaultPrompt => kCommonPoiPrompt;

  static String get activePrompt => _customPrompt ?? editedDefaultPrompt;
  static void setCustomPrompt(String? prompt) {
    _customPrompt = (prompt?.trim().isEmpty ?? true) ? null : prompt?.trim();
    _savePrefs();
  }
  static bool get hasCustomPrompt => _customPrompt != null;

  static Future<({List<PoiPoint> points, GeoFragments fragments, String aiRaw, String aiModel, int aiCount, int localCount})> extract(
      String input) async {

    final cleaned   = LocalGeoExtractor.stripHtml(input);
    // Mémoriser le texte pour restauration au prochain démarrage
    lastInputText = input;
    _savePrefs();
    final fragments = LocalGeoExtractor.extract(cleaned);

    // Coordonnées GPS explicites → POI directs
    // Respecte le prompt : si prompt personnalisé actif, on saute l'extraction locale
    // et laisse l'IA tout gérer (le prompt "Ne fait rien" doit bloquer tout)
    final directPois = <PoiPoint>[];
    if (!hasCustomPrompt) {
      // Extraction locale uniquement si pas de prompt personnalisé
      for (final coord in fragments.coords) {
        final ctx = coord.context;
        String name = '';

        // Tentative 1 : expression entre guillemets ou parenthèses
        final quoted = RegExp(r'''["'(]([^"')
]{3,40})["')]''').firstMatch(ctx);
        if (quoted != null) name = quoted.group(1)!.trim();

        // Tentative 2 : séquence de mots capitalisés (nom propre)
        if (name.isEmpty) {
          final titleCase = RegExp(
              r'([A-ZÁÉÈÊÀÙÎÔÛÄËÏÖÜ][a-záéèêàùîôûäëïöü]+(?:[ -][A-ZÁÉÈÊÀÙÎÔÛÄËÏÖÜ][a-záéèêàùîôûäëïöü]+){0,4})')
              .allMatches(ctx)
              .map((m) => m.group(0)!)
              .where((w) => !RegExp(
                  r'^(Le|La|Les|Du|Des|De|Et|En|Au|Aux|Un|Une|Sur|Sous)$',
                  caseSensitive: false).hasMatch(w))
              .where((w) => w.length > 4)
              .toList();
          if (titleCase.isNotEmpty) name = titleCase.last;
        }

        // Tentative 3 : dernier mot alphabétique avant les chiffres des coords
        if (name.isEmpty) {
          final beforeCoord = ctx.split(RegExp(r'\d{1,3}[.,]\d')).first;
          final words2 = beforeCoord.trim().split(RegExp(r'\s+')).reversed
              .where((w) => w.length > 3 && RegExp(r'[a-zA-Z]').hasMatch(w))
              .toList();
          if (words2.isNotEmpty) {
            name = words2.first.replaceAll(RegExp(r"[^a-zA-ZÀ-ÿ\-']"), '');
          }
        }

        if (name.isEmpty) name = 'Point ${directPois.length + 1}';

        directPois.add(PoiPoint(
            name: name, lat: coord.lat, lon: coord.lon,
            description: ctx.length > 80 ? ctx.substring(0, 80) : ctx,
            type: 'coord'));
      }
    }

    // Si aucun fragment détecté localement mais texte non vide + clé API → laisser l'IA analyser
    if (fragments.isEmpty && !hasApiKey) {
      if (directPois.isNotEmpty) return (points: directPois, fragments: fragments, aiRaw: '', aiModel: '', aiCount: 0, localCount: directPois.length);
      throw Exception('Aucune information geographique detectee dans le texte.');
    }

    if (!hasApiKey) {
      // Sans cle API : retourner seulement les coords directes + message
      if (directPois.isNotEmpty) return (points: directPois, fragments: fragments, aiRaw: '', aiModel: '', aiCount: 0, localCount: directPois.length);
      throw Exception(
          'Cle API OpenRouter requise pour analyser ce texte.\n'
          'Creez un compte gratuit sur openrouter.ai et entrez votre cle dans Parametres IA.');
    }

    // Envoi a OpenRouter
    // IMPORTANT : on envoie le TEXTE COMPLET nettoyé à l'IA, pas seulement les
    // fragments extraits par regex (compactText). Les fragments locaux ne
    // servent qu'aux POI "directs" (coordonnées GPS explicites) ci-dessus —
    // l'IA a besoin du contexte complet pour identifier monuments, quartiers,
    // points de vue, etc. même quand la regex locale ne trouve rien.
    final compactText = fragments.toCompactText();
    final aiSourceText = cleaned.isNotEmpty ? cleaned : compactText;
    if (aiSourceText.isEmpty) return (points: directPois, fragments: fragments, aiRaw: '', aiModel: '', aiCount: 0, localCount: directPois.length);

    // Chunking si texte long (>5000 chars) → plusieurs appels IA fusionnés
    const maxChunkChars = 5000;
    List<PoiPoint> allAiPois = [];
    String lastRaw = '';

    final chunks = aiSourceText.length <= maxChunkChars
        ? [aiSourceText]
        : _splitIntoChunks(aiSourceText, maxChunkChars);

    for (int chunkIdx = 0; chunkIdx < chunks.length; chunkIdx++) {
      final chunk = chunks[chunkIdx];
      final chunkSuffix = chunks.length > 1
          ? ' [partie ${chunkIdx+1}/${chunks.length}]' : '';
      // activePrompt se termine déjà par "Texte à analyser :\n" — ne pas dupliquer
      final prompt = chunkSuffix.isEmpty
          ? '$activePrompt$chunk'
          : '$activePrompt$chunkSuffix\n$chunk';
      try {
        final response = await http.post(
          Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
          headers: {
            'Content-Type':  'application/json',
            'Authorization': 'Bearer $apiKey',
            'HTTP-Referer':  'https://github.com/gpx-overlay',
            'X-Title':       'PulseGpx App',
          },
          body: json.encode({
            'model':      _selectedModel,
            'max_tokens': 4000,
            'messages':   [{'role': 'user', 'content': prompt}],
          }),
        ).timeout(const Duration(seconds: 90));
        if (response.statusCode != 200) {
          throw Exception('Erreur OpenRouter (${response.statusCode}):\n${response.body}');
        }
        final data    = json.decode(response.body);
        final content = data['choices'][0]['message']['content'] as String;
        allAiPois.addAll(_parsePoiJson(content));
        lastRaw = content;
      } on Exception catch (e) {
        if (e.toString().contains('TimeoutException') && chunks.length > 1) {
          lastRaw = '⚠️ Timeout partie ${chunkIdx+1}';
          continue;
        }
        rethrow;
      }
      if (chunkIdx < chunks.length - 1)
        await Future.delayed(const Duration(seconds: 2));
    }

    // Résoudre les coordonnées manquantes (lat==0 && lon==0) via Nominatim
    // Les POI non résolus restent dans la liste avec lat=0/lon=0 et description ⚠️
    final merged = _deduplicate([...directPois, ...allAiPois]);
    final needsGeocode = merged.any((p) => p.lat == 0.0 && p.lon == 0.0);
    final finalPoints = needsGeocode
        ? await _geocodeMissing(merged)
        : merged;

    return (
      points:     finalPoints,
      fragments:  fragments,
      aiRaw:      lastRaw,
      aiModel:    _selectedModel,
      aiCount:    allAiPois.length,
      localCount: directPois.length,
    );
  }

  /// Résout les coords manquantes via Nominatim pour les POI lat==0/lon==0
  static Future<List<PoiPoint>> _geocodeMissing(List<PoiPoint> pts) async {
    final result = <PoiPoint>[];
    for (final p in pts) {
      if (p.lat != 0.0 || p.lon != 0.0) {
        result.add(p);
        continue;
      }
      // Recherche Nominatim
      final found = await _nominatimSearch(p.name);
      if (found != null) {
        result.add(p.copyWith(lat: found.$1, lon: found.$2));
      } else {
        // Marquer clairement comme introuvable — lat/lon restent 0
        result.add(p.copyWith(
          description: '⚠️ Coordonnées introuvables'
              '${p.description != null ? " · ${p.description}" : ""}',
        ));
      }
      await Future.delayed(const Duration(milliseconds: 1100));
    }
    return result;
  }

  static Future<(double, double)?> _nominatimSearch(String query) =>
      GeocodingService.geocodeSingle(query, timeout: const Duration(seconds: 6));

  /// Enrichit les POI extraits avec une photo (DuckDuckGo + Wikimedia
  /// Commons) quand ils n'en ont pas déjà une.
  ///
  /// Avant la refonte, ce pipeline (extraction HTML) laissait `photoUrls`
  /// systématiquement vide alors que le pipeline blog (blog_poi_service.dart)
  /// recherchait bien une photo — incohérence corrigée en réutilisant ici le
  /// même PoiEnrichmentService que partout ailleurs dans l'app.
  static Future<List<PoiPoint>> enrichPhotos(
    List<PoiPoint> points, {
    void Function(int done, int total)? onProgress,
  }) async {
    final result = <PoiPoint>[];
    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      onProgress?.call(i, points.length);
      if (p.hasPhotos || (p.lat == 0.0 && p.lon == 0.0)) {
        result.add(p);
        continue;
      }
      final photos = await PoiEnrichmentService.searchPhotos(p.name);
      result.add(photos.isEmpty ? p : p.copyWith(photoUrls: photos));
      await Future.delayed(const Duration(milliseconds: 300));
    }
    onProgress?.call(points.length, points.length);
    return result;
  }

  static List<String> _splitIntoChunks(String text, int maxChars) {
    final chunks  = <String>[];
    final lines   = text.split('\n');
    final current = StringBuffer();
    for (final line in lines) {
      if (current.length + line.length + 1 > maxChars && current.isNotEmpty) {
        chunks.add(current.toString().trim());
        current.clear();
      }
      current.write('$line\n');
    }
    if (current.isNotEmpty) chunks.add(current.toString().trim());
    return chunks.isEmpty ? [text] : chunks;
  }


  static List<PoiPoint> _parsePoiJson(String raw) {
    // 1. Supprimer balises <think>...</think> (DeepSeek R1, etc.)
    var cleaned = raw.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
    // 2. Supprimer fences markdown
    cleaned = cleaned.trim()
        .replaceFirst(RegExp(r'^```json?\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();

    List<dynamic>? list;

    // Tentative 1 : array direct [ ... ]
    final arrStart = cleaned.indexOf('[');
    final arrEnd   = cleaned.lastIndexOf(']');
    if (arrStart >= 0 && arrEnd > arrStart) {
      try { list = json.decode(cleaned.substring(arrStart, arrEnd + 1)) as List; }
      catch (_) {}
    }

    // Tentative 2 : objet { "pois": [...] } ou similaire
    if (list == null) {
      final objStart = cleaned.indexOf('{');
      final objEnd   = cleaned.lastIndexOf('}');
      if (objStart >= 0 && objEnd > objStart) {
        try {
          final obj = json.decode(cleaned.substring(objStart, objEnd + 1)) as Map;
          for (final key in ['pois','points','locations','places','results','data','items']) {
            if (obj[key] is List) { list = obj[key] as List; break; }
          }
          if (list == null) {
            for (final v in obj.values) { if (v is List) { list = v; break; } }
          }
        } catch (_) {}
      }
    }

    if (list == null) return [];

    const genericNames = {'poi','point','coordonnées','coordonnees',
        'lieu','location','place','','null','undefined','unknown','inconnu','n/a','na'};
    final points = <PoiPoint>[];

    for (final item in list) {
      if (item is! Map) continue;
      final m   = Map<String, dynamic>.from(item);
      var lat = double.tryParse(m['lat']?.toString() ?? '');
      var lon = double.tryParse(m['lon']?.toString() ?? '');
      // Coordonnées invalides → on les garde mais on les marque comme manquantes
      // (lat=0, lon=0 EST valide en mer, on utilise un sentinel 999.0)
      final hasValidCoords = lat != null && lon != null &&
          lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 &&
          !(lat == 0 && lon == 0);
      if (!hasValidCoords) { lat = null; lon = null; }

      final rawName = (m['name'] ?? m['label'] ?? m['title'] ?? '').toString().trim();
      String poiName = rawName;
      if (genericNames.contains(poiName.toLowerCase())) {
        final desc   = m['description']?.toString() ?? '';
        final titleM = RegExp(r'[A-ZÁÉÈÊÀÙÎÔÛÄËÏÖÜ][a-z]{3,}(?:[ -][A-ZÁÉÈÊÀÙÎÔÛÄËÏÖÜ][a-z]+)*')
            .firstMatch(desc);
        poiName = titleM?.group(0) ?? 'Point ${points.length + 1}';
      }
      // Construire une description enrichie avec tips, horaires, tarifs
      final desc = m['description']?.toString() ?? '';
      final tips = m['tips']?.toString() ?? '';
      final hours = m['opening_hours']?.toString() ?? '';
      final bestTime = m['best_time']?.toString() ?? '';
      final score = m['interest_score']?.toString() ?? '';
      final level = m['interest_level']?.toString() ?? '';
      final day = m['day']?.toString() ?? '';

      // Description enrichie
      final enriched = [
        if (desc.isNotEmpty) desc,
        if (tips.isNotEmpty) '💡 $tips',
        if (hours.isNotEmpty) '⏰ $hours',
        if (bestTime.isNotEmpty) '🕐 $bestTime',
        if (level.isNotEmpty) '⭐ $level${score.isNotEmpty ? " ($score/10)" : ""}',
        if (day.isNotEmpty) '📅 Jour $day',
      ].join(' · ');

      // Tags pour le type
      final rawType = m['type']?.toString() ?? 'poi';
      final mappedType = hasValidCoords ? _mapTouristType(rawType) : 'no_coords';

      points.add(PoiPoint(
          name: poiName,
          lat: lat ?? 0.0,
          lon: lon ?? 0.0,
          description: enriched.isNotEmpty ? enriched : null,
          type: mappedType,
          photoUrls: []));
    }
    return points;
  }

  static String _mapTouristType(String t) {
    const map = {
      'monument': 'monument', 'musee': 'museum', 'place': 'city',
      'parc': 'forest', 'jardin': 'forest', 'palais': 'castle',
      'marche': 'attraction', 'quartier': 'city', 'stade': 'attraction',
      'monument_religieux': 'chapel', 'site_historique': 'ruins',
      'site_naturel': 'forest', 'site_archeologique': 'ruins',
      'village': 'village', 'port': 'lake', 'plage': 'lake',
      'pont': 'monument', 'rue_pittoresque': 'city',
      'point_de_vue': 'viewpoint', 'spot_photo': 'viewpoint',
      'shopping': 'attraction', 'restaurant': 'restaurant',
      'cafe': 'cafe', 'bar': 'attraction', 'spectacle': 'attraction',
      'experience': 'attraction',
      // Anciens types conservés pour compatibilité
      'museum': 'museum', 'castle': 'castle', 'peak': 'peak',
      'waterfall': 'waterfall', 'viewpoint': 'viewpoint',
      'hotel': 'hotel', 'city': 'city', 'lake': 'lake',
    };
    return map[t] ?? 'poi';
  }

  static List<PoiPoint> _deduplicate(List<PoiPoint> pts) {
    final result = <PoiPoint>[];
    for (final p in pts) {
      final isDup = result.any((r) =>
          (r.lat - p.lat).abs() < 0.001 && (r.lon - p.lon).abs() < 0.001);
      if (!isDup) result.add(p);
    }
    return result;
  }
}
