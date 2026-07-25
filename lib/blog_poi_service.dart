import 'dart:convert';
import 'package:http/http.dart' as http;
import 'poi_layer.dart';
import 'html_poi_extractor.dart';
import 'poi_ai_common.dart';
import 'core/services/geocoding_service.dart';
import 'core/services/poi_enrichment_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Fiche POI enrichie issue de l'analyse de blog
// ─────────────────────────────────────────────────────────────────────────────
class BlogPoi {
  String  name;
  String  description;
  String  type;
  String? address;
  String? tips;          // conseil pratique issu du texte
  String? openingHours;
  double? lat;
  double? lon;
  String? imageUrl;
  String? imageCreditUrl;
  CoordSource coordSource;
  bool   selected;
  bool   isDuplicate   = false;
  String duplicateName = '';   // nom du POI existant similaire

  BlogPoi({
    required this.name,
    required this.description,
    required this.type,
    this.address,
    this.tips,
    this.openingHours,
    this.lat,
    this.lon,
    this.imageUrl,
    this.imageCreditUrl,
    this.coordSource = CoordSource.unknown,
    this.selected = true,
  });

  bool get hasCoords => lat != null && lon != null;

  PoiPoint toPoiPoint() => PoiPoint(
    name:        name,
    lat:         lat!,
    lon:         lon!,
    description: description.length > 120
        ? '${description.substring(0, 120)}…' : description,
    type:        _typeMapping[type] ?? 'poi',
    photoUrls:   imageUrl != null ? [imageUrl!] : [],
  );

  static const _typeMapping = {
    'restaurant': 'restaurant', 'hotel': 'hotel', 'monument': 'monument',
    'castle': 'castle', 'museum': 'museum', 'church': 'chapel',
    'viewpoint': 'viewpoint', 'peak': 'peak', 'park': 'forest',
    'beach': 'lake', 'market': 'attraction', 'district': 'city',
    'village': 'village', 'city': 'city', 'shop': 'attraction',
    'activity': 'attraction', 'nature': 'forest', 'street': 'city',
  };
}

enum CoordSource { nominatim, ai, both, manual, unknown }

// ─────────────────────────────────────────────────────────────────────────────
// Pipeline d'analyse blog
// ─────────────────────────────────────────────────────────────────────────────
class BlogPoiService {

  // URLs Nominatim/DuckDuckGo désormais gérées par les services core/services/

  /// Étape 1 : analyse IA enrichie du texte de blog
  /// Le prompt demande titre, description, tips, type, adresse, coords si dispo
  static Future<List<BlogPoi>> analyzeText(String text) async {
    if (!HtmlPoiExtractor.hasApiKey) {
      throw Exception('Clé API OpenRouter requise');
    }

    final prompt = kCommonPoiPrompt;

    // Chunking : découper le texte si trop long (>5000 chars)
    const maxChunkChars = 5000;
    final chunks = text.length <= maxChunkChars
        ? [text]
        : _splitIntoChunks(text, maxChunkChars);

    final allPois = <BlogPoi>[];
    for (int ci = 0; ci < chunks.length; ci++) {
      final chunkText = chunks[ci];
      final suffix = chunks.length > 1 ? ' [partie ${ci+1}/${chunks.length}]' : '';
      final body = jsonEncode({
        'model':       HtmlPoiExtractor.selectedModel,
        'max_tokens':  6000,
        'temperature': 0.1,
        'messages': [{'role': 'user', 'content': '$prompt$suffix\n$chunkText'}],
      });
      try {
        final resp = await http.post(
          Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
          headers: {
            'Content-Type':  'application/json',
            'Authorization': 'Bearer ${HtmlPoiExtractor.apiKey}',
            'HTTP-Referer':  'https://pulsegpx.app',
          },
          body: body,
        ).timeout(const Duration(seconds: 90));

        if (resp.statusCode != 200) {
          throw Exception('Erreur OpenRouter (${resp.statusCode}): ${resp.body}');
        }
        final data    = jsonDecode(resp.body) as Map;
        final content = (data['choices'] as List).first['message']['content'] as String;
        allPois.addAll(_parseBlogPois(content));
      } on Exception catch (e) {
        // Sur timeout d'un chunk : continuer avec le suivant
        if (e.toString().contains('TimeoutException') && chunks.length > 1) continue;
        rethrow;
      }
      if (ci < chunks.length - 1)
        await Future.delayed(const Duration(seconds: 2));
    }
    return allPois;
  }

  /// Parse un JSON structuré au format "touriste" (madrid_pois_complet.json)
  /// Accepte : { "pois": [...] } ou directement [ ... ]
  /// Chaque item peut avoir : name, nom, type, lat/latitude, lon/longitude,
  /// description, tips/conseils, interet.global/interest_score, etc.
  static List<BlogPoi> parseStructuredJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      List<dynamic> items;

      if (decoded is List) {
        items = decoded;
      } else if (decoded is Map) {
        // { "pois": [...] } ou { "destination":..., "pois": [...] }
        items = decoded['pois'] as List? ??
                decoded['points'] as List? ??
                decoded['places'] as List? ?? [];
      } else {
        return [];
      }

      return items.whereType<Map>().map((m) {
        // Coordonnées : lat/latitude, lon/longitude/lng
        final lat = double.tryParse(
            (m['lat'] ?? m['latitude'] ?? '').toString());
        final lon = double.tryParse(
            (m['lon'] ?? m['longitude'] ?? m['lng'] ?? '').toString());

        // Nom : name ou nom
        final name = (m['name'] ?? m['nom'] ?? '').toString().trim();
        if (name.isEmpty) return null;

        // Type
        final type = (m['type'] ?? m['category'] ?? 'poi').toString();

        // Description enrichie
        final desc  = (m['description'] ?? '').toString();
        final tips  = (m['tips'] ?? _extractConseils(m)).toString();
        final hours = (m['opening_hours'] ?? m['horaires']?['ouverture'] ?? '').toString();
        final best  = (m['best_time'] ?? m['visite']?['meilleur_moment'] ?? '').toString();

        // Score d'intérêt
        final score  = double.tryParse(
            (m['interest_score'] ?? m['interet']?['global'] ?? '').toString());
        final level  = (m['interest_level'] ?? m['interet']?['niveau'] ?? '').toString();

        // Durée
        final durMin = int.tryParse(
            (m['visit_duration_min'] ?? m['visite']?['duree_minutes'] ?? '').toString());

        // Image query
        final imgQ = (m['image_query'] ?? m['image']?['query'] ?? '').toString();

        // Jour dans l'itinéraire
        final day = (m['day'] ?? '').toString();

        // Tags
        final tags = (m['tags'] as List? ?? []).map((t) => t.toString()).toList();

        final isFree = m['price_free'] ?? m['tarifs']?['gratuit'];
        final priceA = double.tryParse(
            (m['price_adult'] ?? m['tarifs']?['adulte'] ?? '').toString());

        // Description complète
        final parts = <String>[
          if (desc.isNotEmpty) desc,
          if (tips.isNotEmpty) '💡 $tips',
          if (hours.isNotEmpty) '⏰ $hours',
          if (best.isNotEmpty) '🕐 Idéal : $best',
          if (durMin != null) '⏱ ~${durMin}min',
          if (level.isNotEmpty) '⭐ $level${score != null ? " (${score.toStringAsFixed(1)}/10)" : ""}',
          if (priceA != null && priceA > 0) '💶 ${priceA.toStringAsFixed(0)}€',
          if (isFree == true) '🆓 Gratuit',
          if (tags.isNotEmpty) '🏷 ${tags.join(", ")}',
          if (day.isNotEmpty) '📅 Jour $day',
        ];

        return BlogPoi(
          name:        name,
          description: parts.isNotEmpty ? parts.join(' · ') : (desc.isNotEmpty ? desc : name),
          type:        type,
          tips:        tips.isNotEmpty ? tips : null,
          lat:         (lat != null && lat >= -90 && lat <= 90) ? lat : null,
          lon:         (lon != null && lon >= -180 && lon <= 180) ? lon : null,
          coordSource: (lat != null && lon != null) ? CoordSource.ai : CoordSource.unknown,
          imageUrl:    imgQ.isNotEmpty ? null : null,  // sera rempli par fetchImages
        );
      }).whereType<BlogPoi>().toList();
    } catch (e) {
      return [];
    }
  }

  static String _extractConseils(Map m) {
    final conseils = m['conseils'] as List?;
    if (conseils != null && conseils.isNotEmpty) {
      return conseils.take(2).join(', ');
    }
    return '';
  }

  static List<BlogPoi> _parseBlogPois(String raw) {
    // Nettoyer balises think + markdown
    var cleaned = raw.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
    cleaned = cleaned.trim()
        .replaceFirst(RegExp(r'^```json?\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();

    List<dynamic>? list;
    final arrStart = cleaned.indexOf('[');
    final arrEnd   = cleaned.lastIndexOf(']');
    if (arrStart >= 0 && arrEnd > arrStart) {
      try { list = jsonDecode(cleaned.substring(arrStart, arrEnd + 1)) as List; }
      catch (_) {}
    }
    if (list == null) {
      final objStart = cleaned.indexOf('{');
      final objEnd   = cleaned.lastIndexOf('}');
      if (objStart >= 0 && objEnd > objStart) {
        try {
          final obj = jsonDecode(cleaned.substring(objStart, objEnd + 1)) as Map;
          for (final key in ['pois','places','locations','items','results','data']) {
            if (obj[key] is List) { list = obj[key] as List; break; }
          }
        } catch (_) {}
      }
    }
    if (list == null) return [];

    return list.whereType<Map>().map((m) {
      final lat = double.tryParse(m['lat']?.toString() ?? '');
      final lon = double.tryParse(m['lon']?.toString() ?? '');
      final valid = lat != null && lon != null &&
          lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
      return BlogPoi(
        name:         (m['name'] ?? '').toString().trim(),
        description:  (m['description'] ?? '').toString().trim(),
        type:         (m['type'] ?? 'poi').toString(),
        address:      m['address']?.toString(),
        tips:         m['tips']?.toString(),
        openingHours: m['opening_hours']?.toString(),
        lat:  valid ? lat : null,
        lon:  valid ? lon : null,
        coordSource: valid ? CoordSource.ai : CoordSource.unknown,
      );
    }).where((p) => p.name.isNotEmpty).toList();
  }

  /// Étape 2 : résolution des coordonnées via Nominatim
  static Future<void> resolveCoords(List<BlogPoi> pois,
      {void Function(int done, int total)? onProgress}) async {
    final needsCoords = pois.where((p) => !p.hasCoords || p.coordSource == CoordSource.ai).toList();
    for (int i = 0; i < needsCoords.length; i++) {
      final poi = needsCoords[i];
      onProgress?.call(i, needsCoords.length);
      try {
        final result = await _nominatimSearch(poi.name);
        if (result != null) {
          if (poi.coordSource == CoordSource.ai) {
            // Croiser Nominatim + IA : si trop différent (>50km), garder Nominatim
            final dist = _distKm(poi.lat!, poi.lon!, result.$1, result.$2);
            if (dist < 50) {
              // Proche : moyenne pondérée — Nominatim plus fiable
              poi.lat = (poi.lat! * 0.3 + result.$1 * 0.7);
              poi.lon = (poi.lon! * 0.3 + result.$2 * 0.7);
              poi.coordSource = CoordSource.both;
            } else {
              poi.lat = result.$1;
              poi.lon = result.$2;
              poi.coordSource = CoordSource.nominatim;
            }
          } else {
            poi.lat = result.$1;
            poi.lon = result.$2;
            poi.coordSource = CoordSource.nominatim;
          }
        }
      } catch (_) {}
      // Respecter le rate limit Nominatim (1 req/s)
      await Future.delayed(const Duration(milliseconds: 1100));
    }
    onProgress?.call(needsCoords.length, needsCoords.length);
  }

  /// Délègue au service de géocodage unique (GeocodingService).
  static Future<(double, double)?> _nominatimSearch(String query) =>
      GeocodingService.geocodeSingle(query);

  /// Étape 3 : recherche d'images DuckDuckGo
  static Future<void> fetchImages(List<BlogPoi> pois,
      {void Function(int done, int total)? onProgress}) async {
    for (int i = 0; i < pois.length; i++) {
      final poi = pois[i];
      onProgress?.call(i, pois.length);
      if (!poi.hasCoords) continue;
      try {
        final url = await _ddgImageSearch(poi.name);
        if (url != null) poi.imageUrl = url;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    }
    onProgress?.call(pois.length, pois.length);
  }

  /// Délègue au service d'enrichissement POI unique (PoiEnrichmentService).
  static Future<String?> _ddgImageSearch(String query) =>
      PoiEnrichmentService.searchImageDuckDuckGo(query);

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

  /// Détecte les doublons par rapport aux POI existants
  /// (distance < 100m OU similarité de nom > 80%)
  static void checkDuplicates(
      List<BlogPoi> newPois, List<PoiPoint> existingPois) {
    for (final bp in newPois) {
      if (!bp.hasCoords) continue;
      for (final ep in existingPois) {
        final dist = _distKm(bp.lat!, bp.lon!, ep.lat, ep.lon) * 1000;
        if (dist < 100) {
          bp.isDuplicate   = true;
          bp.duplicateName = ep.name;
          break;
        }
        if (_nameSimilarity(bp.name, ep.name) > 0.8) {
          bp.isDuplicate   = true;
          bp.duplicateName = ep.name;
          break;
        }
      }
    }
  }


  /// Retourne le PoiPoint existant correspondant au doublon d'un BlogPoi
  static PoiPoint? findDuplicatePoiPoint(
      BlogPoi bp, List<PoiPoint> existingPois) {
    if (!bp.hasCoords || !bp.isDuplicate) return null;
    for (final ep in existingPois) {
      final dist = _distKm(bp.lat!, bp.lon!, ep.lat, ep.lon) * 1000;
      if (dist < 100 || _nameSimilarity(bp.name, ep.name) > 0.8) return ep;
    }
    return null;
  }

  /// Distance en mètres entre deux coords — public pour html_poi_screen.dart
  static double distanceMeters(double lat1, double lon1, double lat2, double lon2) =>
      _distKm(lat1, lon1, lat2, lon2) * 1000;

  /// Similarité de nom (Dice bigrammes) — public pour html_poi_screen.dart
  static double nameSim(String a, String b) => _nameSimilarity(a, b);

  /// Recherche une image DuckDuckGo pour un nom de lieu — public
  static Future<String?> fetchImageUrl(String query) => _ddgImageSearch(query);

  static double _nameSimilarity(String a, String b) {
    final na = a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final nb = b.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (na.isEmpty || nb.isEmpty) return 0;
    if (na == nb) return 1.0;
    Set<String> bigrams(String s) {
      final set = <String>{};
      for (int i = 0; i < s.length - 1; i++) set.add(s.substring(i, i+2));
      return set;
    }
    final ba = bigrams(na), bb = bigrams(nb);
    final common = ba.intersection(bb).length;
    return 2 * common / (ba.length + bb.length);
  }

  // Distance approx entre deux points GPS (km)
  static double _distKm(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371.0;
    final dlat = (lat2 - lat1) * 3.14159 / 180;
    final dlon = (lon2 - lon1) * 3.14159 / 180;
    final a = dlat * dlat + dlon * dlon *
        _cos(lat1 * 3.14159 / 180) * _cos(lat2 * 3.14159 / 180);
    return R * _sqrt(a);
  }

  static double _cos(double x) {
    double r = 1, t = 1;
    for (int i = 1; i <= 8; i++) { t *= -x*x/(2*i*(2*i-1)); r += t; }
    return r;
  }

  static double _sqrt(double x) {
    if (x <= 0) return 0;
    double s = x / 2;
    for (int i = 0; i < 20; i++) s = (s + x/s) / 2;
    return s;
  }
}
