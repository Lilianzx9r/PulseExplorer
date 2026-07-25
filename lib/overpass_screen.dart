import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'core/services/vector_map_layer.dart';
import 'package:latlong2/latlong.dart';
import 'overpass_service.dart';
import 'poi_layer.dart';
import 'nominatim_helper.dart';
import 'core/services/poi_import_service.dart';

class OverpassScreen extends StatefulWidget {
  final BoundingBox? hintBbox; // bbox courante de l'app
  /// Si true, l'écran est affiché SANS son propre Scaffold/AppBar (utilisé
  /// comme onglet embarqué dans PoiSearchScreen) et retourne son résultat
  /// via [onResult] plutôt que par Navigator.pop.
  final bool embedded;
  final ValueChanged<PoiLayer>? onResult;

  const OverpassScreen({
    super.key, this.hintBbox, this.embedded = false, this.onResult,
  });

  @override
  State<OverpassScreen> createState() => _OverpassScreenState();
}

class _OverpassScreenState extends State<OverpassScreen> {

  // Zone de recherche
  late double _minLat, _maxLat, _minLon, _maxLon;
  final _cityCtrl = TextEditingController();

  // Catégories sélectionnées
  final Set<String> _selectedCats = {'viewpoint', 'peak', 'cliff', 'attraction', 'monument', 'village'};
  bool _categoriesCollapsed = false;

  // ── Dessin d'une zone précise sur la carte (bouton "Zone") ────────────────
  bool    _drawMode = false;
  LatLng? _drawCornerA;
  LatLng? _drawCornerB;
  // true une fois une zone dessinée à la main — désactive le suivi
  // automatique de la zone visible (onPositionChanged) tant qu'une
  // nouvelle zone n'est pas redessinée, pour ne pas écraser le choix
  // explicite de l'utilisateur au moindre geste sur la carte.
  bool _customZoneActive = false;

  // Résultats
  bool             _isLoading = false;
  String?          _error;
  List<PoiPoint>   _results   = [];
  final Set<int>   _checked   = {}; // indices sélectionnés pour ajout
  String           _layerName = 'POI touristiques';
  int              _maxResults = 100;

  // Carte
  final MapController _mapCtrl = MapController();
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    // Init bbox depuis l'app ou valeur par défaut
    final b = widget.hintBbox;
    if (b != null) {
      _minLat = b.minLat; _maxLat = b.maxLat;
      _minLon = b.minLon; _maxLon = b.maxLon;
    } else {
      _minLat = 42.0; _maxLat = 43.0;
      _minLon = 0.0;  _maxLon = 1.0;
    }
  }

  double get _centerLat => (_minLat + _maxLat) / 2;
  double get _centerLon => (_minLon + _maxLon) / 2;

  /// Aligne les bornes de recherche sur la zone actuellement visible à
  /// l'écran — appelé à chaque déplacement/zoom de la carte (voir
  /// onPositionChanged) pour que "Charger les POI OSM" cherche toujours
  /// dans ce que l'utilisateur voit, pas une zone figée à l'ouverture.
  void _syncBoundsToViewport() {
    if (!_mapReady || _customZoneActive) return;
    final b = _mapCtrl.camera.visibleBounds;
    setState(() {
      _minLat = b.south; _maxLat = b.north;
      _minLon = b.west;  _maxLon = b.east;
    });
  }

  Future<void> _searchCity() async {
    final q = _cityCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() { _isLoading = true; _error = null; });
    try {
      final results = await NominatimHelper.searchCity(q);
      if (results.isNotEmpty) {
        final b = results.first;
        setState(() {
          _minLat = b.minLat; _maxLat = b.maxLat;
          _minLon = b.minLon; _maxLon = b.maxLon;
          // Une recherche par nom remplace toute zone dessinée à la main —
          // le suivi de la zone visible reprend au prochain déplacement.
          _customZoneActive = false;
          _drawMode = false;
          _drawCornerA = null;
          _drawCornerB = null;
        });
        if (_mapReady) {
          _mapCtrl.move(LatLng(_centerLat, _centerLon), 11.0);
        }
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _fetch() async {
    if (_selectedCats.isEmpty) {
      setState(() => _error = 'Sélectionnez au moins une catégorie');
      return;
    }
    setState(() {
      _isLoading = true;
      _error     = null;
      _results   = [];
      _checked.clear();
    });
    try {
      final pts = await OverpassService.fetchPois(
        minLat:      _minLat, maxLat: _maxLat,
        minLon:      _minLon, maxLon: _maxLon,
        categoryIds: _selectedCats.toList(),
        maxResults:  _maxResults,
      );
      setState(() {
        _results = pts;
        // Tout sélectionner par défaut
        _checked.addAll(List.generate(pts.length, (i) => i));
      });
      if (_mapReady && pts.isNotEmpty) {
        _mapCtrl.move(LatLng(_centerLat, _centerLon), 11.0);
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _addSelected() {
    final pts = _checked.map((i) => _results[i]).toList();
    if (pts.isEmpty) return;
    final layer = PoiImportService.buildLayer(pts, label: _layerName);
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
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('POI Road Trip (OSM/Overpass)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          Text('${_results.length} résultats',
              style: const TextStyle(fontSize: 10, color: Colors.white70)),
        ]),
        actions: [
          if (_checked.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: _addSelected,
                icon: const Icon(Icons.add_location_alt, size: 16),
                label: Text('Ajouter (${_checked.length})'),
                style: FilledButton.styleFrom(backgroundColor: Colors.green),
              ),
            ),
        ],
      ),
      body: Column(children: [

        // ── Carte ─────────────────────────────────────────────────────────
        Expanded(
          child: FlutterMap(
            mapController: _mapCtrl,
            options: MapOptions(
              initialCenter: LatLng(_centerLat, _centerLon),
              initialZoom: 10,
              onMapReady: () {
                _mapReady = true;
                _mapCtrl.move(LatLng(_centerLat, _centerLon), 10.0);
                // Bornes = zone visible dès l'ouverture (pas seulement
                // après un pan/zoom) — corrige "la zone visible n'est
                // pas utilisée" : avant, elles restaient figées sur
                // hintBbox ou la dernière ville recherchée, sans jamais
                // suivre ce qui est réellement affiché.
                _syncBoundsToViewport();
              },
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture) _syncBoundsToViewport();
              },
              onTap: !_drawMode ? null : (tapPos, latlng) {
                setState(() {
                  // Premier tap = coin A (ou on recommence si une zone
                  // était déjà dessinée) ; second tap = coin B → zone prête.
                  if (_drawCornerA == null || _drawCornerB != null) {
                    _drawCornerA = latlng;
                    _drawCornerB = null;
                  } else {
                    _drawCornerB = latlng;
                    _minLat = math.min(_drawCornerA!.latitude, _drawCornerB!.latitude);
                    _maxLat = math.max(_drawCornerA!.latitude, _drawCornerB!.latitude);
                    _minLon = math.min(_drawCornerA!.longitude, _drawCornerB!.longitude);
                    _maxLon = math.max(_drawCornerA!.longitude, _drawCornerB!.longitude);
                    _customZoneActive = true;
                  }
                });
              },
            ),
            children: [
              const AppMapLayer(),
              // Zone de recherche — orange tant que le dessin est en cours
              // (2 coins pas encore posés), bleu une fois active.
              PolygonLayer(polygons: [
                Polygon(
                  points: [
                    LatLng(_minLat, _minLon), LatLng(_maxLat, _minLon),
                    LatLng(_maxLat, _maxLon), LatLng(_minLat, _maxLon),
                  ],
                  color: (_customZoneActive ? Colors.orange : Colors.blue).withOpacity(0.1),
                  borderColor: _customZoneActive ? Colors.orange : Colors.blue,
                  borderStrokeWidth: 2,
                ),
              ]),
              // Premier coin posé, en attente du second
              if (_drawMode && _drawCornerA != null && _drawCornerB == null)
                MarkerLayer(markers: [
                  Marker(point: _drawCornerA!, width: 20, height: 20,
                    child: const Icon(Icons.push_pin, color: Colors.orange, size: 20)),
                ]),
              // Résultats
              MarkerLayer(markers: [
                for (int i = 0; i < _results.length; i++)
                  Marker(
                    point: LatLng(_results[i].lat, _results[i].lon),
                    width: 20, height: 20,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _checked.contains(i)
                            ? Colors.deepOrange : Colors.grey,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: const Icon(Icons.place,
                          size: 12, color: Colors.white),
                    ),
                  ),
              ]),
            ],
          ),
        ),

        // ── Paramètres (hauteur adaptée au contenu — la carte, en Expanded
        // juste au-dessus, récupère l'espace libéré quand les catégories
        // sont repliées) ──────────────────────────────────────────────────
        SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // Ville / zone
              Row(children: [
                Expanded(child: TextField(
                  controller: _cityCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Ville ou région',
                    hintText: 'Ex: Huesca, Pyrénées...',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _searchCity(),
                )),
                const SizedBox(width: 8),
                // "Zone" bascule le mode dessin sur la carte (2 touchers
                // pour définir un rectangle précis) — auparavant, ce
                // bouton relançait juste la même recherche par nom de
                // ville que la validation du champ texte, sans jamais
                // permettre de dessiner quoi que ce soit.
                OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _drawMode = !_drawMode;
                    if (!_drawMode) { _drawCornerA = null; _drawCornerB = null; }
                  }),
                  icon: Icon(_drawMode ? Icons.close : Icons.crop_square,
                      size: 16, color: _drawMode ? Colors.orange : null),
                  label: Text(_drawMode ? 'Annuler' : 'Zone'),
                  style: OutlinedButton.styleFrom(
                      side: _drawMode ? const BorderSide(color: Colors.orange) : null),
                ),
              ]),
              if (_drawMode)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _drawCornerA == null
                        ? '✏️ Touchez un premier coin de la zone sur la carte.'
                        : _drawCornerB == null
                            ? '✏️ Touchez le coin opposé pour terminer.'
                            : '✏️ Zone dessinée — touchez à nouveau pour la refaire.',
                    style: const TextStyle(fontSize: 11, color: Colors.orange)),
                ),

              const SizedBox(height: 10),

              // Catégories — pliable pour agrandir la vue de la carte
              InkWell(
                onTap: () => setState(() => _categoriesCollapsed = !_categoriesCollapsed),
                child: Row(children: [
                  Icon(_categoriesCollapsed ? Icons.expand_more : Icons.expand_less,
                      size: 18, color: Colors.black54),
                  const SizedBox(width: 2),
                  Text(
                    _categoriesCollapsed
                        ? 'Catégories : ${_selectedCats.length} sélectionnée(s)'
                        : 'Catégories :',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                ]),
              ),
              if (!_categoriesCollapsed) ...[
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4,
                  children: kPoiCategories.map((cat) {
                    final sel = _selectedCats.contains(cat.id);
                    return FilterChip(
                      label: Text('${cat.emoji} ${cat.label}',
                          style: TextStyle(
                              fontSize: 11,
                              color: sel ? Colors.white : Colors.black87)),
                      selected: sel,
                      onSelected: (v) => setState(() {
                        if (v) _selectedCats.add(cat.id);
                        else   _selectedCats.remove(cat.id);
                      }),
                      backgroundColor: Colors.grey.shade100,
                      selectedColor: const Color(0xFF003580),
                      checkmarkColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 0),
                    );
                  }).toList(),
                ),
              ],

              const SizedBox(height: 10),

              // Limite
              Row(children: [
                const Text('Max résultats :',
                    style: TextStyle(fontSize: 12)),
                Expanded(child: Slider(
                  value: _maxResults.toDouble(),
                  min: 20, max: 500, divisions: 24,
                  label: '$_maxResults',
                  onChanged: (v) =>
                      setState(() => _maxResults = v.round()),
                )),
                Text('$_maxResults',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w500)),
              ]),

              // Nom couche
              TextField(
                onChanged: (v) => _layerName = v,
                controller: TextEditingController(text: _layerName),
                decoration: const InputDecoration(
                  labelText: 'Nom de la couche',
                  prefixIcon: Icon(Icons.label),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),

              const SizedBox(height: 10),

              // Bouton fetch
              FilledButton.icon(
                onPressed: _isLoading ? null : _fetch,
                icon: _isLoading
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.download_for_offline, size: 18),
                label: Text(_isLoading
                    ? 'Chargement...'
                    : 'Charger les POI OSM'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 46),
                  backgroundColor: const Color(0xFF003580),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.red.shade200)),
                  child: Row(children: [
                    const Icon(Icons.error_outline,
                        color: Colors.red, size: 14),
                    const SizedBox(width: 6),
                    Expanded(child: Text(_error!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 11))),
                  ]),
                ),
              ],

              // Résultats
              if (_results.isNotEmpty) ...[
                const SizedBox(height: 10),
                Row(children: [
                  Text('${_results.length} POI trouvés',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 12)),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() {
                      if (_checked.length == _results.length) {
                        _checked.clear();
                      } else {
                        _checked.addAll(
                            List.generate(_results.length, (i) => i));
                      }
                    }),
                    child: Text(
                      _checked.length == _results.length
                          ? 'Tout désélect.' : 'Tout sélect.',
                      style: const TextStyle(fontSize: 11)),
                  ),
                ]),
                // Résumé par type
                _buildTypeSummary(),
                const SizedBox(height: 6),
                // Liste
                ...List.generate(_results.length, (i) {
                  final p   = _results[i];
                  final sel = _checked.contains(i);
                  return CheckboxListTile(
                    dense: true,
                    value: sel,
                    onChanged: (v) => setState(() {
                      if (v == true) _checked.add(i);
                      else           _checked.remove(i);
                    }),
                    title: Text(p.name,
                        style: const TextStyle(fontSize: 12,
                            fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      if (p.description != null && p.description!.isNotEmpty)
                        Text(p.description!,
                            style: const TextStyle(fontSize: 10),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      Text(
                        '${p.lat.toStringAsFixed(4)}, '
                        '${p.lon.toStringAsFixed(4)}  •  ${p.type ?? ""}',
                        style: const TextStyle(
                            fontSize: 9, color: Colors.blueGrey)),
                    ]),
                    secondary: Text(
                        _typeEmoji(p.type),
                        style: const TextStyle(fontSize: 18)),
                    isThreeLine: p.description != null &&
                        p.description!.isNotEmpty,
                  );
                }),
              ],
            ]),
          ),
      ]),
    );
  }

  Widget _buildTypeSummary() {
    final counts = <String, int>{};
    for (final p in _results) {
      final t = p.type ?? 'poi';
      counts[t] = (counts[t] ?? 0) + 1;
    }
    return Wrap(
      spacing: 6, runSpacing: 4,
      children: counts.entries.map((e) => Chip(
        label: Text('${_typeEmoji(e.key)} ${e.key}: ${e.value}',
            style: const TextStyle(fontSize: 10)),
        backgroundColor: Colors.grey.shade100,
        padding: EdgeInsets.zero,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      )).toList(),
    );
  }

  String _typeEmoji(String? t) {
    switch (t) {
      case 'viewpoint':   return '🔭';
      case 'peak':        return '⛰️';
      case 'cliff':       return '🏔️';
      case 'gorge':       return '🏔️';
      case 'waterfall':   return '💧';
      case 'museum':      return '🖼️';
      case 'attraction':  return '🎠';
      case 'hotel':       return '🏨';
      case 'restaurant':  return '🍽️';
      case 'monument':    return '🏛️';
      case 'village':     return '🏘️';
      case 'fuel':        return '⛽';
      case 'parking':     return '🅿️';
      case 'chapel':      return '⛪';
      case 'scenic':      return '🛣️';
      default:            return '📍';
    }
  }
}
