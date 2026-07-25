import 'package:flutter/material.dart';
import 'core/services/geocoding_service.dart';
import 'core/services/poi_enrichment_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// poi_field_search.dart
//
// Recherches réutilisables champ par champ pour l'édition d'un POI :
// - Coordonnées via Nominatim
// - Description via Wikipedia
// - Photos via DuckDuckGo + Wikimedia Commons
//
// Utilisé par poi_edit_dialog.dart (édition POI extraits par IA) ET
// poi_detail_screen.dart (édition POI depuis la carte/liste principale).
// ─────────────────────────────────────────────────────────────────────────────

class NominatimResult {
  final String display;
  final double lat, lon;
  final String type;
  const NominatimResult({required this.display, required this.lat,
      required this.lon, required this.type});
}

class PoiFieldSearch {
  PoiFieldSearch._();

  /// Recherche de coordonnées via Nominatim — jusqu'à 5 résultats.
  /// Délègue à GeocodingService (service unique, voir core/services/).
  static Future<List<NominatimResult>> searchCoords(String query) async {
    try {
      final results = await GeocodingService.search(query, limit: 5);
      return results
          .map((r) => NominatimResult(
                display: r.displayName,
                lat: r.lat,
                lon: r.lon,
                type: r.type,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Recherche de description via Wikipedia. Délègue à PoiEnrichmentService.
  static Future<String?> searchDescription(String query) =>
      PoiEnrichmentService.searchDescription(query);

  /// Recherche de photos via DuckDuckGo + Wikimedia Commons.
  /// Délègue à PoiEnrichmentService (service unique d'enrichissement POI).
  static Future<List<String>> searchPhotos(String query) =>
      PoiEnrichmentService.searchPhotos(query);

  // ── Dialogs réutilisables ───────────────────────────────────────────────────

  /// Affiche les résultats Nominatim dans un dialog, retourne le choix ou null
  static Future<NominatimResult?> pickCoordsDialog(
      BuildContext context, List<NominatimResult> results) {
    if (results.isEmpty) return Future.value(null);
    return showDialog<NominatimResult>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('Choisir les coordonnées',
            style: TextStyle(color: Colors.white, fontSize: 14)),
        content: SizedBox(width: 400,
          child: Column(mainAxisSize: MainAxisSize.min,
            children: results.map((r) => ListTile(
              dense: true,
              title: Text(r.display.split(',').take(3).join(', '),
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  '${r.lat.toStringAsFixed(4)}, ${r.lon.toStringAsFixed(4)} · ${r.type}',
                  style: const TextStyle(color: Colors.white38, fontSize: 10)),
              trailing: const Icon(Icons.check, color: Colors.amber, size: 18),
              onTap: () => Navigator.pop(context, r),
            )).toList()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler', style: TextStyle(color: Colors.white54))),
        ],
      ),
    );
  }

  /// Affiche le résumé Wikipedia trouvé, retourne 'replace'/'append'/null
  static Future<String?> confirmDescriptionDialog(
      BuildContext context, String extract) {
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('Description Wikipedia',
            style: TextStyle(color: Colors.white, fontSize: 14)),
        content: Text(extract,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler', style: TextStyle(color: Colors.white38))),
          TextButton(onPressed: () => Navigator.pop(context, 'append'),
              child: const Text('Ajouter', style: TextStyle(color: Colors.lightBlue))),
          FilledButton(onPressed: () => Navigator.pop(context, 'replace'),
              style: FilledButton.styleFrom(backgroundColor: Colors.amber,
                  foregroundColor: Colors.black),
              child: const Text('Remplacer')),
        ],
      ),
    );
  }

  /// Affiche une grille d'images à choisir, retourne les URLs sélectionnées
  static Future<List<String>> pickPhotosDialog(
      BuildContext context, List<String> urls, String query) async {
    if (urls.isEmpty) return [];
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _PhotoPickerDialog(urls: urls, query: query),
    );
    return result ?? [];
  }

  /// Bouton compact de recherche avec état de chargement — widget réutilisable
  static Widget searchButton({
    required IconData icon, required String tooltip,
    bool loading = false, required VoidCallback onTap,
  }) =>
    Tooltip(message: tooltip,
      child: GestureDetector(
        onTap: loading ? null : onTap,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(.15),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.blue.withOpacity(.3))),
          child: loading
              ? const SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.blue))
              : Icon(icon, size: 14, color: Colors.lightBlue),
        ),
      ));
}

class _PhotoPickerDialog extends StatefulWidget {
  final List<String> urls;
  final String query;
  const _PhotoPickerDialog({required this.urls, required this.query});

  @override
  State<_PhotoPickerDialog> createState() => _PhotoPickerDialogState();
}

class _PhotoPickerDialogState extends State<_PhotoPickerDialog> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF16213e),
      title: Text('Images pour "${widget.query}"',
          style: const TextStyle(color: Colors.white, fontSize: 13)),
      content: SizedBox(width: 400, height: 300,
        child: GridView.builder(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
          itemCount: widget.urls.length,
          itemBuilder: (ctx, i) => GestureDetector(
            onTap: () => setState(() {
              _selected.contains(i) ? _selected.remove(i) : _selected.add(i);
            }),
            child: Stack(fit: StackFit.expand, children: [
              ClipRRect(borderRadius: BorderRadius.circular(6),
                child: Image.network(widget.urls[i], fit: BoxFit.cover,
                    errorBuilder: (_,__,___) => Container(color: Colors.grey.shade800,
                        child: const Icon(Icons.broken_image, color: Colors.white30)))),
              if (_selected.contains(i))
                Container(decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(.3),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.amber, width: 2)),
                  child: const Center(child: Icon(Icons.check_circle,
                      color: Colors.amber, size: 28))),
            ]),
          ),
        )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Annuler', style: TextStyle(color: Colors.white54))),
        FilledButton(
          onPressed: _selected.isEmpty ? null : () =>
              Navigator.pop(context, _selected.map((i) => widget.urls[i]).toList()),
          style: FilledButton.styleFrom(backgroundColor: Colors.amber,
              foregroundColor: Colors.black),
          child: Text('Ajouter (${_selected.length})'),
        ),
      ],
    );
  }
}
