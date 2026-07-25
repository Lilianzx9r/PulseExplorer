import 'dart:async';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'poi_field_search.dart';

// ─────────────────────────────────────────────────────────────────────────────
// place_search_field.dart
//
// Champ de recherche de lieu par nom (géocodage Nominatim), réutilisable
// partout où l'utilisateur doit choisir une position : départ de navigation,
// étape d'itinéraire, position manuelle, etc.
// ─────────────────────────────────────────────────────────────────────────────

class PlaceSearchResult {
  final String name;
  final LatLng position;
  const PlaceSearchResult({required this.name, required this.position});
}

/// Dialog de recherche de lieu — retourne le résultat choisi ou null
class PlaceSearchDialog extends StatefulWidget {
  final String title;
  final String hint;

  const PlaceSearchDialog({
    super.key,
    this.title = 'Rechercher un lieu',
    this.hint = 'Nom de ville, adresse, lieu-dit…',
  });

  @override
  State<PlaceSearchDialog> createState() => _PlaceSearchDialogState();

  /// Raccourci statique pour ouvrir le dialog
  static Future<PlaceSearchResult?> show(BuildContext context, {
    String title = 'Rechercher un lieu',
    String hint = 'Nom de ville, adresse, lieu-dit…',
  }) {
    return showDialog<PlaceSearchResult>(
      context: context,
      builder: (_) => PlaceSearchDialog(title: title, hint: hint),
    );
  }
}

class _PlaceSearchDialogState extends State<PlaceSearchDialog> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<NominatimResult> _results = [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 3) {
      setState(() { _results = []; _error = null; });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await PoiFieldSearch.searchCoords(query);
      if (mounted) {
        setState(() {
          _results = results;
          if (results.isEmpty) _error = 'Aucun résultat pour "$query"';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Erreur de recherche : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF16213e),
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 520),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
            child: Row(children: [
              const Icon(Icons.search, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.title,
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 15))),
              IconButton(icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                  onPressed: () => Navigator.pop(context)),
            ])),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _ctrl, autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              onChanged: _onChanged,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
                prefixIcon: const Icon(Icons.location_on, size: 18, color: Colors.white38),
                suffixIcon: _loading
                    ? const Padding(padding: EdgeInsets.all(12),
                        child: SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber)))
                    : (_ctrl.text.isNotEmpty
                        ? IconButton(icon: const Icon(Icons.clear, size: 18, color: Colors.white38),
                            onPressed: () { _ctrl.clear(); setState(() => _results = []); })
                        : null),
                enabledBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF0f3460))),
                focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.amber)),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            )),
          const SizedBox(height: 8),
          Flexible(child: _results.isEmpty
              ? Padding(padding: const EdgeInsets.all(24),
                  child: Text(_error ?? 'Tapez au moins 3 caractères pour rechercher',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _error != null ? Colors.orange : Colors.white30,
                          fontSize: 12)))
              : ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF0f3460)),
                  itemBuilder: (ctx, i) {
                    final r = _results[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.place, size: 18, color: Colors.amber),
                      title: Text(r.display.split(',').take(2).join(', '),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(r.display.split(',').skip(2).take(2).join(', '),
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text(r.type, style: const TextStyle(
                          color: Colors.white24, fontSize: 9)),
                      onTap: () => Navigator.pop(context, PlaceSearchResult(
                          name: r.display.split(',').first,
                          position: LatLng(r.lat, r.lon))),
                    );
                  },
                )),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}

/// Champ de recherche compact intégrable directement dans un formulaire
/// (pas un dialog) — utile dans les écrans où le clavier doit rester ouvert
/// et le résultat affiché en ligne (ex: éditeur d'itinéraire).
class PlaceSearchField extends StatefulWidget {
  final String hint;
  final void Function(PlaceSearchResult) onSelected;

  const PlaceSearchField({
    super.key, this.hint = 'Rechercher un lieu…', required this.onSelected,
  });

  @override
  State<PlaceSearchField> createState() => _PlaceSearchFieldState();
}

class _PlaceSearchFieldState extends State<PlaceSearchField> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  List<NominatimResult> _results = [];
  bool _loading = false;

  @override
  void dispose() { _debounce?.cancel(); _ctrl.dispose(); super.dispose(); }

  void _onChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 3) { setState(() => _results = []); return; }
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    try {
      final results = await PoiFieldSearch.searchCoords(query);
      if (mounted) setState(() => _results = results);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        controller: _ctrl,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        onChanged: _onChanged,
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
          prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white38),
          suffixIcon: _loading ? const Padding(padding: EdgeInsets.all(12),
              child: SizedBox(width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amber))) : null,
          isDense: true,
          enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF0f3460))),
          focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Colors.amber)),
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
      ),
      if (_results.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 4),
          constraints: const BoxConstraints(maxHeight: 220),
          decoration: BoxDecoration(
            color: const Color(0xFF0a1628),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF0f3460))),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _results.length,
            itemBuilder: (ctx, i) {
              final r = _results[i];
              return ListTile(
                dense: true,
                leading: const Icon(Icons.place, size: 16, color: Colors.amber),
                title: Text(r.display.split(',').take(2).join(', '),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () {
                  widget.onSelected(PlaceSearchResult(
                      name: r.display.split(',').first,
                      position: LatLng(r.lat, r.lon)));
                  setState(() { _results = []; _ctrl.text = r.display.split(',').first; });
                },
              );
            },
          ),
        ),
    ]);
  }
}
