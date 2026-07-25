import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'core/services/vector_map_layer.dart';
import 'package:latlong2/latlong.dart';
import 'poi_layer.dart';
import 'core/services/geocoding_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Modèle résultat Nominatim
// ─────────────────────────────────────────────────────────────────────────────
class PlaceResult {
  final String  displayName;
  final String  shortName;
  final double  lat;
  final double  lon;
  final String  type;
  final String  category;
  final double? importance;

  PlaceResult({
    required this.displayName,
    required this.shortName,
    required this.lat,
    required this.lon,
    required this.type,
    required this.category,
    this.importance,
  });

  factory PlaceResult.fromJson(Map<String, dynamic> j) {
    final parts = (j['display_name'] as String).split(', ');
    return PlaceResult(
      displayName: j['display_name'] as String,
      shortName:   parts.take(2).join(', '),
      lat:         double.parse(j['lat'].toString()),
      lon:         double.parse(j['lon'].toString()),
      type:        j['type']?.toString()     ?? 'place',
      category:    j['class']?.toString()    ?? 'place',
      importance:  double.tryParse(j['importance']?.toString() ?? ''),
    );
  }

  PoiPoint toPoiPoint() => PoiPoint(
    name:        shortName,
    lat:         lat,
    lon:         lon,
    description: displayName,
    type:        _mapType(type),
  );

  static String _mapType(String t) {
    if (['city','town','village','hamlet'].contains(t)) return 'city';
    if (['hotel','hostel','guest_house','motel'].contains(t)) return 'hotel';
    if (['restaurant','cafe','bar','fast_food'].contains(t)) return 'restaurant';
    if (['peak','viewpoint','waterfall','lake','forest'].contains(t)) return 'nature';
    return 'poi';
  }

  String get typeIcon {
    switch (_mapType(type)) {
      case 'city':       return '🏙️';
      case 'hotel':      return '🏨';
      case 'restaurant': return '🍽️';
      case 'nature':     return '🌿';
      default:           return '📍';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service de recherche Nominatim
// ─────────────────────────────────────────────────────────────────────────────
class NominatimSearch {
  /// Délègue au service de géocodage unique (GeocodingService).
  static Future<List<PlaceResult>> search(String query, {int limit = 10}) async {
    if (query.trim().isEmpty) return [];
    final results = await GeocodingService.search(query.trim(), limit: limit);
    return results.map((r) => PlaceResult.fromJson({
      'display_name': r.displayName,
      'lat': r.lat, 'lon': r.lon,
      'type': r.type, 'class': r.type,
    })).toList();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Écran de recherche de lieux
// ─────────────────────────────────────────────────────────────────────────────
class PlaceSearchScreen extends StatefulWidget {
  /// Si true, retourne son résultat via [onResult] plutôt que par
  /// Navigator.pop (utilisé comme onglet embarqué dans PoiSearchScreen).
  final bool embedded;
  final ValueChanged<PoiLayer>? onResult;
  const PlaceSearchScreen({super.key, this.embedded = false, this.onResult});

  @override
  State<PlaceSearchScreen> createState() => _PlaceSearchScreenState();
}

class _PlaceSearchScreenState extends State<PlaceSearchScreen> {
  final _searchCtrl  = TextEditingController();
  final _mapCtrl     = MapController();

  List<PlaceResult>   _results       = [];
  final Set<int>      _selected      = {};   // indices sélectionnés
  bool                _isSearching   = false;
  String?             _error;
  PlaceResult?        _focusedResult; // résultat affiché sur la carte

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _isSearching = true;
      _error       = null;
      _results     = [];
      _selected.clear();
      _focusedResult = null;
    });
    try {
      final results = await NominatimSearch.search(q);
      setState(() => _results = results);
      if (results.isNotEmpty) _focusOn(results.first);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _isSearching = false);
    }
  }

  bool _mapReady = false;

  void _focusOn(PlaceResult r) {
    setState(() => _focusedResult = r);
    if (_mapReady) {
      _mapCtrl.move(LatLng(r.lat, r.lon), 13.0);
    }
  }

  void _toggleSelect(int i) {
    setState(() {
      if (_selected.contains(i)) _selected.remove(i);
      else _selected.add(i);
    });
  }

  void _addSelected() {
    if (_selected.isEmpty) return;
    final pts = _selected.map((i) => _results[i].toPoiPoint()).toList();
    final layer = PoiLayer(
      label:  pts.length == 1 ? pts.first.name : '${pts.length} lieux',
      points: pts,
      color:  Colors.deepOrange,
    );
    if (widget.embedded) {
      widget.onResult?.call(layer);
    } else {
      Navigator.pop(context, layer);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: const Text('Recherche de lieu',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        actions: [
          if (_selected.isNotEmpty)
            FilledButton.icon(
              onPressed: _addSelected,
              icon: const Icon(Icons.add_location_alt, size: 16),
              label: Text('Ajouter (${_selected.length})'),
              style: FilledButton.styleFrom(backgroundColor: Colors.green),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(children: [

        // ── Barre de recherche ──────────────────────────────────────────────
        Container(
          color: const Color(0xFF003580).withOpacity(0.05),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Ex: Mirador de Mallos de Riglos, Col du Galibier...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() { _results = []; _selected.clear(); });
                          })
                      : null,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                ),
                onSubmitted: (_) => _search(),
                onChanged:   (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _isSearching ? null : _search,
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF003580),
                  minimumSize: const Size(52, 50)),
              child: _isSearching
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.search),
            ),
          ]),
        ),

        // ── Erreur ─────────────────────────────────────────────────────────
        if (_error != null)
          Container(
            color: Colors.red.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12))),
            ]),
          ),

        // ── Carte + résultats ───────────────────────────────────────────────
        Expanded(child: _results.isEmpty && _focusedResult == null
            ? _buildEmpty()
            : _buildMapAndResults()),
      ]),
    );
  }

  Widget _buildEmpty() {
    return Center(child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.travel_explore,
            size: 64, color: Colors.grey.shade300),
        const SizedBox(height: 12),
        Text('Recherchez un lieu par son nom',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
        const SizedBox(height: 6),
        Text('Mirador, col, village, hôtel, restaurant...',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
      ],
    ));
  }

  Widget _buildMapAndResults() {
    return Column(children: [
      // Carte
      SizedBox(
        height: 260,
        child: FlutterMap(
          mapController: _mapCtrl,
          options: MapOptions(
            initialCenter: _focusedResult != null
                ? LatLng(_focusedResult!.lat, _focusedResult!.lon)
                : const LatLng(46.0, 2.0),
            initialZoom: _focusedResult != null ? 13.0 : 5.0,
            minZoom: 2, maxZoom: 18,
            onMapReady: () {
              _mapReady = true;
              if (_focusedResult != null) {
                _mapCtrl.move(
                  LatLng(_focusedResult!.lat, _focusedResult!.lon), 13.0);
              }
            },
          ),
          children: [
            const AppMapLayer(),
            MarkerLayer(markers: [
              for (int i = 0; i < _results.length; i++)
                Marker(
                  point: LatLng(_results[i].lat, _results[i].lon),
                  width: 36, height: 36,
                  child: GestureDetector(
                    onTap: () {
                      _focusOn(_results[i]);
                      _toggleSelect(i);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: _selected.contains(i)
                            ? Colors.green : const Color(0xFF003580),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black26, blurRadius: 4)],
                      ),
                      child: Center(child: Text(
                        '${i + 1}',
                        style: const TextStyle(color: Colors.white,
                            fontSize: 12, fontWeight: FontWeight.bold),
                      )),
                    ),
                  ),
                ),
            ]),
          ],
        ),
      ),

      // Résultats
      if (_results.isEmpty)
        Expanded(child: Center(
          child: Text('Aucun résultat',
              style: TextStyle(color: Colors.grey.shade500)),
        ))
      else
        Expanded(child: Column(children: [
          // En-tête
          Container(
            color: Colors.grey.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [
              Text('${_results.length} résultat${_results.length > 1 ? "s" : ""}',
                  style: const TextStyle(fontWeight: FontWeight.bold,
                      fontSize: 12)),
              const Spacer(),
              if (_results.isNotEmpty)
                TextButton.icon(
                  icon: const Icon(Icons.select_all, size: 14),
                  label: Text(
                    _selected.length == _results.length
                        ? 'Désélect.' : 'Tout sélect.',
                    style: const TextStyle(fontSize: 11)),
                  onPressed: () => setState(() {
                    if (_selected.length == _results.length) {
                      _selected.clear();
                    } else {
                      _selected.addAll(
                          List.generate(_results.length, (i) => i));
                    }
                  }),
                ),
            ]),
          ),
          // Liste
          Expanded(child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (ctx, i) {
              final r = _results[i];
              final isSel = _selected.contains(i);
              final isFocus = _focusedResult == r;
              return InkWell(
                onTap: () {
                  _focusOn(r);
                  _toggleSelect(i);
                },
                child: Container(
                  color: isSel
                      ? Colors.green.shade50
                      : isFocus
                          ? Colors.blue.shade50
                          : null,
                  child: ListTile(
                    dense: true,
                    leading: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: isSel
                              ? Colors.green : const Color(0xFF003580),
                          child: Text('${i + 1}',
                              style: const TextStyle(color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold)),
                        ),
                        if (isSel)
                          Container(
                            width: 14, height: 14,
                            decoration: BoxDecoration(
                              color: Colors.green.shade700,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white,
                                  width: 1.5)),
                            child: const Icon(Icons.check,
                                size: 8, color: Colors.white),
                          ),
                      ],
                    ),
                    title: Row(children: [
                      Text(r.typeIcon,
                          style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      Expanded(child: Text(r.shortName,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis)),
                    ]),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(r.displayName,
                            style: TextStyle(fontSize: 10,
                                color: Colors.grey.shade600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        Text(
                          '${r.lat.toStringAsFixed(5)}, '
                          '${r.lon.toStringAsFixed(5)}  •  '
                          '${r.category}/${r.type}',
                          style: const TextStyle(
                              fontSize: 9,
                              fontFamily: 'monospace',
                              color: Colors.blueGrey),
                        ),
                      ],
                    ),
                    isThreeLine: true,
                    trailing: Icon(
                      isSel ? Icons.check_circle : Icons.add_circle_outline,
                      color: isSel ? Colors.green : Colors.grey.shade400,
                      size: 22,
                    ),
                  ),
                ),
              );
            },
          )),
        ])),
    ]);
  }
}
