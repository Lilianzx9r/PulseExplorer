import 'dart:convert';
import 'package:http/http.dart' as http;

// ─────────────────────────────────────────────────────────────────────────────
// poi_enrichment_service.dart
//
// Service UNIQUE d'enrichissement d'un POI depuis le web : description et
// photos. Réunit ce qui était avant dispersé et incomplet :
//   - poi_field_search.dart : description via Wikipedia + photos via
//     DuckDuckGo ET Wikimedia Commons (le plus complet des deux)
//   - blog_poi_service.dart : photos via DuckDuckGo seulement
//   - html_poi_extractor.dart : ne recherchait aucune photo (photoUrls
//     toujours vide) alors que la description enrichie par IA prévoyait un
//     champ image_query pour cet usage — c'est corrigé ici.
//
// Ce service est utilisé partout où un POI est créé ou édité, quel que soit
// son point d'entrée (recherche manuelle, extraction IA depuis un blog,
// import Overpass), pour que "chercher description + photos" soit une
// action disponible de façon cohérente et non dépendante du chemin
// d'origine du POI.
// ─────────────────────────────────────────────────────────────────────────────

class PoiEnrichmentService {
  PoiEnrichmentService._();

  static const String _userAgent = 'PulseExplorer/1.0 (contact: app@pulsegps.local)';

  // ── Description ─────────────────────────────────────────────────────────

  /// Description courte via le résumé Wikipedia (fr). Retourne null si
  /// introuvable. Sert de solution de repli quand le POI n'a pas été
  /// enrichi par l'IA (ou en l'absence de clé API OpenRouter).
  static Future<String?> searchDescription(
    String query, {
    int maxChars = 300,
  }) async {
    try {
      final r = await http.get(
        Uri.parse(
            'https://fr.wikipedia.org/api/rest_v1/page/summary/${Uri.encodeComponent(query)}'),
        headers: {'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final data = json.decode(r.body) as Map;
      final extract = data['extract']?.toString() ?? '';
      if (extract.isEmpty) return null;
      return extract.length > maxChars
          ? '${extract.substring(0, maxChars)}…'
          : extract;
    } catch (_) {
      return null;
    }
  }

  // ── Photos ───────────────────────────────────────────────────────────────

  /// Recherche d'image DuckDuckGo — retourne la première URL d'image de
  /// taille raisonnable pour la requête, ou null.
  static Future<String?> searchImageDuckDuckGo(String query) async {
    try {
      const imagesBase = 'https://duckduckgo.com/';
      final initResp = await http.get(
        Uri.parse('${imagesBase}?q=${Uri.encodeComponent(query)}&iax=images&ia=images'),
        headers: {'User-Agent': 'Mozilla/5.0 (compatible)'},
      ).timeout(const Duration(seconds: 8));

      final vqdMatch = RegExp(r'vqd=([\d-]+)').firstMatch(initResp.body);
      if (vqdMatch == null) return null;
      final vqd = vqdMatch.group(1)!;

      final imgResp = await http.get(
        Uri.parse('${imagesBase}i.js?q=${Uri.encodeComponent(query)}&vqd=$vqd&f=,,,,,'),
        headers: {
          'User-Agent': 'Mozilla/5.0 (compatible)',
          'Referer': 'https://duckduckgo.com/',
        },
      ).timeout(const Duration(seconds: 8));

      if (imgResp.statusCode != 200) return null;
      final data = json.decode(imgResp.body) as Map;
      final results = data['results'] as List?;
      if (results == null || results.isEmpty) return null;

      for (final r in results.take(5)) {
        final url = r['image']?.toString() ?? '';
        final width = r['width'] as int? ?? 0;
        final height = r['height'] as int? ?? 0;
        if (url.isNotEmpty && width >= 200 && height >= 150) return url;
      }
      return results.first['image']?.toString();
    } catch (_) {
      return null;
    }
  }

  /// Recherche d'images sur Wikimedia Commons — jusqu'à [limit] URLs.
  static Future<List<String>> searchImagesWikimediaCommons(
    String query, {
    int limit = 6,
    int thumbWidth = 400,
  }) async {
    final urls = <String>[];
    try {
      final wr = await http.get(
        Uri.parse('https://commons.wikimedia.org/w/api.php?action=query&format=json'
            '&generator=search&gsrsearch=${Uri.encodeComponent(query)}'
            '&gsrnamespace=6&gsrlimit=$limit&prop=imageinfo&iiprop=url&iiurlwidth=$thumbWidth'),
        headers: {'User-Agent': _userAgent},
      ).timeout(const Duration(seconds: 10));
      if (wr.statusCode == 200) {
        final data = json.decode(wr.body) as Map;
        final pages = (data['query']?['pages'] as Map?)?.values ?? [];
        for (final p in pages) {
          final infos = p['imageinfo'] as List?;
          final ii = (infos != null && infos.isNotEmpty) ? infos.first : null;
          final url = ii?['thumburl'] ?? ii?['url'];
          if (url != null) urls.add(url.toString());
        }
      }
    } catch (_) {}
    return urls;
  }

  /// Recherche combinée : DuckDuckGo (1 résultat) + Wikimedia Commons
  /// (plusieurs résultats), pour proposer un choix de photos à l'utilisateur.
  static Future<List<String>> searchPhotos(String query) async {
    final urls = <String>[];
    final ddg = await searchImageDuckDuckGo(query);
    if (ddg != null) urls.add(ddg);
    urls.addAll(await searchImagesWikimediaCommons(query));
    return urls;
  }

  /// Enrichissement complet d'un POI : description + première photo trouvée.
  /// Pratique pour les pipelines automatiques (extraction blog/HTML) qui
  /// veulent une seule photo par POI plutôt qu'une liste de choix.
  static Future<({String? description, String? photoUrl})> enrich(
    String query, {
    bool useAiDescriptionFallback = true,
  }) async {
    final description =
        useAiDescriptionFallback ? await searchDescription(query) : null;
    final photoUrl = await searchImageDuckDuckGo(query);
    return (description: description, photoUrl: photoUrl);
  }
}
