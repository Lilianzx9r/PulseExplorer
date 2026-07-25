import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'offline_graph.dart';
import 'navigation_service.dart';
import 'app_dirs.dart';
import 'core/services/vector_map_layer.dart';
import 'package:file_picker/file_picker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Pré-chargement de tuiles de carte pour utilisation hors-ligne
// ─────────────────────────────────────────────────────────────────────────────

/// Calcule les coordonnées de tuile (z,x,y) pour une position
int _lon2x(double lon, int z) => ((lon + 180) / 360 * (1 << z)).floor();
int _lat2y(double lat, int z) {
  final r = lat * math.pi / 180;
  return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * (1 << z)).floor();
}

/// Retourne toutes les tuiles (z,x,y) couvrant une bbox pour un zoom donné
List<(int z, int x, int y)> _tilesForBbox(
    double minLat, double maxLat, double minLon, double maxLon, int z) {
  final x0 = _lon2x(minLon, z), x1 = _lon2x(maxLon, z);
  final y0 = _lat2y(maxLat, z), y1 = _lat2y(minLat, z);
  final tiles = <(int, int, int)>[];
  for (int x = x0; x <= x1; x++) {
    for (int y = y0; y <= y1; y++) {
      tiles.add((z, x, y));
    }
  }
  return tiles;
}

/// Répertoire de cache des tuiles
Future<Directory> _tilesCacheDir() async {
  final base = await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}/PulseGpx/tiles_cache');
  await dir.create(recursive: true);
  return dir;
}

/// Chemin local d'une tuile
Future<String> _tilePath(int z, int x, int y) async {
  final dir = await _tilesCacheDir();
  return '${dir.path}/$z/$x/$y.png';
}

/// Vérifie si une tuile est en cache
Future<bool> _isCached(int z, int x, int y) async {
  return File(await _tilePath(z, x, y)).exists();
}

/// Télécharge et met en cache une tuile OSM
Future<bool> _downloadTile(int z, int x, int y) async {
  final path = await _tilePath(z, x, y);
  final file = File(path);
  await file.parent.create(recursive: true);
  if (await file.exists()) return true;
  try {
    // Alterner entre a/b/c pour respecter les serveurs OSM
    final sub = ['a', 'b', 'c'][x % 3];
    final url = 'https://$sub.tile.openstreetmap.org/$z/$x/$y.png';
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': 'PulseGpx/1.0 (offline tiles preload)',
    }).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 200) {
      await file.writeAsBytes(resp.bodyBytes);
      return true;
    }
  } catch (_) {}
  return false;
}

/// Taille totale du cache en Mo
Future<double> _cacheSizeMb() async {
  final dir = await _tilesCacheDir();
  if (!dir.existsSync()) return 0;
  double total = 0;
  await for (final f in dir.list(recursive: true)) {
    if (f is File) total += await f.length();
  }
  return total / 1024 / 1024;
}

/// Supprime tout le cache
Future<void> _clearCache() async {
  final dir = await _tilesCacheDir();
  if (dir.existsSync()) await dir.delete(recursive: true);
  await dir.create();
}

// ─────────────────────────────────────────────────────────────────────────────
// TileProvider utilisant le cache local avant le réseau
// ─────────────────────────────────────────────────────────────────────────────
class CachedOsmTileProvider extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coords, TileLayer options) {
    return _CachedTileImage(coords.x, coords.y, coords.z.toInt());
  }
}

class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  final int x, y, z;
  const _CachedTileImage(this.x, this.y, this.z);

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration config) async => this;

  @override
  ImageStreamCompleter loadImage(_CachedTileImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_load(key, decode));
  }

  Future<ImageInfo> _load(_CachedTileImage key, ImageDecoderCallback decode) async {
    final path = await _tilePath(key.z, key.x, key.y);
    final file = File(path);
    if (file.existsSync()) {
      final bytes = await file.readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await decode(buffer);
      final frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image);
    }
    // Pas en cache → télécharger et mettre en cache
    final sub = ['a', 'b', 'c'][key.x % 3];
    final url = 'https://$sub.tile.openstreetmap.org/${key.z}/${key.x}/${key.y}.png';
    final resp = await http.get(Uri.parse(url), headers: {
      'User-Agent': 'PulseGpx/1.0',
    }).timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(resp.bodyBytes);
      final buffer = await ui.ImmutableBuffer.fromUint8List(resp.bodyBytes);
      final codec = await decode(buffer);
      final frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image);
    }
    throw Exception('Tile not available: \$url');
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImage && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);
}

// ─────────────────────────────────────────────────────────────────────────────
// Écran de gestion du cache de tuiles
// ─────────────────────────────────────────────────────────────────────────────
class TileCacheScreen extends StatefulWidget {
  /// Centre initial de la zone à sélectionner (position GPS ou centre GPX)
  final LatLng? initialCenter;

  const TileCacheScreen({super.key, this.initialCenter});

  @override
  State<TileCacheScreen> createState() => _TileCacheScreenState();
}

class _TileCacheScreenState extends State<TileCacheScreen> {
  late final MapController _mc;

  // Paramètres de téléchargement
  int  _zoomMin = 10;
  int  _zoomMax = 14;
  bool _downloading = false;
  bool _cancelled   = false;

  // ── Téléchargement du graphe routier hors-ligne ───────────────────────────
  bool    _downloadingGraph = false;
  String  _graphStatus      = '';
  Map<String, double> _graphSizes = {};
  String  _graphProfile     = 'walking';

  int    _total = 0;
  int    _done  = 0;
  int    _failed = 0;
  double _cacheSize = 0;
  String _status = '';

  // Bbox de la zone visible sur la carte
  LatLngBounds? _visibleBounds;

  // ── Dessin d'une zone précise (indépendante du panoramique/zoom) ─────────
  bool    _drawMode = false;
  LatLng? _drawCornerA;
  LatLng? _drawCornerB;

  // ── Zones déjà téléchargées (visualisation) ───────────────────────────────
  List<Map<String, dynamic>> _cachedZones = [];

  // ── Carte vectorielle (.pmtiles) importée localement ──────────────────────
  String? _pmtilesPath;
  bool _pmtilesImporting = false;

  /// Zone active pour le téléchargement : le rectangle dessiné s'il est
  /// complet, sinon la zone visible (comportement précédent, conservé en
  /// repli pour ne rien casser).
  LatLngBounds? get _selectedBounds {
    if (_drawCornerA != null && _drawCornerB != null) {
      return LatLngBounds(_drawCornerA!, _drawCornerB!);
    }
    return _visibleBounds;
  }

  @override
  void initState() {
    super.initState();
    _mc = MapController();
    _loadCacheInfo();
    AppDirs.loadCachedZones().then((z) { if (mounted) setState(() => _cachedZones = z); });
    AppDirs.loadPmtilesPath().then((p) {
      if (mounted) setState(() => _pmtilesPath = p);
    });
  }

  @override
  void dispose() { _mc.dispose(); super.dispose(); }

  Future<void> _loadCacheInfo() async {
    final size   = await _cacheSizeMb();
    final graphs = await OfflineGraph.graphSizesMb();
    if (mounted) setState(() { _cacheSize = size; _graphSizes = graphs; });
  }

  Future<void> _downloadGraph() async {
    final bounds = _selectedBounds;
    if (bounds == null) return;
    setState(() { _downloadingGraph = true; _graphStatus = 'Téléchargement du graphe…'; });
    try {
      final graph = await OfflineGraph.download(
        bounds.south, bounds.north,
        bounds.west,  bounds.east,
        profile: _graphProfile,
        onStatus: (s) { if (mounted) setState(() => _graphStatus = s); },
      );
      if (graph != null) {
        await graph.save(_graphProfile);
        NavigationService.invalidateGraphCache();
        await _loadCacheInfo();
        if (mounted) setState(() =>
            _graphStatus = '✅ Graphe ${ _graphProfile} téléchargé (${_graphSizes[_graphProfile]?.toStringAsFixed(1) ?? "?"}  Mo)');
      } else {
        if (mounted) setState(() => _graphStatus = '❌ Échec du téléchargement');
      }
    } finally {
      if (mounted) setState(() => _downloadingGraph = false);
    }
  }

  int get _estimatedTiles {
    final bounds = _selectedBounds;
    if (bounds == null) return 0;
    int n = 0;
    for (int z = _zoomMin; z <= _zoomMax; z++) {
      n += _tilesForBbox(
        bounds.south, bounds.north,
        bounds.west, bounds.east, z,
      ).length;
    }
    return n;
  }

  Future<void> _startDownload() async {
    final bounds = _selectedBounds;
    if (bounds == null) return;
    setState(() {
      _downloading = true; _cancelled = false;
      _done = 0; _failed = 0; _status = 'Préparation…';
    });

    final allTiles = <(int, int, int)>[];
    for (int z = _zoomMin; z <= _zoomMax; z++) {
      allTiles.addAll(_tilesForBbox(
        bounds.south, bounds.north,
        bounds.west, bounds.east, z,
      ));
    }
    setState(() { _total = allTiles.length; _status = 'Téléchargement…'; });

    for (final (z, x, y) in allTiles) {
      if (_cancelled || !mounted) break;
      final ok = await _downloadTile(z, x, y);
      if (mounted) setState(() {
        if (ok) _done++; else _failed++;
        _status = 'Z$z — tuile $_done/$_total';
      });
      // Pause légère pour respecter Nominatim OSM usage policy
      await Future.delayed(const Duration(milliseconds: 30));
    }

    await _loadCacheInfo();

    // Mémorise la zone téléchargée pour pouvoir la visualiser plus tard —
    // seulement si au moins une tuile a été récupérée avec succès (pas pour
    // une tentative annulée immédiatement ou totalement en échec).
    if (!_cancelled && _done > 0) {
      _cachedZones = [..._cachedZones, {
        'south': bounds.south, 'north': bounds.north,
        'west': bounds.west, 'east': bounds.east,
        'zoomMin': _zoomMin, 'zoomMax': _zoomMax,
        'tiles': _done,
        'savedAt': DateTime.now().toIso8601String(),
      }];
      unawaited(AppDirs.saveCachedZones(_cachedZones));
    }

    if (mounted) setState(() {
      _downloading = false;
      _status = _cancelled
          ? 'Annulé — $_done tuiles téléchargées'
          : '✅ $_done téléchargées · $_failed échec(s)';
    });
  }

  String _profileLabel(String p) => switch(p) {
    'cycling' => '🚲 Vélo', 'driving' => '🚗 Voiture', _ => '🚶 Marche',
  };

  @override
  Widget build(BuildContext context) {
    final est = _estimatedTiles;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pré-chargement de cartes'),
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        actions: [
          Padding(padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              onPressed: () async {
                final ok = await showDialog<bool>(context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Vider le cache ?'),
                    content: Text('${_cacheSize.toStringAsFixed(1)} Mo seront supprimés.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false),
                          child: const Text('Annuler')),
                      FilledButton(onPressed: () => Navigator.pop(context, true),
                          style: FilledButton.styleFrom(backgroundColor: Colors.red),
                          child: const Text('Vider')),
                    ],
                  ));
                if (ok == true) {
                  await _clearCache();
                  await _loadCacheInfo();
                  if (mounted) setState(() {});
                }
              },
              icon: const Icon(Icons.delete_outline, color: Colors.white70, size: 16),
              label: Text('Cache : ${_cacheSize.toStringAsFixed(1)} Mo',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            )),
        ],
      ),
      body: Column(children: [
        // Carte de sélection de zone
        Expanded(flex: 3, child: FlutterMap(
          mapController: _mc,
          options: MapOptions(
            initialCenter: widget.initialCenter ?? const LatLng(46.0, 2.0),
            initialZoom: 10,
            onMapReady: () {
              Future.microtask(() {
                setState(() => _visibleBounds = _mc.camera.visibleBounds);
              });
            },
            onPositionChanged: (pos, _) {
              if (!_drawMode) setState(() => _visibleBounds = _mc.camera.visibleBounds);
            },
            onTap: !_drawMode ? null : (tapPos, latlng) {
              setState(() {
                // Premier tap = coin A (recommence une nouvelle zone si une
                // zone complète était déjà dessinée) ; second tap = coin B.
                if (_drawCornerA == null || _drawCornerB != null) {
                  _drawCornerA = latlng;
                  _drawCornerB = null;
                } else {
                  _drawCornerB = latlng;
                }
              });
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.pulsegpx.app',
              tileProvider: CachedOsmTileProvider(),
            ),
            // Zones déjà téléchargées — visualisation (vert translucide)
            PolygonLayer(polygons: [
              for (final z in _cachedZones)
                Polygon(
                  points: [
                    LatLng(z['south'] as double, z['west'] as double),
                    LatLng(z['south'] as double, z['east'] as double),
                    LatLng(z['north'] as double, z['east'] as double),
                    LatLng(z['north'] as double, z['west'] as double),
                  ],
                  color: Colors.green.withOpacity(0.18),
                  borderColor: Colors.green,
                  borderStrokeWidth: 2,
                ),
            ]),
            // Zone en cours de sélection (dessinée à la main) — orange
            if (_drawCornerA != null && _drawCornerB != null)
              PolygonLayer(polygons: [
                Polygon(
                  points: [
                    LatLng(_selectedBounds!.south, _selectedBounds!.west),
                    LatLng(_selectedBounds!.south, _selectedBounds!.east),
                    LatLng(_selectedBounds!.north, _selectedBounds!.east),
                    LatLng(_selectedBounds!.north, _selectedBounds!.west),
                  ],
                  color: Colors.orange.withOpacity(0.25),
                  borderColor: Colors.orange,
                  borderStrokeWidth: 3,
                ),
              ]),
            // Premier coin posé, en attente du second — simple marqueur
            if (_drawCornerA != null && _drawCornerB == null)
              MarkerLayer(markers: [
                Marker(point: _drawCornerA!, width: 20, height: 20,
                  child: const Icon(Icons.push_pin, color: Colors.orange, size: 20)),
              ]),
          ],
        )),

        // Panneau de contrôle
        Expanded(flex: 2, child: SingleChildScrollView(
        child: Container(
          color: const Color(0xFF0f1e3c),
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Instruction + bascule mode dessin
            Row(children: [
              Expanded(child: Text(
                _drawMode
                    ? (_drawCornerA == null
                        ? '✏️ Touchez un premier coin de la zone à pré-charger.'
                        : _drawCornerB == null
                            ? '✏️ Touchez le coin opposé pour terminer.'
                            : '✏️ Zone dessinée — touchez à nouveau pour la refaire.')
                    : '📍 Naviguez sur la carte pour sélectionner la zone, '
                      'ou touchez "Dessiner" pour une zone précise.',
                style: const TextStyle(color: Colors.white70, fontSize: 12))),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _drawMode = !_drawMode;
                  if (!_drawMode) { _drawCornerA = null; _drawCornerB = null; }
                }),
                icon: Icon(_drawMode ? Icons.close : Icons.crop_square,
                    size: 16, color: _drawMode ? Colors.orange : Colors.white70),
                label: Text(_drawMode ? 'Annuler' : 'Dessiner',
                    style: const TextStyle(fontSize: 11)),
                style: OutlinedButton.styleFrom(
                    side: BorderSide(color: _drawMode ? Colors.orange : Colors.white24)),
              ),
            ]),
            const SizedBox(height: 8),
            // Rappel important : le préchargement ne couvre QUE les tuiles
            // de carte (affichage visuel) et le graphe routier hors-ligne
            // (calcul d'itinéraire entre coordonnées déjà connues). La
            // SAISIE d'une adresse en texte libre reste impossible hors
            // connexion : elle passe par Nominatim (service en ligne), qui
            // n'a pas d'équivalent hors-ligne dans l'app. Seuls vos POI et
            // traces déjà enregistrés localement restent cherchables sans
            // réseau (recherche par nom, pas de géocodage nécessaire).
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(.08),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.orange.withOpacity(.3)),
              ),
              child: const Row(children: [
                Icon(Icons.info_outline, size: 14, color: Colors.orange),
                SizedBox(width: 6),
                Expanded(child: Text(
                  'La saisie d\'une adresse (recherche de lieu) nécessite '
                  'Internet même avec les cartes pré-chargées — seuls '
                  'l\'affichage de la carte et le calcul d\'itinéraire entre '
                  'coordonnées déjà connues fonctionnent hors connexion. Vos '
                  'POI et traces déjà enregistrés restent cherchables sans réseau.',
                  style: TextStyle(color: Colors.orange, fontSize: 10))),
              ]),
            ),
            const SizedBox(height: 10),

            // ── Carte vectorielle (.pmtiles) — importable localement ──
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(.08),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.blue.withOpacity(.3)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Row(children: [
                  Icon(Icons.layers, size: 14, color: Colors.lightBlueAccent),
                  SizedBox(width: 6),
                  Text('Carte vectorielle (.pmtiles)',
                      style: TextStyle(color: Colors.lightBlueAccent, fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 4),
                Text(
                  _pmtilesPath != null
                      ? '✅ Active : ${_pmtilesPath!.split(Platform.pathSeparator).last}\n'
                        'Toutes les cartes de l\'app utilisent ce fichier local — '
                        'fonctionne hors connexion sur Android comme sur Windows.'
                      : 'Importez un fichier .pmtiles (généré ou téléchargé pour '
                        'votre région) pour activer le rendu vectoriel partout '
                        'dans l\'app, y compris hors connexion. Sans import, les '
                        'cartes restent en mode raster (comportement actuel).',
                  style: const TextStyle(color: Colors.white54, fontSize: 10)),
                const SizedBox(height: 6),
                Row(children: [
                  if (_pmtilesImporting)
                    const Padding(padding: EdgeInsets.symmetric(vertical: 6),
                      child: SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  else ...[
                    OutlinedButton.icon(
                      onPressed: _importPmtiles,
                      icon: const Icon(Icons.file_open, size: 14),
                      label: Text(_pmtilesPath != null ? 'Remplacer' : 'Importer',
                          style: const TextStyle(fontSize: 11)),
                    ),
                    if (_pmtilesPath != null) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _removePmtiles,
                        icon: const Icon(Icons.delete_outline, size: 14, color: Colors.red),
                        label: const Text('Retirer', style: TextStyle(fontSize: 11, color: Colors.red)),
                      ),
                    ],
                  ],
                ]),
              ]),
            ),
            const SizedBox(height: 10),

            // Sliders zoom
            Row(children: [
              const Text('Zoom min :', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(child: Slider(
                value: _zoomMin.toDouble(), min: 5, max: 16,
                divisions: 11, label: '$_zoomMin',
                onChanged: _downloading ? null : (v) => setState(() {
                  _zoomMin = v.round();
                  if (_zoomMax < _zoomMin) _zoomMax = _zoomMin;
                }),
              )),
              Text('$_zoomMin', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),
            Row(children: [
              const Text('Zoom max :', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(width: 8),
              Expanded(child: Slider(
                value: _zoomMax.toDouble(), min: 5, max: 18,
                divisions: 13, label: '$_zoomMax',
                onChanged: _downloading ? null : (v) => setState(() {
                  _zoomMax = v.round();
                  if (_zoomMin > _zoomMax) _zoomMin = _zoomMax;
                }),
              )),
              Text('$_zoomMax', style: const TextStyle(color: Colors.white, fontSize: 12)),
            ]),

            // Estimation
            Row(children: [
              Icon(
                est > 5000 ? Icons.warning_amber : Icons.info_outline,
                size: 14,
                color: est > 5000 ? Colors.orange : Colors.white38),
              const SizedBox(width: 6),
              Text(
                est == 0 ? 'Bougez la carte pour estimer'
                    : '~$est tuiles (~${(est * 15 / 1024).toStringAsFixed(1)} Mo estimé)',
                style: TextStyle(
                  fontSize: 11,
                  color: est > 5000 ? Colors.orange : Colors.white54)),
            ]),
            if (est > 10000)
              const Padding(padding: EdgeInsets.only(top: 3),
                child: Text('⚠️ Zone très grande — réduire le zoom max ou la zone',
                    style: TextStyle(fontSize: 10, color: Colors.orange))),
            const SizedBox(height: 10),

            // Barre de progression
            if (_downloading || _status.isNotEmpty) ...[
              LinearProgressIndicator(
                value: _total > 0 ? _done / _total : null,
                backgroundColor: Colors.white12,
                color: Colors.amber),
              const SizedBox(height: 4),
              Text(_status, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(height: 8),
            ],

            // Bouton action
            SizedBox(width: double.infinity,
              child: _downloading
                  ? OutlinedButton.icon(
                      onPressed: () => setState(() => _cancelled = true),
                      icon: const Icon(Icons.stop, size: 16, color: Colors.red),
                      label: const Text('Annuler le téléchargement',
                          style: TextStyle(color: Colors.red)),
                      style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.red)))
                  : FilledButton.icon(
                      onPressed: est == 0 || est > 50000 ? null : _startDownload,
                      icon: const Icon(Icons.download, size: 18),
                      label: Text(est > 50000
                          ? 'Zone trop grande (max 50 000 tuiles)'
                          : 'Télécharger ~$est tuiles'),
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF003580)),
                    )),

            const Divider(color: Color(0xFF1a2f5e), height: 20),

            // ── Navigation hors-ligne (graphe routier) ──────────────────────
            const Text('🗺 Navigation hors-ligne',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            const Text('Télécharge le réseau routier OSM pour la zone visible.\n'
                'Permet de calculer des itinéraires sans connexion.',
                style: TextStyle(color: Colors.white60, fontSize: 11)),
            const SizedBox(height: 8),

            if (_graphSizes.isNotEmpty) ...[
              ...['walking', 'cycling', 'driving'].map((p) {
                final size = _graphSizes[p];
                if (size == null) return const SizedBox();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: [
                    Text(_profileLabel(p),
                        style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(width: 8),
                    Text('${size.toStringAsFixed(1)} Mo',
                        style: const TextStyle(color: Colors.green, fontSize: 11)),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        await OfflineGraph.deleteGraph(p);
                        NavigationService.invalidateGraphCache();
                        await _loadCacheInfo();
                        if (mounted) setState(() {});
                      },
                      child: const Text('Supprimer', style: TextStyle(fontSize: 11, color: Colors.red))),
                  ]),
                );
              }),
              const SizedBox(height: 4),
            ],

            Row(children: [
              const Text('Profil : ', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(width: 6),
              ...['walking', 'cycling', 'driving'].map((p) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _graphProfile = p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _graphProfile == p ? Colors.teal.withOpacity(.25) : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _graphProfile == p ? Colors.teal : Colors.white24)),
                    child: Text(_profileLabel(p),
                        style: TextStyle(fontSize: 12,
                            color: _graphProfile == p ? Colors.teal : Colors.white54))),
                ))),
            ]),
            const SizedBox(height: 8),

            if (_graphStatus.isNotEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 6),
                child: Text(_graphStatus,
                    style: TextStyle(fontSize: 11,
                        color: _graphStatus.startsWith('✅')
                            ? Colors.green : _graphStatus.startsWith('❌')
                                ? Colors.red : Colors.white54))),

            SizedBox(width: double.infinity,
              child: _downloadingGraph
                  ? const Center(child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(color: Colors.teal, strokeWidth: 2)))
                  : FilledButton.icon(
                      onPressed: _selectedBounds == null ? null : _downloadGraph,
                      icon: const Icon(Icons.route, size: 18),
                      label: Text('Télécharger réseau $_graphProfile'),
                      style: FilledButton.styleFrom(backgroundColor: Colors.teal))),

            // ── Zones déjà téléchargées (visualisées en vert sur la carte) ──
            if (_cachedZones.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Divider(color: Colors.white24, height: 1),
              const SizedBox(height: 8),
              Text('Zones pré-chargées (${_cachedZones.length})',
                  style: const TextStyle(color: Colors.white54, fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              for (int i = 0; i < _cachedZones.length; i++)
                _cachedZoneTile(i),
            ],
          ]),
        ))),
      ]),
    );
  }

  /// Ligne récapitulative d'une zone pré-chargée, avec bouton de
  /// suppression (retire uniquement de la liste de visualisation — les
  /// tuiles déjà en cache disque restent, "Vider le cache" les efface).
  /// Importe un fichier .pmtiles local (copié dans le stockage privé de
  /// l'app — voir AppDirs.mapsDir) et l'active immédiatement comme source
  /// de rendu vectoriel pour TOUTES les cartes de l'app (AppMapLayer bascule
  /// automatiquement dès que VectorMapConfig.pmtilesSource est renseigné).
  /// Fonctionne aussi bien sur Android que sur Windows — PmTilesVectorTileProvider
  /// lit directement un chemin de fichier local via dart:io, sans permission
  /// particulière puisque le fichier est copié dans le dossier privé de l'app.
  Future<void> _importPmtiles() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['pmtiles'],
        withData: true,
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Sélecteur de fichier indisponible : $e')));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    if (picked.bytes == null) return;

    setState(() => _pmtilesImporting = true);
    try {
      final dir = await AppDirs.mapsDir();
      final dest = File('${dir.path}/${picked.name}');
      await dest.writeAsBytes(picked.bytes!);

      VectorMapConfig.pmtilesSource = dest.path;
      await AppDirs.savePmtilesPath(dest.path);

      if (mounted) {
        setState(() { _pmtilesPath = dest.path; _pmtilesImporting = false; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✅ Carte vectorielle importée : ${picked.name}'),
          backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _pmtilesImporting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Erreur import : $e'), backgroundColor: Colors.red));
      }
    }
  }

  Future<void> _removePmtiles() async {
    final path = _pmtilesPath;
    VectorMapConfig.pmtilesSource = null;
    await AppDirs.savePmtilesPath(null);
    if (path != null) {
      try { await File(path).delete(); } catch (_) {}
    }
    if (mounted) setState(() => _pmtilesPath = null);
  }

  Widget _cachedZoneTile(int i) {
    final z = _cachedZones[i];
    final south = z['south'] as double, north = z['north'] as double;
    final west  = z['west']  as double, east  = z['east']  as double;
    final zMin = z['zoomMin'] as int, zMax = z['zoomMax'] as int;
    final tiles = z['tiles'] as int;
    final savedAt = DateTime.tryParse(z['savedAt'] as String? ?? '');
    final approxKm = ((north - south) * 111).abs();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        const Icon(Icons.crop_square, size: 14, color: Colors.green),
        const SizedBox(width: 6),
        Expanded(child: Text(
          '${approxKm.toStringAsFixed(0)} km × zoom $zMin-$zMax · $tiles tuiles'
          '${savedAt != null ? " · ${savedAt.day.toString().padLeft(2,'0')}/${savedAt.month.toString().padLeft(2,'0')}" : ""}',
          style: const TextStyle(color: Colors.white54, fontSize: 11))),
        IconButton(
          icon: const Icon(Icons.visibility, size: 15, color: Colors.white38),
          tooltip: 'Centrer la carte sur cette zone',
          onPressed: () => _mc.fitCamera(CameraFit.bounds(
            bounds: LatLngBounds(LatLng(south, west), LatLng(north, east)),
            padding: const EdgeInsets.all(24))),
          padding: EdgeInsets.zero, constraints: const BoxConstraints()),
        const SizedBox(width: 6),
        IconButton(
          icon: const Icon(Icons.close, size: 15, color: Colors.red),
          tooltip: 'Retirer de la liste',
          onPressed: () {
            setState(() => _cachedZones = [..._cachedZones]..removeAt(i));
            unawaited(AppDirs.saveCachedZones(_cachedZones));
          },
          padding: EdgeInsets.zero, constraints: const BoxConstraints()),
      ]),
    );
  }
}
