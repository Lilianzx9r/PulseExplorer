import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'nominatim_helper.dart';
import 'gpx_track.dart';
import 'gpx_loader.dart';
import 'gpx_overlay_painter.dart';
import 'gpx_only_view.dart';
import 'capture_service.dart';
import 'track_list_panel.dart';
import 'georef_overlay_screen.dart';
import 'poi_layer.dart';
import 'poi_export.dart';
import 'poi_search_screen.dart';
import 'overpass_service.dart';
import 'poi_geocoder.dart';
import 'html_poi_extractor.dart';
import 'app_dirs.dart';
import 'core/services/vector_map_layer.dart';
import 'session_store.dart';
import 'sessions_screen.dart';
import 'calibrated_overlay_painter.dart';
import 'map_calibration_screen.dart';
import 'backup_service.dart';
import 'backup_screen.dart';
import 'layers_panel.dart';
import 'poi_folder.dart';
import 'core/models/library_folder.dart';
import 'poi_folder_manager.dart';
import 'poi_detail_screen.dart';
import 'poi_zoom_settings.dart';
import 'map_export_screen.dart';
import 'explorer_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HtmlPoiExtractor.loadPrefs(); // charger clé API + modèle + prompt

  // Carte vectorielle : recharge le fichier .pmtiles importé lors d'une
  // session précédente (voir tile_cache_screen.dart / AppDirs.savePmtilesPath)
  // — sans ça, AppMapLayer repartirait en mode raster à chaque redémarrage
  // malgré un import déjà fait.
  VectorMapConfig.pmtilesSource = await AppDirs.loadPmtilesPath();

  // Sur Windows/desktop : intercepter le clic sur la croix de fermeture pour
  // pouvoir proposer la sauvegarde si des modifications sont en attente.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      title: 'PulseExplorer',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setPreventClose(true);
      await windowManager.show();
    });
  }

  runApp(const PulseExplorerApp());
}

class PulseExplorerApp extends StatelessWidget {
  const PulseExplorerApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PulseExplorer',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF003580)),
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver, WindowListener {

  // ── Session courante ───────────────────────────────────────────────────────
  VisuSession? _currentSession;

  // ── Config ────────────────────────────────────────────────────────────────
  final _cityController     = TextEditingController();
  final _checkInController  = TextEditingController();
  final _checkOutController = TextEditingController();
  BoundingBox?      _selectedBbox;
  List<BoundingBox> _cityResults = [];
  String            _mapSource   =
      (Platform.isAndroid || Platform.isIOS) ? 'webview' : 'gpxonly';

  // ── Données ───────────────────────────────────────────────────────────────
  final List<GpxTrack>  _tracks    = [];
  final List<PoiLayer>  _poiLayers  = [];
  final List<PoiFolder> _poiFolders = [];
  final List<GpxFolder> _gpxFolders = []; // dossiers de traces GPX (nouveau)
  bool _isDirty = false; // modifications non sauvegardées
  final PoiZoomSettings _zoomSettings = PoiZoomSettings();
  int                   _maxZipMb  = 50;

  // ── UI state ──────────────────────────────────────────────────────────────
  bool    _isLoading    = false;
  String? _errorMessage;
  int     _step         = 0;

  // ── Capture ───────────────────────────────────────────────────────────────
  WebViewController? _webViewController;
  ui.Image?          _screenshotImage;
  Uint8List?         _screenshotBytes;
  final GlobalKey    _repaintKey = GlobalKey();
  bool               _captureServiceRunning = false;
  Uint8List?         _pendingCaptureBytes;

  // ── Overlay ───────────────────────────────────────────────────────────────
  bool               _showTrackPanel = false;
  CalibrationResult? _calibration;      // résultat du calage affine
  bool               _showCalibPoints = false;
  bool               _debugPoiMode    = false;   // mode debug POI
  bool   _dragMode       = false;
  Offset _gpxOffset      = Offset.zero;
  Offset _dragStart      = Offset.zero;
  Offset _offsetAtDrag   = Offset.zero;

  // ── Bouton capture WebView draggable ──────────────────────────────────────
  Offset _captureButtonPos = const Offset(16, 16); // depuis le bas

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
    }
    _initDates();
    _loadLastSession();

    const EventChannel('pulse_gpx/capture_stream')
        .receiveBroadcastStream()
        .listen((data) {
      if (data is Uint8List) {
        setState(() => _pendingCaptureBytes = data);
        _applyCapture(data);
      }
    }, onError: (_) {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  /// Appelé quand l'utilisateur clique sur la croix de fermeture de la fenêtre
  /// (Windows/Linux/macOS) — propose la sauvegarde si modifications en attente.
  @override
  void onWindowClose() async {
    if (_isDirty) {
      final save = await showDialog<bool>(context: context,
        builder: (_) => AlertDialog(
          title: const Text('Modifications non sauvegardées'),
          content: const Text('Voulez-vous sauvegarder avant de quitter ?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, null),
                child: const Text('Annuler')),
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Quitter sans sauvegarder')),
            FilledButton(onPressed: () => Navigator.pop(context, true),
                child: const Text('Sauvegarder')),
          ],
        ));
      if (save == null) return; // annulé — ne pas fermer
      if (save) await _saveCurrentSession();
    }
    await windowManager.destroy();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _captureServiceRunning && _pendingCaptureBytes != null) {
      _applyCapture(_pendingCaptureBytes!);
      _pendingCaptureBytes = null;
    }
  }

  void _initDates() {
    final now = DateTime.now();
    _checkInController.text  = _fmt(now.add(const Duration(days: 1)));
    _checkOutController.text = _fmt(now.add(const Duration(days: 2)));
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

  // ── Persistence sessions ───────────────────────────────────────────────────
  Future<void> _loadLastSession() async {
    final sessions = await SessionStore.loadAll();
    if (sessions.isNotEmpty) _applySession(sessions.first);
  }

  void _applySession(VisuSession s) {
    setState(() {
      _currentSession = s;
      // Le mode WebView n'existe que sur Android/iOS — si une session
      // synchronisée depuis mobile arrive sur Windows/desktop, on bascule
      // sur un mode disponible pour éviter le crash du DropdownButton.
      _mapSource = (s.mapSource == 'webview' && !(Platform.isAndroid || Platform.isIOS))
          ? 'gpxonly' : s.mapSource;
      _cityController.text     = s.cityName;
      _checkInController.text  = s.checkIn.isNotEmpty  ? s.checkIn  : _checkInController.text;
      _checkOutController.text = s.checkOut.isNotEmpty ? s.checkOut : _checkOutController.text;
      if (s.bboxMinLat != null) {
        _selectedBbox = BoundingBox(
          minLat: s.bboxMinLat!, maxLat: s.bboxMaxLat!,
          minLon: s.bboxMinLon!, maxLon: s.bboxMaxLon!,
          displayName: s.bboxLabel ?? '',
        );
      }
      _tracks.clear();
      _tracks.addAll(SessionStore.deserializeTracks(s.gpxTracksData));
      _poiLayers.clear();
      _poiLayers.addAll(s.poiLayersData.map((d) => PoiLayer.fromJson(d)));
      // Charger les dossiers POI (vider d'abord pour éviter les doublons)
      _poiFolders.clear();
      _poiFolders.addAll(SessionStore.deserializeFolders(s.poiFoldersData));
      // Charger les dossiers GPX
      _gpxFolders.clear();
      _gpxFolders.addAll(SessionStore.deserializeGpxFolders(s.gpxFoldersData));
    });
  }

  // ── Helpers détection doublons (distance + similarité de nom) ──────────────
  double _distM(double lat1, double lon1, double lat2, double lon2) {
    final dlat = (lat2 - lat1) * 111320;
    final dlon = (lon2 - lon1) * 111320 * _cosApprox(lat1 * 3.14159 / 180);
    final sq = dlat * dlat + dlon * dlon;
    return sq <= 0 ? 0 : _sqrtApprox(sq);
  }

  double _cosApprox(double x) {
    double r = 1, t = 1;
    for (int i = 1; i <= 8; i++) { t *= -x * x / (2 * i * (2 * i - 1)); r += t; }
    return r;
  }

  double _sqrtApprox(double x) {
    if (x <= 0) return 0;
    double s = x / 2;
    for (int i = 0; i < 20; i++) s = (s + x / s) / 2;
    return s;
  }

  double _nameSim(String a, String b) {
    final na = a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final nb = b.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (na.isEmpty || nb.isEmpty) return 0;
    if (na == nb) return 1.0;
    Set<String> bigrams(String s) {
      final set = <String>{};
      for (int i = 0; i < s.length - 1; i++) set.add(s.substring(i, i + 2));
      return set;
    }
    final ba = bigrams(na), bb = bigrams(nb);
    final common = ba.intersection(bb).length;
    if (ba.length + bb.length == 0) return 0;
    return 2 * common / (ba.length + bb.length);
  }

  // ── Migration des anciennes couches "Blog —" vers des dossiers ─────────────
  /// dans un dossier "Blog — JJ/MM" (regroupé par date si le nom le permet,
  /// sinon dans un dossier générique "Blog (importé)").
  void _migrateBlogLayersToFolders() {
    final toMigrate = _poiLayers
        .where((l) => l.label.startsWith('Blog —') || l.label.startsWith('Blog -'))
        .toList();
    if (toMigrate.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Aucune couche "Blog" à ranger'),
        backgroundColor: Colors.grey));
      return;
    }

    int migrated = 0;
    for (final layer in toMigrate) {
      // Le nom de la couche EST déjà "Blog — JJ/MM" (ancien format) → devient
      // le nom du dossier ; la couche prend un nom générique "Import".
      final folderName = layer.label;
      PoiFolder? folder;
      for (final f in _poiFolders) {
        if (f.label.trim().toLowerCase() == folderName.trim().toLowerCase()) {
          folder = f; break;
        }
      }
      folder ??= PoiFolder(label: folderName, layers: []);
      if (!_poiFolders.contains(folder)) _poiFolders.add(folder);

      _poiLayers.remove(layer);
      layer.label = 'Import';
      folder.layers.add(layer);
      migrated++;
    }

    setState(() => _isDirty = true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('📁 $migrated couche${migrated > 1 ? "s" : ""} "Blog" rangée${migrated > 1 ? "s" : ""} en dossier'),
      backgroundColor: Colors.green,
      duration: const Duration(seconds: 3)));
  }

  // ── Détection globale des doublons parmi tous les POI ──────────────────────
  void _detectAllDuplicates() {
    final all = <({PoiPoint poi, String layerLabel, PoiLayer layer})>[
      for (final l in _poiLayers)
        for (final p in l.points) (poi: p, layerLabel: l.label, layer: l),
      for (final f in _poiFolders)
        for (final l in f.layers)
          for (final p in l.points)
            (poi: p, layerLabel: '${f.label} / ${l.label}', layer: l),
    ];

    if (all.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Pas assez de POI pour détecter des doublons'),
        backgroundColor: Colors.grey));
      return;
    }

    final pairs = <(int, int)>[];
    for (int i = 0; i < all.length; i++) {
      for (int j = i + 1; j < all.length; j++) {
        final a = all[i].poi, b = all[j].poi;
        final dist = _distM(a.lat, a.lon, b.lat, b.lon);
        if (dist < 100 || _nameSim(a.name, b.name) > 0.8) pairs.add((i, j));
      }
    }

    if (pairs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ Aucun doublon détecté'),
        backgroundColor: Colors.green));
      return;
    }

    // Dialog avec liste des paires et bouton Fusionner pour chacune
    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setDlg) {
        // Recalculer pairs à chaque setState (certains peuvent avoir été résolus)
        final remaining = pairs.where((p) {
          final (ia, ib) = p;
          return ia < all.length && ib < all.length &&
              all[ia].layer.points.contains(all[ia].poi) &&
              all[ib].layer.points.contains(all[ib].poi);
        }).toList();

        return AlertDialog(
          title: Text('⚠️ ${remaining.length} doublon${remaining.length != 1 ? "s" : ""} potentiel${remaining.length != 1 ? "s" : ""}'),
          contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          content: SizedBox(width: 500, height: 420,
            child: remaining.isEmpty
                ? const Center(child: Text('✅ Tous les doublons ont été traités',
                    style: TextStyle(color: Colors.green)))
                : ListView.builder(
                    itemCount: remaining.length,
                    itemBuilder: (ctx2, i) {
                      final (ia, ib) = remaining[i];
                      final a = all[ia], b = all[ib];
                      final dist = _distM(a.poi.lat, a.poi.lon, b.poi.lat, b.poi.lon);
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: Padding(padding: const EdgeInsets.all(10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(a.poi.name,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                Text(a.layerLabel,
                                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
                              ])),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: Icon(dist < 100 ? Icons.location_on : Icons.text_fields,
                                    size: 16, color: Colors.orange)),
                              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text(b.poi.name, textAlign: TextAlign.end,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                Text(b.layerLabel, textAlign: TextAlign.end,
                                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
                              ])),
                            ]),
                            const SizedBox(height: 4),
                            Text(dist < 100
                                ? '📍 ${dist.toStringAsFixed(0)} m d\'écart'
                                : '🔤 ${(_nameSim(a.poi.name, b.poi.name) * 100).toStringAsFixed(0)}% similaire',
                                style: const TextStyle(fontSize: 10, color: Colors.orange)),
                            const SizedBox(height: 6),
                            Row(children: [
                              const Spacer(),
                              // Ignorer ce doublon
                              OutlinedButton.icon(
                                onPressed: () {
                                  setDlg(() => pairs.removeAt(
                                      pairs.indexOf(remaining[i])));
                                },
                                icon: const Icon(Icons.close, size: 14),
                                label: const Text('Ignorer', style: TextStyle(fontSize: 11)),
                                style: OutlinedButton.styleFrom(
                                    minimumSize: const Size(0, 28),
                                    padding: const EdgeInsets.symmetric(horizontal: 10)),
                              ),
                              const SizedBox(width: 8),
                              // Fusionner les deux
                              FilledButton.icon(
                                onPressed: () async {
                                  await _openMergeDialog(
                                    ctx: ctx,
                                    poiA: a.poi, layerA: a.layer, labelA: a.layerLabel,
                                    poiB: b.poi, layerB: b.layer, labelB: b.layerLabel,
                                    onMerged: () {
                                      setDlg(() => pairs.removeAt(
                                          pairs.indexOf(remaining[i])));
                                      setState(() => _isDirty = true);
                                    },
                                  );
                                },
                                icon: const Icon(Icons.merge_type, size: 14),
                                label: const Text('Fusionner', style: TextStyle(fontSize: 11)),
                                style: FilledButton.styleFrom(
                                    backgroundColor: Colors.deepOrange,
                                    minimumSize: const Size(0, 28),
                                    padding: const EdgeInsets.symmetric(horizontal: 10)),
                              ),
                            ]),
                          ]),
                        ),
                      );
                    },
                  )),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(context),
                child: const Text('Fermer')),
          ],
        );
      }),
    );
  }

  /// Ouvre le dialog de fusion pour deux PoiPoint en doublon
  Future<void> _openMergeDialog({
    required BuildContext ctx,
    required PoiPoint poiA, required PoiLayer layerA, required String labelA,
    required PoiPoint poiB, required PoiLayer layerB, required String labelB,
    required VoidCallback onMerged,
  }) async {
    final nameCtrl = TextEditingController(text: poiA.name);
    final descCtrl = TextEditingController(text: poiA.description ?? '');
    final latCtrl  = TextEditingController(text: poiA.lat.toStringAsFixed(6));
    final lonCtrl  = TextEditingController(text: poiA.lon.toStringAsFixed(6));

    final kept = await showDialog<String>(
      context: ctx,
      builder: (_) => StatefulBuilder(builder: (dctx, setMrg) {
        return AlertDialog(
          backgroundColor: const Color(0xFF16213e),
          title: const Text('Fusionner les doublons',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: SizedBox(width: 500,
            child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Headers
              Row(children: [
                Expanded(child: _dupColHeader(labelA, Colors.blue)),
                const SizedBox(width: 8),
                Expanded(child: _dupColHeader(labelB, Colors.teal)),
              ]),
              const SizedBox(height: 8),
              // Nom
              _mergeRow('Nom',
                  valA: poiA.name, valB: poiB.name, ctrl: nameCtrl, setMrg: setMrg),
              // Description
              _mergeRow('Description',
                  valA: poiA.description ?? '', valB: poiB.description ?? '',
                  ctrl: descCtrl, setMrg: setMrg, maxLines: 3),
              // Lat/Lon
              Row(children: [
                Expanded(child: _mergeRow('Latitude',
                    valA: poiA.lat.toStringAsFixed(6),
                    valB: poiB.lat.toStringAsFixed(6),
                    ctrl: latCtrl, setMrg: setMrg)),
                const SizedBox(width: 6),
                Expanded(child: _mergeRow('Longitude',
                    valA: poiA.lon.toStringAsFixed(6),
                    valB: poiB.lon.toStringAsFixed(6),
                    ctrl: lonCtrl, setMrg: setMrg)),
              ]),
              const SizedBox(height: 8),
              const Text('Lequel conserver ?',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.pop(dctx, 'A'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blue,
                      side: const BorderSide(color: Colors.blue)),
                  child: Text('Garder $labelA', overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11)),
                )),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton(
                  onPressed: () => Navigator.pop(dctx, 'B'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.teal,
                      side: const BorderSide(color: Colors.teal)),
                  child: Text('Garder $labelB', overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11)),
                )),
              ]),
            ])),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dctx),
                child: const Text('Annuler', style: TextStyle(color: Colors.white54))),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dctx, 'merge'),
              icon: const Icon(Icons.merge_type, size: 16),
              label: const Text('Fusionner (champs ci-dessus)'),
              style: FilledButton.styleFrom(backgroundColor: Colors.deepOrange),
            ),
          ],
        );
      }),
    );

    if (kept == null) return;
    final newLat = double.tryParse(latCtrl.text) ?? poiA.lat;
    final newLon = double.tryParse(lonCtrl.text) ?? poiA.lon;
    final merged = PoiPoint(
      name: nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : poiA.name,
      lat: newLat, lon: newLon,
      description: descCtrl.text.trim().isNotEmpty ? descCtrl.text.trim() : null,
      type: poiA.type,
      photoUrls: [...poiA.photoUrls, ...poiB.photoUrls].toSet().toList(),
    );

    // Remplacer le POI "keeper" par la version fusionnée, supprimer l'autre
    if (kept == 'A' || kept == 'merge') {
      final idx = layerA.points.indexOf(poiA);
      if (idx >= 0) layerA.points[idx] = merged;
      layerB.points.remove(poiB);
    } else {
      final idx = layerB.points.indexOf(poiB);
      if (idx >= 0) layerB.points[idx] = merged;
      layerA.points.remove(poiA);
    }
    onMerged();
  }

  Widget _dupColHeader(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withOpacity(.15),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withOpacity(.4))),
    child: Text(label,
        style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
        overflow: TextOverflow.ellipsis));

  Widget _mergeRow(String label, {
    required String valA, required String valB,
    required TextEditingController ctrl, required void Function(void Function()) setMrg,
    int maxLines = 1,
  }) {
    return Padding(padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        const SizedBox(height: 3),
        TextField(controller: ctrl, maxLines: maxLines,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF0f3460))),
            focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.amber)),
            border: OutlineInputBorder())),
        if (valA != valB) ...[
          const SizedBox(height: 3),
          Row(children: [
            _optionChip('← $valA', Colors.blue,
                () => setMrg(() => ctrl.text = valA)),
            const SizedBox(width: 6),
            _optionChip('→ $valB', Colors.teal,
                () => setMrg(() => ctrl.text = valB)),
          ]),
        ],
      ]));
  }

  Widget _optionChip(String label, Color color, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withOpacity(.4))),
        child: Text(
          label.length > 30 ? '${label.substring(0, 30)}…' : label,
          style: TextStyle(fontSize: 9, color: color))));


  Future<void> _saveCurrentSession() async {
    _isDirty = false;
    final session = _currentSession ?? VisuSession(
      label:    _cityController.text.isNotEmpty ? _cityController.text : 'Session',
      mapSource: _mapSource,
      cityName:  _cityController.text,
      checkIn:   _checkInController.text,
      checkOut:  _checkOutController.text,
    );
    session.mapSource  = _mapSource;
    session.cityName   = _cityController.text;
    session.checkIn    = _checkInController.text;
    session.checkOut   = _checkOutController.text;
    session.bboxMinLat = _selectedBbox?.minLat;
    session.bboxMaxLat = _selectedBbox?.maxLat;
    session.bboxMinLon = _selectedBbox?.minLon;
    session.bboxMaxLon = _selectedBbox?.maxLon;
    session.bboxLabel  = _selectedBbox?.displayName;
    session.gpxTracksData = SessionStore.serializeTracks(_tracks);
    session.poiLayersData  = _poiLayers.map((l) => l.toJson()).toList();
    session.poiFoldersData = SessionStore.serializeFolders(_poiFolders);
    session.gpxFoldersData = SessionStore.serializeGpxFolders(_gpxFolders);
    await SessionStore.upsert(session);
    setState(() => _currentSession = session);
  }

  Future<void> _openSessionsScreen() async {
    await _saveCurrentSession();
    if (!mounted) return;
    final allSessions = await SessionStore.loadAll();
    if (!mounted) return;
    final selected = await Navigator.push<VisuSession>(context,
      MaterialPageRoute(builder: (_) =>
          SessionsScreen(
            currentSessionId: _currentSession?.id ?? '',
            currentSessions:  allSessions,
          )));
    if (selected != null) _applySession(selected);
  }

  Future<void> _newSession() async {
    final ctrl = TextEditingController();
    final label = await showDialog<String>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nouvelle session'),
        content: TextField(controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nom de la session', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Créer'),
          ),
        ],
      ),
    );
    if (label == null || label.isEmpty) return;
    final defaultSource = (Platform.isAndroid || Platform.isIOS) ? 'webview' : 'gpxonly';
    setState(() {
      _currentSession = VisuSession(
        label: label, mapSource: defaultSource,
        cityName: '', checkIn: _checkInController.text, checkOut: _checkOutController.text,
      );
      _tracks.clear();
      _poiLayers.clear();
      _poiFolders.clear();
      _gpxFolders.clear();
      _selectedBbox = null;
      _cityResults  = [];
      _cityController.clear();
      _mapSource    = defaultSource;
      _screenshotImage = null;
      _screenshotBytes = null;
    });
  }

  // ── Recherche ville ────────────────────────────────────────────────────────
  Future<void> _searchCity() async {
    final city = _cityController.text.trim();
    if (city.isEmpty) return;
    setState(() { _isLoading = true; _errorMessage = null; _cityResults = []; _selectedBbox = null; });
    try {
      final results = await NominatimHelper.searchCity(city);
      setState(() => _cityResults = results);
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── GPX ───────────────────────────────────────────────────────────────────
  Future<void> _pickFiles() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final loaded = await GpxLoader.pickFiles(context, maxZipBytes: _maxZipMb * 1024 * 1024);
      if (loaded != null && loaded.isNotEmpty) {
        final before = _tracks.length;
        for (int i = 0; i < loaded.length; i++) {
          _tracks.add(GpxTrack(data: loaded[i].data, fileName: loaded[i].fileName,
              color: trackColorForIndex(_tracks.length)));
          _isDirty = true;
        }
        setState(() {});
        if (_selectedBbox == null) _autoCenter();
        final added = _tracks.length - before;
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$added tracé(s) importé(s)'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2)));
      } else if (loaded != null && loaded.isEmpty) {
        setState(() => _errorMessage = 'Aucun tracé GPX valide trouvé');
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickFolder() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final loaded = await GpxLoader.pickFolder(context, maxZipBytes: _maxZipMb * 1024 * 1024);
      if (loaded != null && loaded.isNotEmpty) {
        for (int i = 0; i < loaded.length; i++) {
          _tracks.add(GpxTrack(data: loaded[i].data, fileName: loaded[i].fileName,
              color: trackColorForIndex(_tracks.length)));
        }
        setState(() {});
        if (_selectedBbox == null) _autoCenter();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${loaded.length} tracé(s) chargé(s)'),
          backgroundColor: Colors.green,
        ));
      } else {
        setState(() => _errorMessage = 'Aucun fichier GPX ou ZIP trouvé');
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _autoCenter() {
    if (_tracks.isEmpty) return;
    double minLat=90, maxLat=-90, minLon=180, maxLon=-180;
    for (final t in _tracks) {
      if (t.data.minLat < minLat) minLat = t.data.minLat;
      if (t.data.maxLat > maxLat) maxLat = t.data.maxLat;
      if (t.data.minLon < minLon) minLon = t.data.minLon;
      if (t.data.maxLon > maxLon) maxLon = t.data.maxLon;
    }
    setState(() => _selectedBbox = BoundingBox(
      minLat: minLat-0.05, maxLat: maxLat+0.05,
      minLon: minLon-0.05, maxLon: maxLon+0.05,
      displayName: _tracks.length == 1 ? _tracks.first.displayName : '${_tracks.length} tracés',
    ));
  }

  // ── Recherche / import POI — point d'entrée unique ──────────────────────────
  // Remplace les 4 méthodes _openPlaceSearch / _openOverpass /
  // _openBlogPoiScreen / _openHtmlPoiScreen : un seul écran avec sélecteur
  // de source (voir poi_search_screen.dart).
  Future<void> _openPoiSearchHub() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => PoiSearchScreen(
        rootLayers: _poiLayers,
        folders:    _poiFolders,
        tracks:     _tracks,
        hintBbox:   _selectedBbox,
        onImported: () => setState(() => _isDirty = true),
      ),
    ));
    setState(() {});
  }

  // ── Gestionnaire de dossiers POI ───────────────────────────────────────────
  Future<void> _openFolderManager() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => PoiFolderManager(
        folders:      _poiFolders,
        rootLayers:   _poiLayers,
        sessionLabel: 'Session courante',
      ),
    ));
    setState(() {});
  }

  // ── Menu contextuel POI ──────────────────────────────────────────────────
  void _showPoiMenu(BuildContext ctx, PoiLayer layer, PoiPoint poi) {
    showModalBottomSheet(
      context: ctx,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        // En-tête
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(children: [
            Container(width: 12, height: 12,
                decoration: BoxDecoration(color: layer.color,
                    shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(poi.name, style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
                Text('${_poiTypeLabel(poi.type)}  •  '
                    '${poi.lat.toStringAsFixed(5)}, ${poi.lon.toStringAsFixed(5)}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
              ],
            )),
          ]),
        ),
        if (poi.hasPhotos) Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Row(children: [
            const Icon(Icons.photo_library, size: 14, color: Colors.blue),
            const SizedBox(width: 4),
            Text('${poi.localPhotos.length + poi.photoUrls.length} photo(s)',
                style: const TextStyle(fontSize: 12, color: Colors.blue)),
          ]),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.edit, color: Colors.blue),
          title: const Text('Modifier'),
          onTap: () { Navigator.pop(ctx); _editPoi(layer, poi); },
        ),
        ListTile(
          leading: Icon(Icons.visibility_off, color: Colors.orange.shade700),
          title: const Text('Masquer la couche'),
          onTap: () { Navigator.pop(ctx); setState(() => layer.visible = false); },
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline, color: Colors.red),
          title: const Text('Supprimer ce POI'),
          onTap: () {
            Navigator.pop(ctx);
            setState(() => layer.points.remove(poi));
          },
        ),
        const SizedBox(height: 8),
      ])),
    );
  }

  String _poiTypeLabel(String? type) {
    const map = {
      'hotel': '🏨 Hôtel', 'restaurant': '🍽️ Restaurant',
      'monument': '🏛️ Monument', 'peak': '⛰️ Sommet',
      'waterfall': '💧 Cascade', 'castle': '🏰 Château',
      'museum': '🖼️ Musée', 'village': '🏘️ Village',
      'city': '🏙️ Ville', 'chapel': '⛪ Chapelle',
      'parking': '🅿️ Parking', 'fuel': '⛽ Station',
      'lake': '🌊 Lac', 'forest': '🌲 Forêt',
    };
    return map[type] ?? '📍 POI';
  }

  // ── Édition d'un POI (avec photos) ─────────────────────────────────────────
  Future<void> _editPoi(PoiLayer layer, PoiPoint poi) async {
    final updated = await Navigator.push<PoiPoint>(context, MaterialPageRoute(
      builder: (_) => PoiDetailScreen(poi: poi, color: layer.color),
    ));
    if (updated != null) {
      final idx = layer.points.indexOf(poi);
      if (idx >= 0) {
        setState(() => layer.points[idx] = updated);
      }
    }
  }

  Widget _poiTypeIcon(String? type) {
    const icons = {
      'hotel':      '🏨', 'restaurant': '🍽️', 'monument': '🏛️',
      'peak':       '⛰️', 'waterfall':  '💧', 'castle':   '🏰',
      'museum':     '🖼️', 'village':    '🏘️', 'city':     '🏙️',
      'chapel':     '⛪', 'parking':    '🅿️', 'fuel':     '⛽',
      'lake':       '🌊', 'forest':     '🌲',
    };
    final emoji = icons[type] ?? '📍';
    return Text(emoji, style: const TextStyle(fontSize: 16));
  }

  // ── Capture ───────────────────────────────────────────────────────────────
  Future<void> _setupCaptureMode() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      bool hasOverlay = await CaptureService.hasOverlayPermission();
      if (!hasOverlay) {
        hasOverlay = await CaptureService.requestOverlayPermission();
        if (!hasOverlay) throw Exception('Permission overlay refusée');
      }
      final code = await CaptureService.requestMediaProjection();
      if (code == null) { setState(() => _errorMessage = 'Capture annulée.'); return; }
      await CaptureService.startFloatingService(code);
      setState(() => _captureServiceRunning = true);
      if (mounted) _showCaptureInstructions();
    } catch (e) {
      setState(() => _errorMessage = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showCaptureInstructions() {
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Row(children: [Icon(Icons.camera_alt, color: Color(0xFF003580)), SizedBox(width:8), Text('Service actif')]),
      content: const Text('📸 Bouton flottant visible.\n\n1. Ouvrez votre carte\n2. Naviguez\n3. Appuyez 📸\n4. Retour automatique'),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
    ));
  }

  Future<void> _stopCaptureService() async {
    await CaptureService.stopFloatingService();
    setState(() => _captureServiceRunning = false);
  }

  Future<void> _applyCapture(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      setState(() { _screenshotImage = frame.image; _screenshotBytes = bytes; _step = 2; });
      await _stopCaptureService();
    } catch (e) {
      setState(() => _errorMessage = 'Erreur capture: $e');
    }
  }

  // ── Ouvrir l'écran de calage ──────────────────────────────────────────────
  Future<void> _openCalibration() async {
    if (_screenshotBytes == null || _screenshotImage == null) return;

    // Rassembler tous les POI connus (toutes les couches)
    final allPois = _poiLayers
        .where((l) => l.visible)
        .expand((l) => l.points)
        .toList();

    if (allPois.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: const Text("Ajoutez d'abord des POI via Extraction HTML pour caler la carte"),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    final result = await Navigator.push<CalibrationResult>(
      context,
      MaterialPageRoute(builder: (_) => MapCalibrationScreen(
        screenshotBytes: _screenshotBytes!,
        screenshotImage: _screenshotImage!,
        knownPois:       allPois,
      )),
    );

    if (result != null) {
      setState(() => _calibration = result);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Calage appliqué — ${result.points.length} points, '
          'RMS: ${result.rmsPixels.toStringAsFixed(1)}px'),
        backgroundColor: result.rmsPixels < 20 ? Colors.green : Colors.orange,
      ));
    }
  }

  Future<void> _pasteFromClipboard() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      const channel = MethodChannel('pulse_gpx/capture');
      final Uint8List? bytes = await channel.invokeMethod<Uint8List>('getImage');
      if (bytes == null || bytes.isEmpty) throw Exception('Aucune image');
      await _applyCapture(bytes);
    } catch (_) {
      _showClipboardFallback();
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showClipboardFallback() {
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Importer l\'image'),
      content: const Text('Pas d\'image dans le presse-papiers.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: () { Navigator.pop(context); _pickImageFile(); }, child: const Text('Importer')),
      ],
    ));
  }

  Future<void> _pickImageFile() async {
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      final bytes = await GpxLoader.pickImageBytes(context);
      if (bytes == null) return;
      await _applyCapture(bytes);
    } catch (e) {
      setState(() => _errorMessage = 'Erreur: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _openBookingWebView() {
    if (_selectedBbox == null) return;
    // WebView uniquement disponible sur Android/iOS
    if (!Platform.isAndroid && !Platform.isIOS) {
      setState(() { _mapSource = 'clipboard'; });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('WebView non disponible sur desktop — utilisez Presse-papiers ou Importer une image'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 4),
      ));
      return;
    }
    final url = NominatimHelper.buildBookingUrl(
      bbox: _selectedBbox!, checkIn: _checkInController.text, checkOut: _checkOutController.text);
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36')
      ..loadRequest(Uri.parse(url));
    setState(() { _webViewController = controller; _step = 1; });
  }

  Future<void> _captureWebView() async {
    setState(() => _isLoading = true);
    try {
      final boundary = _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw Exception('Impossible de capturer');
      final img  = await boundary.toImage(pixelRatio: 2.0);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      await _applyCapture(data!.buffer.asUint8List());
    } catch (e) {
      setState(() => _errorMessage = 'Erreur: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── Sauvegarde / Import ───────────────────────────────────────────────────
  Future<void> _openMapExport() async {
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => MapExportScreen(
        tracks:       _tracks,
        rootLayers:   _poiLayers,
        folders:      _poiFolders,
        sessionLabel: _currentSession?.label ?? 'PulseExplorer',
      ),
    ));
  }

  Future<void> _openBackup() async {
    // Charger toutes les sessions existantes pour la sauvegarde
    final allSessions = await SessionStore.loadAll();

    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => BackupScreen(
        sessions:   allSessions,
        poiLayers:  _poiLayers,
        poiFolders: _poiFolders,
        tracks:     _tracks,
        onImported: (data) async {
          // Fusionner les sessions importées
          final existing = await SessionStore.loadAll();
          final merged   = List<VisuSession>.from(existing);
          for (final s in data.sessions) {
            if (!merged.any((e) => e.id == s.id)) merged.add(s);
          }
          await SessionStore.saveAll(merged);

          // Fusionner tracés, POI et dossiers en mémoire
          if (mounted) {
            setState(() {
              // Tracés GPX
              for (final t in data.tracks) {
                if (!_tracks.any((e) => e.fileName == t.fileName)) {
                  _tracks.add(t);
                }
              }
              // Couches POI racine
              for (final l in data.poiLayers) {
                if (!_poiLayers.any((e) => e.id == l.id)) _poiLayers.add(l);
              }
              // Dossiers POI
              for (final f in data.poiFolders) {
                if (!_poiFolders.any((e) => e.id == f.id)) _poiFolders.add(f);
              }
              _isDirty = data.tracks.isNotEmpty ||
                  data.poiLayers.isNotEmpty ||
                  data.poiFolders.isNotEmpty;
            });
          }

          // Persister dans la session courante
          if (_isDirty) await _saveCurrentSession();
        },
      ),
    ));
  }

  Future<void> _proceed() async {
    switch (_mapSource) {
      case 'gpxonly':
        // Passage direct — pas de sauvegarde pour ne pas bloquer
        setState(() => _step = 2);
        return;
      case 'webview':   _openBookingWebView(); break;
      case 'clipboard': await _pasteFromClipboard(); break;
      case 'file':      await _pickImageFile(); break;
      case 'capture':   await _setupCaptureMode(); break;
    }
    await _saveCurrentSession();
  }

  bool _canProceed() {
    final hasPoi = _poiLayers.isNotEmpty ||
        _poiFolders.any((f) => f.layers.isNotEmpty);
    // Mode OSM : autoriser si au moins un tracé ou POI
    if (_mapSource == 'gpxonly') return _tracks.isNotEmpty || hasPoi;
    if (_tracks.isEmpty && !hasPoi) return false;
    if (_mapSource == 'webview' && _selectedBbox == null) return false;
    return true;
  }

  void _goBack() {
    if (_captureServiceRunning) _stopCaptureService();
    setState(() { _step = 0; _showTrackPanel = false; _dragMode = false; });
  }

  Future<void> _openExplorer() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExplorerScreen(initialBounds: _selectedBbox),
      ),
    );
  }

  // ─────────────────────────────── BUILD ────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (_step > 0) { _goBack(); return false; }
        if (_isDirty) {
          final save = await showDialog<bool>(context: context,
            builder: (_) => AlertDialog(
              title: const Text('Modifications non sauvegardées'),
              content: const Text('Voulez-vous sauvegarder avant de quitter ?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false),
                    child: const Text('Quitter sans sauvegarder')),
                FilledButton(onPressed: () => Navigator.pop(context, true),
                    child: const Text('Sauvegarder')),
              ],
            ));
          if (save == true) await _saveCurrentSession();
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF003580),
          foregroundColor: Colors.white,
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_step == 0 ? 'PulseExplorer' : _step == 1 ? 'Carte Booking' : 'Superposition',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            if (_currentSession != null)
              Text(_currentSession!.label,
                  style: const TextStyle(fontSize: 10, color: Colors.white70)),
          ]),
          leading: _step > 0
              ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: _goBack)
              : null,
          actions: [
            if (_step == 2 && _mapSource != 'gpxonly') ...[
              IconButton(
                icon: Icon(_showTrackPanel ? Icons.layers : Icons.layers_outlined, color: Colors.white),
                onPressed: () => setState(() => _showTrackPanel = !_showTrackPanel),
              ),
              // Calage affine par OCR + tap
              if (_screenshotBytes != null && _screenshotImage != null)
                IconButton(
                  icon: Icon(Icons.my_location,
                      color: _calibration != null ? Colors.greenAccent : Colors.amber),
                  tooltip: _calibration != null
                      ? 'Recalage (${_calibration!.points.length} pts, RMS ${_calibration!.rmsPixels.toStringAsFixed(0)}px)'
                      : 'Caler la carte sur le GPX',
                  onPressed: _openCalibration,
                ),
              // Toggle points de calage
              if (_calibration != null)
                IconButton(
                  icon: Icon(_showCalibPoints ? Icons.gps_fixed : Icons.gps_not_fixed,
                      color: Colors.cyan),
                  tooltip: 'Points de calage',
                  onPressed: () => setState(() => _showCalibPoints = !_showCalibPoints),
                ),
            ],
            if (_captureServiceRunning)
              IconButton(icon: const Icon(Icons.stop_circle, color: Colors.red),
                  onPressed: _stopCaptureService),
          ],
        ),
        body: Stack(children: [
          Offstage(offstage: _step != 0, child: _buildStep0()),
          Offstage(offstage: _step != 1, child: _buildStep1()),
          Offstage(offstage: _step != 2, child: _buildStep2()),
        ]),
      ),
    );
  }

  // ─── Étape 0 : Configuration ───────────────────────────────────────────────
  Widget _buildStep0() {
    final hasPoi = _poiLayers.isNotEmpty || _poiFolders.any((f) => f.layers.isNotEmpty);
    final hasData = _tracks.isNotEmpty || hasPoi;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ══════════════════════════════════════════════════════════════════
        // BLOC 1 : SESSION ACTIVE
        // ══════════════════════════════════════════════════════════════════
        _SessionBanner(
          session:        _currentSession,
          isDirty:        _isDirty,
          onOpen:         _openSessionsScreen,
          onNew:          _newSession,
          onSave: () async {
            await _saveCurrentSession();
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Session sauvegardée ✓'),
                  duration: Duration(seconds: 1)));
          },
          onBackup:       _openBackup,
          onExport:       _openMapExport,
        ),

        const SizedBox(height: 12),

        // ══════════════════════════════════════════════════════════════════
        // BOUTON PRINCIPAL — en haut pour accès rapide
        // ══════════════════════════════════════════════════════════════════
        FilledButton.icon(
          onPressed: _canProceed() ? _proceed : null,
          icon: Icon(_modeIcon()),
          label: Text(_modeLabel()),
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 52),
            backgroundColor: _canProceed() ? _modeColor() : Colors.grey.shade400,
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _openExplorer,
            icon: const Icon(Icons.explore),
            label: const Text('Explorer avec plusieurs agents IA'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              side: const BorderSide(color: Color(0xFF003580)),
            ),
          ),
        ),
        if (!_canProceed())
          Padding(padding: const EdgeInsets.only(top: 5, bottom: 2),
            child: Text(
              (_tracks.isEmpty && !hasPoi)
                  ? '⬆ Importez un GPX ou ajoutez des POI pour commencer'
                  : _mapSource == 'webview' ? '⬆ Choisissez une ville'
                  : '⬆ Données chargées — appuyez pour visualiser',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
            )),

        const SizedBox(height: 14),

        // ══════════════════════════════════════════════════════════════════
        // BLOC 2 : TRACÉS GPX  (séparé visuellement)
        // ══════════════════════════════════════════════════════════════════
        _buildSectionTitle(Icons.route, 'Tracés GPX',
            color: const Color(0xFF1565C0),
            badge: _tracks.isNotEmpty ? '${_tracks.length}' : null),

        Container(
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue.shade200),
          ),
          child: Column(children: [
            // Boutons d'import
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
              child: Row(children: [
                Expanded(child: _actionBtn(
                  Icons.upload_file, 'Fichiers GPX / ZIP',
                  const Color(0xFF1565C0), _isLoading ? null : _pickFiles)),
                const SizedBox(width: 8),
                Expanded(child: _actionBtn(
                  Icons.folder_open, 'Dossier',
                  const Color(0xFF1565C0), _isLoading ? null : _pickFolder)),
              ]),
            ),
            // Slider ZIP
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(children: [
                Icon(Icons.archive, size: 14, color: Colors.blue.shade400),
                const SizedBox(width: 4),
                const Text('Limite ZIP :', style: TextStyle(fontSize: 11)),
                Expanded(child: Slider(
                  value: _maxZipMb.toDouble(), min: 5, max: 200, divisions: 39,
                  label: '$_maxZipMb Mo',
                  activeColor: const Color(0xFF1565C0),
                  onChanged: (v) => setState(() => _maxZipMb = v.round()),
                )),
                Text('$_maxZipMb Mo',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
            // Liste tracés chargés
            if (_tracks.isNotEmpty) ...[
              const Divider(height: 1),
              _GpxLayerList(
                tracks: _tracks,
                folders: _gpxFolders,
                onChanged: () => setState(() { _isDirty = true; }),
              ),
            ],
          ]),
        ),

        const SizedBox(height: 14),

        // ══════════════════════════════════════════════════════════════════
        // BLOC 3 : POINTS D'INTÉRÊT  (séparé visuellement)
        // ══════════════════════════════════════════════════════════════════
        _buildSectionTitle(Icons.place, 'Points d\'intérêt',
            color: const Color(0xFF6A1B9A),
            badge: hasPoi
                ? '${_poiLayers.fold(0,(s,l)=>s+l.points.length) + _poiFolders.fold(0,(s,f)=>s+f.layers.fold(0,(ss,l)=>ss+l.points.length))}'
                : null,
            actions: [
              if (_poiLayers.any((l) => l.label.startsWith('Blog —') || l.label.startsWith('Blog -')))
                IconButton(
                  icon: const Icon(Icons.drive_file_move_outline, size: 18, color: Color(0xFF6A1B9A)),
                  tooltip: 'Ranger les couches "Blog" dans des dossiers',
                  onPressed: _migrateBlogLayersToFolders,
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
              IconButton(
                icon: const Icon(Icons.content_copy_outlined, size: 18, color: Color(0xFF6A1B9A)),
                tooltip: 'Détecter les doublons',
                onPressed: _detectAllDuplicates,
                padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),

        Container(
          decoration: BoxDecoration(
            color: Colors.purple.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.purple.shade200),
          ),
          child: Column(children: [
            // Source POI — point d'entrée unique (fusion des 4 écrans
            // auparavant dispersés : lieu / Overpass / HTML→IA / blog→IA)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
              child: Column(children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _openPoiSearchHub,
                    icon: const Icon(Icons.travel_explore),
                    label: const Text('Rechercher / importer des POI'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.purple.shade600,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: _actionBtn(
                    Icons.create_new_folder, 'Gérer dossiers',
                    Colors.amber.shade700, _openFolderManager),
                ),
              ]),
            ),
            // Liste couches POI + dossiers (LayersPanel onglet POI seulement)
            if (hasPoi) ...[
              const Divider(height: 1),
              _PoiLayerList(
                rootLayers:  _poiLayers,
                folders:     _poiFolders,
                tracks:      _tracks,
                onChanged:   () => setState(() { _isDirty = true; }),
                onPoiMenu:   _showPoiMenu,
                onExport:    (layers) => showDialog(
                  context: context,
                  builder: (_) => PoiExportDialog(layers: layers, tracks: _tracks),
                ),
              ),
            ],
          ]),
        ),

        const SizedBox(height: 14),

        // ══════════════════════════════════════════════════════════════════
        // BLOC 4 : SOURCE DE CARTE — combobox compacte
        // ══════════════════════════════════════════════════════════════════
        _buildSectionTitle(Icons.map, 'Source de la carte',
            color: Colors.grey.shade700),

        Container(
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DropdownButtonFormField<String>(
              value: _mapSource,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                _srcDropItem('gpxonly',   Icons.route,              Colors.blue,             'GPX + POI sur OSM',           'Tracés sur carte OpenStreetMap'),
                if (Platform.isAndroid || Platform.isIOS)
                  _srcDropItem('webview', Icons.web,                const Color(0xFF003580), 'Booking.com intégré',         'WebView + capture auto'),
                _srcDropItem('clipboard', Icons.content_paste,      Colors.teal,             'Presse-papiers',              'Capture copiée manuellement'),
                _srcDropItem('file',      Icons.image,              Colors.orange,           'Importer une image',          'PNG/JPG depuis la galerie'),
                _srcDropItem('capture',   Icons.screenshot_monitor, Colors.purple,           'Capturer toute application',  'Bouton flottant 📸 universel'),
              ],
              onChanged: (v) { if (v != null) setState(() => _mapSource = v); },
            ),

            // Ville + dates — visibles uniquement en mode WebView
            if (_mapSource == 'webview') ...[ 
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: TextField(
                  controller: _cityController,
                  decoration: const InputDecoration(
                    labelText: 'Ville ou région',
                    prefixIcon: Icon(Icons.location_city, size: 18),
                    border: OutlineInputBorder(), isDense: true),
                  onSubmitted: (_) => _searchCity(),
                )),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _isLoading ? null : _searchCity,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 44),
                    backgroundColor: const Color(0xFF003580),
                  ),
                  child: _isLoading
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('OK'),
                ),
              ]),
              if (_cityResults.isNotEmpty) ...[ 
                const SizedBox(height: 4),
                ..._cityResults.take(4).map((b) => RadioListTile<BoundingBox>(
                  dense: true, contentPadding: EdgeInsets.zero,
                  title: Text(b.displayName.split(',').take(2).join(', '),
                      style: const TextStyle(fontSize: 12)),
                  value: b, groupValue: _selectedBbox,
                  onChanged: (v) => setState(() => _selectedBbox = v),
                )),
              ],
              if (_selectedBbox != null) ...[ 
                const SizedBox(height: 4),
                _chip(Icons.check_circle,
                    _selectedBbox!.displayName.split(',').take(2).join(', '), Colors.green),
              ],
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: _checkInController,
                  decoration: const InputDecoration(
                    labelText: 'Arrivée', hintText: 'AAAA-MM-JJ',
                    border: OutlineInputBorder(), isDense: true,
                    prefixIcon: Icon(Icons.login, size: 18)))),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: _checkOutController,
                  decoration: const InputDecoration(
                    labelText: 'Départ', hintText: 'AAAA-MM-JJ',
                    border: OutlineInputBorder(), isDense: true,
                    prefixIcon: Icon(Icons.logout, size: 18)))),
              ]),
            ],
          ]),
        ),

                if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          _chip(Icons.error_outline, _errorMessage!, Colors.red),
        ],
        if (_captureServiceRunning)
          Padding(padding: const EdgeInsets.only(top: 8),
            child: _chip(Icons.screenshot_monitor,
                'Service capture actif — bouton 📸 visible', Colors.purple)),

        const SizedBox(height: 20),
      ]),
    );
  }

  // ── Helper titre de section ───────────────────────────────────────────────
  Widget _buildSectionTitle(IconData icon, String title,
      {Color color = Colors.grey, String? badge, List<Widget> actions = const []}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(title,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w800,
                color: color, letterSpacing: 0.5)),
        if (badge != null) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(10)),
            child: Text(badge,
                style: const TextStyle(
                    fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
        const Spacer(),
        ...actions,
      ]),
    );
  }

  // ── Helper bouton action compact ─────────────────────────────────────────
  Widget _actionBtn(IconData icon, String label, Color color, VoidCallback? onPressed) =>
    OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16, color: color),
      label: Text(label, style: TextStyle(fontSize: 11, color: color),
          overflow: TextOverflow.ellipsis, maxLines: 1),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        side: BorderSide(color: color.withOpacity(0.5)),
      ),
    );

  // ─── Étape 1 : WebView avec bouton draggable ──────────────────────────────
  Widget _buildStep1() {
    if (_webViewController == null) return const SizedBox();
    // Sécurité supplémentaire : ne jamais instancier WebViewWidget sur desktop
    if (!Platform.isAndroid && !Platform.isIOS) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.web_asset_off, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          const Text('WebView non disponible sur cette plateforme.\nUtilisez le mode Presse-papiers ou Importer une image.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 14)),
        ]),
      ));
    }
    return Stack(children: [
      RepaintBoundary(key: _repaintKey,
          child: WebViewWidget(controller: _webViewController!)),

      // Bouton capture draggable
      Positioned(
        right: _captureButtonPos.dx,
        bottom: _captureButtonPos.dy,
        child: GestureDetector(
          onPanUpdate: (d) => setState(() => _captureButtonPos = Offset(
            (_captureButtonPos.dx - d.delta.dx).clamp(0, MediaQuery.of(context).size.width - 180),
            (_captureButtonPos.dy - d.delta.dy).clamp(0, MediaQuery.of(context).size.height - 60),
          )),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(24),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.shade700,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.drag_indicator, color: Colors.white70, size: 16),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: _isLoading ? null : _captureWebView,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    _isLoading
                        ? const SizedBox(width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.screenshot, color: Colors.white, size: 18),
                    const SizedBox(width: 6),
                    const Text('Capturer', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }

  // ─── Étape 2 : Overlay ────────────────────────────────────────────────────
  Widget _buildStep2() {
    final _hasPoi = _poiLayers.isNotEmpty || _poiFolders.any((f) => f.layers.isNotEmpty);
    if (_tracks.isEmpty && !_hasPoi) return const Center(child: Text('Aucune donnee chargee'));

    // Mode GPX seul ou pas de screenshot
    if (_mapSource == 'gpxonly' || _screenshotImage == null) {
      return GpxOnlyView(
        tracks: _tracks,
        poiLayers: _poiLayers,
        poiFolders: _poiFolders,
        zoomSettings: _zoomSettings,
        onChanged: () {
          setState(() => _isDirty = true);
          _saveCurrentSession();
        },
      );
    }

    final bbox = _selectedBbox ?? _autoBbox();

    return Column(children: [
      // Barre outils
      Container(
        color: Colors.grey.shade100,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          _toolBtn(icon: _dragMode ? Icons.open_with : Icons.zoom_in,
              label: _dragMode ? 'Drag' : 'Zoom',
              color: _dragMode ? Colors.purple : Colors.blue,
              onTap: () => setState(() => _dragMode = !_dragMode)),
          const SizedBox(width: 6),
          if (_gpxOffset != Offset.zero)
            _toolBtn(icon: Icons.center_focus_strong, label: 'Reset',
                color: Colors.teal, onTap: () => setState(() => _gpxOffset = Offset.zero)),
          const Spacer(),
          // Badge calage
          if (_calibration != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: _calibration!.rmsPixels < 20
                    ? Colors.green.shade600 : Colors.orange.shade600,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '📐 ${_calibration!.points.length}pts '
                'RMS:${_calibration!.rmsPixels.toStringAsFixed(0)}px',
                style: const TextStyle(color: Colors.white, fontSize: 9,
                    fontWeight: FontWeight.bold),
              ),
            ),
          if (_calibration == null && _mapSource != 'webview') ...[
            const SizedBox(width: 4),
            _toolBtn(icon: Icons.tune, label: 'Zone', color: Colors.orange,
                onTap: _showBboxDialog),
          ],
          const SizedBox(width: 4),
          // Debug POI
          if (_poiLayers.isNotEmpty)
            _toolBtn(
              icon: _debugPoiMode ? Icons.bug_report : Icons.location_searching,
              label: _debugPoiMode ? 'Debug ON' : 'Debug',
              color: _debugPoiMode ? Colors.red : Colors.grey.shade600,
              onTap: () => setState(() => _debugPoiMode = !_debugPoiMode),
            ),
        ]),
      ),

      Expanded(child: Stack(children: [
        if (!_dragMode)
          InteractiveViewer(minScale: 0.5, maxScale: 6.0,
            child: SizedBox.expand(child: CustomPaint(
              painter: _calibration != null
                  ? CalibratedOverlayPainter(
                      tracks: _tracks, poiLayers: _poiLayers,
                      screenshotImage: _screenshotImage,
                      calibration: _calibration,
                      manualOffset: _gpxOffset,
                      showCalibPoints: _showCalibPoints)
                  : GpxOverlayPainter(tracks: _tracks, mapBbox: bbox,
                      screenshotImage: _screenshotImage, offset: _gpxOffset,
                      poiLayers: _poiLayers),
            ))),
        if (_dragMode)
          GestureDetector(
            onPanStart: (d) { _dragStart = d.globalPosition; _offsetAtDrag = _gpxOffset; },
            onPanUpdate: (d) => setState(() =>
                _gpxOffset = _offsetAtDrag + (d.globalPosition - _dragStart)),
            child: SizedBox.expand(child: CustomPaint(
              painter: _calibration != null
                  ? CalibratedOverlayPainter(
                      tracks: _tracks, poiLayers: _poiLayers,
                      screenshotImage: _screenshotImage,
                      calibration: _calibration,
                      manualOffset: _gpxOffset,
                      showCalibPoints: _showCalibPoints)
                  : GpxOverlayPainter(tracks: _tracks, mapBbox: bbox,
                      screenshotImage: _screenshotImage, offset: _gpxOffset,
                      poiLayers: _poiLayers),
            )),
          ),
        // Mode debug POI (affiche les coordonnées des POI)
        if (_debugPoiMode && _poiLayers.isNotEmpty)
          Positioned(bottom: 48, left: 8, child: Container(
            padding: const EdgeInsets.all(6),
            color: Colors.black54,
            child: Text(
              _poiLayers.expand((l) => l.points)
                  .take(5).map((p) => '${p.name}: ${p.lat.toStringAsFixed(3)},${p.lon.toStringAsFixed(3)}')
                  .join('\n'),
              style: const TextStyle(color: Colors.white, fontSize: 9),
            ),
          )),
        if (_showTrackPanel)
          Positioned(top: 8, right: 8, left: 8, child: LayersPanel(
            key: ValueKey('lp2_${_tracks.length}_${_poiLayers.length}_${_poiFolders.length}'),
            tracks: _tracks,
            poiLayers: _poiLayers,
            poiFolders: _poiFolders,
            onChanged: () => setState(() {}),
          )),
        if (_dragMode)
          Positioned(bottom: 8, left: 0, right: 0,
            child: Center(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(color: Colors.purple.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(20)),
              child: const Text('✋ Glissez pour déplacer le tracé GPX',
                  style: TextStyle(color: Colors.white, fontSize: 12)),
            ))),
      ])),

      // Légende
      Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            ..._tracks.map((t) => Padding(padding: const EdgeInsets.only(right: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 18, height: 3, color: t.color),
                const SizedBox(width: 4),
                Text(t.displayName, style: const TextStyle(fontSize: 10)),
              ]))),
            ..._poiLayers.where((l) => l.visible).map((l) => Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 10, height: 10,
                    decoration: BoxDecoration(color: l.color, shape: BoxShape.circle)),
                const SizedBox(width: 4),
                Text(l.label, style: const TextStyle(fontSize: 10)),
              ]))),
          ]),
        ),
      ),
    ]);
  }

  BoundingBox _autoBbox() {
    double minLat=90, maxLat=-90, minLon=180, maxLon=-180;
    // Inclure les tracés GPX
    for (final t in _tracks) {
      if (t.data.minLat < minLat) minLat = t.data.minLat;
      if (t.data.maxLat > maxLat) maxLat = t.data.maxLat;
      if (t.data.minLon < minLon) minLon = t.data.minLon;
      if (t.data.maxLon > maxLon) maxLon = t.data.maxLon;
    }
    // Inclure les POI de toutes les couches visibles
    for (final layer in _poiLayers) {
      if (!layer.visible) continue;
      for (final poi in layer.points) {
        if (poi.lat < minLat) minLat = poi.lat;
        if (poi.lat > maxLat) maxLat = poi.lat;
        if (poi.lon < minLon) minLon = poi.lon;
        if (poi.lon > maxLon) maxLon = poi.lon;
      }
    }
    // Fallback si aucune donnée
    if (minLat > maxLat) { minLat = 43.0; maxLat = 44.0; minLon = 1.0; maxLon = 2.0; }
    return BoundingBox(minLat: minLat-0.05, maxLat: maxLat+0.05,
        minLon: minLon-0.05, maxLon: maxLon+0.05, displayName: 'Auto');
  }

  void _showBboxDialog() {
    final latC  = TextEditingController(text: (_selectedBbox?.centerLat ?? 0).toStringAsFixed(4));
    final lonC  = TextEditingController(text: (_selectedBbox?.centerLon ?? 0).toStringAsFixed(4));
    final spanC = TextEditingController(text: '0.2');
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('Ajuster la zone'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: TextField(controller: latC,
            decoration: const InputDecoration(labelText: 'Lat', border: OutlineInputBorder()),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: lonC,
            decoration: const InputDecoration(labelText: 'Lon', border: OutlineInputBorder()),
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true))),
        ]),
        const SizedBox(height: 8),
        TextField(controller: spanC,
          decoration: const InputDecoration(labelText: 'Étendue (°)', hintText: '0.2 ≈ 20 km',
              border: OutlineInputBorder()),
          keyboardType: const TextInputType.numberWithOptions(decimal: true)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
        FilledButton(onPressed: () {
          final lat  = double.tryParse(latC.text)  ?? 0;
          final lon  = double.tryParse(lonC.text)  ?? 0;
          final span = double.tryParse(spanC.text) ?? 0.2;
          Navigator.pop(context);
          setState(() => _selectedBbox = BoundingBox(
            minLat: lat-span/2, maxLat: lat+span/2,
            minLon: lon-span/2, maxLon: lon+span/2,
            displayName: 'Zone personnalisée',
          ));
        }, child: const Text('Appliquer')),
      ],
    ));
  }

  // ─── Helpers UI ────────────────────────────────────────────────────────────
  Widget _srcOption(String value, IconData icon, Color color, String title, String subtitle) {
    return RadioListTile<String>(
      dense: true, value: value, groupValue: _mapSource,
      onChanged: (v) => setState(() => _mapSource = v!),
      title: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
      secondary: Icon(icon, color: color, size: 22),
    );
  }

  DropdownMenuItem<String> _srcDropItem(
      String value, IconData icon, Color color, String title, String subtitle) {
    return DropdownMenuItem<String>(
      value: value,
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            Text(subtitle,
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ]),
    );
  }

  Widget _sectionHeader(String num, String title) {
    return Padding(padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Container(width: 24, height: 24,
          decoration: const BoxDecoration(color: Color(0xFF003580), shape: BoxShape.circle),
          child: Center(child: Text(num, style: const TextStyle(color: Colors.white,
              fontSize: 12, fontWeight: FontWeight.bold)))),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ]));
  }

  Widget _chip(IconData icon, String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.3))),
      child: Row(children: [
        Icon(icon, color: color, size: 16), const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 12,
            fontWeight: FontWeight.w500))),
      ]),
    );
  }

  Widget _toolBtn({required IconData icon, required String label,
      required Color color, required VoidCallback onTap}) {
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withOpacity(0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color), const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
        ]),
      ));
  }

  IconData _modeIcon() { switch (_mapSource) { case 'clipboard': return Icons.content_paste; case 'file': return Icons.image; case 'capture': return Icons.screenshot_monitor; case 'gpxonly': return Icons.route; default: return Icons.map; } }
  String   _modeLabel() { switch (_mapSource) { case 'clipboard': return 'Coller la carte'; case 'file': return 'Importer la carte'; case 'capture': return _captureServiceRunning ? 'Service actif' : 'Activer la capture'; case 'gpxonly': return 'Visualiser sur OSM'; default: return 'Ouvrir Booking.com'; } }
  Color    _modeColor() { switch (_mapSource) { case 'clipboard': return Colors.teal; case 'file': return Colors.orange; case 'capture': return Colors.purple; case 'gpxonly': return Colors.blue; default: return const Color(0xFF003580); } }
}

// ═════════════════════════════════════════════════════════════════════════════
// _SessionBanner — bandeau session active
// ═════════════════════════════════════════════════════════════════════════════
class _SessionBanner extends StatelessWidget {
  final VisuSession? session;
  final bool         isDirty;
  final VoidCallback onOpen;
  final VoidCallback onNew;
  final VoidCallback onSave;
  final VoidCallback onBackup;
  final VoidCallback onExport;

  const _SessionBanner({
    required this.session, required this.isDirty,
    required this.onOpen,  required this.onNew,
    required this.onSave,  required this.onBackup,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final label = session?.label ?? 'Nouvelle session';
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF003580), Color(0xFF0051B2)],
          begin: Alignment.topLeft, end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.blue.shade900.withOpacity(0.3),
            blurRadius: 8, offset: const Offset(0, 3))],
      ),
      child: Column(children: [
        // Ligne principale session
        InkWell(
          onTap: onOpen,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(children: [
              const Icon(Icons.bookmarks, color: Colors.white70, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('SESSION ACTIVE',
                    style: TextStyle(color: Colors.white38, fontSize: 9,
                        fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                const SizedBox(height: 2),
                Row(children: [
                  Expanded(child: Text(label,
                      style: const TextStyle(color: Colors.white,
                          fontWeight: FontWeight.bold, fontSize: 15),
                      overflow: TextOverflow.ellipsis)),
                  if (isDirty)
                    Container(
                      margin: const EdgeInsets.only(left: 6),
                      width: 7, height: 7,
                      decoration: const BoxDecoration(
                          color: Colors.amber, shape: BoxShape.circle),
                    ),
                ]),
              ])),
              const Icon(Icons.keyboard_arrow_right, color: Colors.white38, size: 20),
            ]),
          ),
        ),

        // Ligne actions
        Container(
          decoration: const BoxDecoration(
            color: Color(0x22000000),
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
          ),
          child: Row(children: [
            _bannerBtn(Icons.add_circle_outline, 'Nouvelle', onNew),
            _divider(),
            _bannerBtn(isDirty ? Icons.save : Icons.save_outlined,
                isDirty ? 'Sauver ●' : 'Sauver', onSave,
                highlight: isDirty),
            _divider(),
            _bannerBtn(Icons.backup_outlined, 'Backup', onBackup),
            _divider(),
            _bannerBtn(Icons.map_outlined, 'Road-book', onExport),
          ]),
        ),
      ]),
    );
  }

  Widget _bannerBtn(IconData icon, String label, VoidCallback onTap,
      {bool highlight = false}) =>
    Expanded(child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 18,
              color: highlight ? Colors.amber : Colors.white70),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 9, color: highlight ? Colors.amber : Colors.white54,
                  fontWeight: highlight ? FontWeight.bold : FontWeight.normal),
              overflow: TextOverflow.ellipsis),
        ]),
      ),
    ));

  Widget _divider() => Container(
      width: 1, height: 32,
      color: Colors.white.withOpacity(0.1));
}

// ═════════════════════════════════════════════════════════════════════════════
// _GpxLayerList — liste des tracés chargés dans le bloc GPX
// ═════════════════════════════════════════════════════════════════════════════
class _GpxLayerList extends StatefulWidget {
  final List<GpxTrack>  tracks;
  final List<GpxFolder> folders;
  final VoidCallback    onChanged;
  const _GpxLayerList({
    required this.tracks, required this.folders, required this.onChanged,
  });
  @override State<_GpxLayerList> createState() => _GpxLayerListState();
}

class _GpxLayerListState extends State<_GpxLayerList> {
  /// Traces non rangées dans un dossier
  List<GpxTrack> get _unfiledTracks {
    final filed = widget.folders.expand((f) => f.trackFileNames).toSet();
    return widget.tracks.where((t) => !filed.contains(t.fileName)).toList();
  }

  Future<void> _newFolder() async {
    final ctrl = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nouveau dossier GPX'),
        content: TextField(controller: ctrl, autofocus: true,
            decoration: const InputDecoration(hintText: 'Ex : Road trip Pyrénées')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Créer')),
        ],
      ),
    );
    if (label == null || label.isEmpty) return;
    setState(() => widget.folders.add(GpxFolder(label: label)));
    widget.onChanged();
  }

  Future<void> _moveTrack(GpxTrack t, GpxFolder? destination) async {
    setState(() {
      for (final f in widget.folders) {
        f.trackFileNames.remove(t.fileName);
      }
      if (destination != null) destination.trackFileNames.add(t.fileName);
    });
    widget.onChanged();
  }

  void _deleteFolder(GpxFolder f) {
    setState(() => widget.folders.remove(f));
    widget.onChanged();
  }

  void _deleteTrack(GpxTrack t) {
    for (final f in widget.folders) {
      f.trackFileNames.remove(t.fileName);
    }
    widget.tracks.remove(t);
    widget.onChanged();
    setState(() {});
  }

  Widget _trackTile(BuildContext ctx, GpxTrack t, {bool indented = false}) {
    return Opacity(
      opacity: t.visible ? 1.0 : 0.45,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: indented ? 28 : 12, right: 4),
        leading: Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: t.color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: t.color, width: 2),
          ),
          child: Icon(Icons.route, size: 16, color: t.color),
        ),
        title: Text(t.displayName,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis),
        subtitle: Text(
            '${t.data.trackPoints.length} pts'
            '${t.data.waypoints.isNotEmpty ? " • ${t.data.waypoints.length} wpts" : ""}',
            style: const TextStyle(fontSize: 10)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            icon: const Icon(Icons.download, size: 16, color: Color(0xFF1565C0)),
            tooltip: 'Exporter ce tracé',
            onPressed: () => showDialog(
              context: ctx,
              builder: (_) => PoiExportDialog(layers: const [], tracks: [t]),
            ),
            padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          IconButton(
            icon: Icon(
                t.visible ? Icons.visibility : Icons.visibility_off,
                size: 16,
                color: t.visible ? const Color(0xFF1565C0) : Colors.grey),
            onPressed: () { t.visible = !t.visible; widget.onChanged(); setState(() {}); },
            padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          PopupMenuButton<GpxFolder?>(
            icon: const Icon(Icons.folder_outlined, size: 16, color: Colors.grey),
            tooltip: 'Déplacer vers un dossier',
            onSelected: (dest) => _moveTrack(t, dest),
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('📤 Racine (aucun dossier)')),
              for (final f in widget.folders)
                PopupMenuItem(value: f, child: Text('📁 ${f.label}')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 14, color: Colors.red),
            onPressed: () async {
              final ok = await showDialog<bool>(context: ctx,
                builder: (_) => AlertDialog(
                  title: const Text('Supprimer le tracé ?'),
                  content: Text('« ${t.displayName} » sera retiré.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Annuler')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Supprimer')),
                  ],
                ));
              if (ok == true) _deleteTrack(t);
            },
            padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          const SizedBox(width: 4),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unfiled = _unfiledTracks;
    return Column(children: [
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _newFolder,
          icon: const Icon(Icons.create_new_folder_outlined, size: 16),
          label: const Text('Nouveau dossier', style: TextStyle(fontSize: 11)),
        ),
      ),
      for (final folder in widget.folders)
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: folder.expanded,
            onExpansionChanged: (v) { folder.expanded = v; widget.onChanged(); },
            leading: const Icon(Icons.folder, size: 18, color: Color(0xFF1565C0)),
            title: Text(folder.label,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            subtitle: Text(
                '${folder.trackFileNames.length} tracé(s)',
                style: const TextStyle(fontSize: 10)),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
              tooltip: 'Supprimer le dossier (les tracés reviennent à la racine)',
              onPressed: () => _deleteFolder(folder),
            ),
            children: [
              for (final fileName in folder.trackFileNames)
                if (widget.tracks.where((t) => t.fileName == fileName).isNotEmpty)
                  _trackTile(context,
                      widget.tracks.firstWhere((t) => t.fileName == fileName),
                      indented: true),
            ],
          ),
        ),
      ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: unfiled.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 44),
        itemBuilder: (ctx, i) => _trackTile(ctx, unfiled[i]),
      ),
    ]);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// _PoiLayerList — explorateur de dossiers/couches POI avec drag & drop
// ═════════════════════════════════════════════════════════════════════════════
//
// Modèle d'identité unifié pour le drag & drop : chaque élément déplaçable
// (dossier ou couche racine ou couche-dans-dossier) porte un _DragItem qui
// encode sa nature et sa position d'origine, permettant de calculer la
// destination lors du drop sans ambiguïté.

enum _DragKind { folder, rootLayer, layerInFolder }

class _DragItem {
  final _DragKind kind;
  final PoiFolder? folder;       // dossier déplacé (kind == folder)
  final PoiLayer?  layer;        // couche déplacée (kind == rootLayer | layerInFolder)
  final PoiFolder? sourceFolder; // dossier d'origine si kind == layerInFolder
  const _DragItem({required this.kind, this.folder, this.layer, this.sourceFolder});
}

class _PoiLayerList extends StatefulWidget {
  final List<PoiLayer>  rootLayers;
  final List<PoiFolder> folders;
  final List<GpxTrack>  tracks;
  final VoidCallback    onChanged;
  final void Function(BuildContext, PoiLayer, PoiPoint) onPoiMenu;
  final void Function(List<PoiLayer>) onExport;

  const _PoiLayerList({
    required this.rootLayers, required this.folders, required this.tracks,
    required this.onChanged,  required this.onPoiMenu, required this.onExport,
  });

  @override State<_PoiLayerList> createState() => _PoiLayerListState();
}

class _PoiLayerListState extends State<_PoiLayerList> {

  void _refresh() { widget.onChanged(); setState(() {}); }

  // ── Déplacements ────────────────────────────────────────────────────────────

  /// Réordonne les dossiers entre eux (drag dossier sur dossier)
  void _reorderFolder(PoiFolder moved, PoiFolder target) {
    final list = widget.folders;
    final from = list.indexOf(moved);
    final to   = list.indexOf(target);
    if (from < 0 || to < 0 || from == to) return;
    list.removeAt(from);
    list.insert(to, moved);
    _refresh();
  }

  /// Réordonne les couches racine entre elles
  void _reorderRootLayer(PoiLayer moved, PoiLayer target) {
    final list = widget.rootLayers;
    final from = list.indexOf(moved);
    final to   = list.indexOf(target);
    if (from < 0 || to < 0 || from == to) return;
    list.removeAt(from);
    list.insert(to, moved);
    _refresh();
  }

  /// Range une couche racine dans un dossier
  void _moveRootLayerToFolder(PoiLayer layer, PoiFolder folder) {
    widget.rootLayers.remove(layer);
    folder.layers.add(layer);
    folder.expanded = true;
    _refresh();
  }

  /// Sort une couche d'un dossier vers la racine
  /// Dialog pour déplacer une couche racine dans un dossier existant ou nouveau
  Future<void> _showMoveToFolderDialog(PoiLayer layer) async {
    final newFolderCtrl = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (_) => StatefulBuilder(builder: (ctx, setD) {
        return AlertDialog(
          title: const Text('Déplacer vers un dossier'),
          content: SizedBox(width: 340, child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (widget.folders.isNotEmpty) ...[
              const Align(alignment: Alignment.centerLeft,
                child: Text('Dossiers existants :',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
              const SizedBox(height: 6),
              ...widget.folders.map((f) => ListTile(
                dense: true,
                leading: const Icon(Icons.folder, size: 18, color: Color(0xFF6A1B9A)),
                title: Text(f.label, style: const TextStyle(fontSize: 13)),
                subtitle: Text('${f.layers.fold(0, (s, l) => s + l.points.length)} POI',
                    style: const TextStyle(fontSize: 10)),
                trailing: const Icon(Icons.arrow_forward, size: 16),
                onTap: () => Navigator.pop(ctx, f.label),
              )),
              const Divider(),
            ],
            const Align(alignment: Alignment.centerLeft,
              child: Text('Nouveau dossier :',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
            const SizedBox(height: 6),
            TextField(
              controller: newFolderCtrl, autofocus: widget.folders.isEmpty,
              decoration: const InputDecoration(
                hintText: 'Nom du nouveau dossier',
                prefixIcon: Icon(Icons.create_new_folder_outlined, size: 18),
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
              onSubmitted: (v) { if (v.trim().isNotEmpty) Navigator.pop(ctx, v.trim()); },
            ),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuler')),
            FilledButton.icon(
              onPressed: () {
                final name = newFolderCtrl.text.trim();
                if (name.isNotEmpty) Navigator.pop(ctx, name);
              },
              icon: const Icon(Icons.drive_file_move_outline, size: 16),
              label: const Text('Déplacer'),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6A1B9A)),
            ),
          ],
        );
      }),
    );

    if (result == null || result.isEmpty) return;

    // Chercher ou créer le dossier cible
    PoiFolder? target;
    for (final f in widget.folders) {
      if (f.label.trim().toLowerCase() == result.toLowerCase()) {
        target = f; break;
      }
    }
    if (target == null) {
      target = PoiFolder(label: result, layers: []);
      widget.folders.add(target);
    }

    widget.rootLayers.remove(layer);
    target.layers.add(layer);
    _refresh();

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('📁 « ${layer.label} » déplacé dans « $result »'),
      backgroundColor: Colors.green,
      duration: const Duration(seconds: 2)));
  }

  void _moveLayerToRoot(PoiLayer layer, PoiFolder from) {
    from.layers.remove(layer);
    widget.rootLayers.add(layer);
    _refresh();
  }

  /// Déplace une couche d'un dossier vers un autre dossier
  void _moveLayerToOtherFolder(PoiLayer layer, PoiFolder from, PoiFolder to) {
    if (from == to) return;
    from.layers.remove(layer);
    to.layers.add(layer);
    to.expanded = true;
    _refresh();
  }

  /// Réordonne deux couches à l'intérieur du même dossier
  void _reorderLayerInFolder(PoiLayer moved, PoiLayer target, PoiFolder folder) {
    final from = folder.layers.indexOf(moved);
    final to   = folder.layers.indexOf(target);
    if (from < 0 || to < 0 || from == to) return;
    folder.layers.removeAt(from);
    folder.layers.insert(to, moved);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [

      // ── Dossiers (réordonnables entre eux, cibles de drop pour les couches) ──
      ...widget.folders.map((f) => DragTarget<_DragItem>(
        onWillAcceptWithDetails: (details) {
          final item = details.data;
          // Un dossier ne s'accepte pas lui-même ; une couche peut toujours
          // être déposée sur un dossier (y compris le sien, ignoré au drop)
          if (item.kind == _DragKind.folder) return item.folder != f;
          return true;
        },
        onAcceptWithDetails: (details) {
          final item = details.data;
          if (item.kind == _DragKind.folder && item.folder != null) {
            _reorderFolder(item.folder!, f);
          } else if (item.kind == _DragKind.rootLayer && item.layer != null) {
            _moveRootLayerToFolder(item.layer!, f);
          } else if (item.kind == _DragKind.layerInFolder &&
                     item.layer != null && item.sourceFolder != null) {
            _moveLayerToOtherFolder(item.layer!, item.sourceFolder!, f);
          }
        },
        builder: (ctx, candidates, rejected) => Draggable<_DragItem>(
          data: _DragItem(kind: _DragKind.folder, folder: f),
          feedback: Material(
            elevation: 4, borderRadius: BorderRadius.circular(6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              width: 220,
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.amber)),
              child: Row(children: [
                Icon(Icons.folder, color: Colors.amber.shade700, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(f.label,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    overflow: TextOverflow.ellipsis)),
              ]),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.3, child: _FolderTile(
            folder: f, tracks: widget.tracks,
            onChanged: _refresh, onPoiMenu: widget.onPoiMenu, onExport: widget.onExport,
            onDelete: () {}, onMoveOut: (_) {}, onReorderInside: (_,__) {},
          )),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              color: candidates.isNotEmpty ? Colors.amber.withOpacity(.15) : null,
              border: candidates.isNotEmpty
                  ? Border.all(color: Colors.amber, width: 1.5)
                  : null,
            ),
            child: _FolderTile(
              folder: f, tracks: widget.tracks,
              onChanged: _refresh,
              onPoiMenu: widget.onPoiMenu,
              onExport:  widget.onExport,
              onDelete:  () async {
                final ok = await showDialog<bool>(context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Supprimer le dossier ?'),
                    content: Text('« ${f.label} » (${f.layers.length} couche(s)) sera supprimé.\nLes couches seront conservées hors dossier.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                      FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red),
                          onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
                    ],
                  ));
                if (ok == true) {
                  widget.rootLayers.addAll(f.layers);
                  widget.folders.remove(f);
                  _refresh();
                }
              },
              onMoveOut: (l) => _moveLayerToRoot(l, f),
              onReorderInside: (moved, target) => _reorderLayerInFolder(moved, target, f),
            ),
          ),
        ),
      )),

      // ── Zone racine — cible de drop pour sortir une couche d'un dossier ──────
      DragTarget<_DragItem>(
        onWillAcceptWithDetails: (details) =>
            details.data.kind == _DragKind.layerInFolder,
        onAcceptWithDetails: (details) {
          final item = details.data;
          if (item.layer != null && item.sourceFolder != null) {
            _moveLayerToRoot(item.layer!, item.sourceFolder!);
          }
        },
        builder: (ctx, candidates, rejected) => Container(
          decoration: BoxDecoration(
            color: candidates.isNotEmpty ? Colors.blue.withOpacity(.06) : null,
            border: candidates.isNotEmpty
                ? Border.all(color: Colors.blue.withOpacity(.4), width: 1.5)
                : null,
          ),
          padding: candidates.isNotEmpty ? const EdgeInsets.all(4) : EdgeInsets.zero,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (candidates.isNotEmpty && widget.rootLayers.isEmpty)
              const Padding(padding: EdgeInsets.all(8),
                child: Text('Déposer ici pour sortir du dossier',
                    style: TextStyle(fontSize: 11, color: Colors.blue))),

            // Couches racine (réordonnables entre elles, cibles de drop)
            ...widget.rootLayers.map((l) => DragTarget<_DragItem>(
              onWillAcceptWithDetails: (details) {
                final item = details.data;
                if (item.kind == _DragKind.rootLayer) return item.layer != l;
                return item.kind == _DragKind.layerInFolder;
              },
              onAcceptWithDetails: (details) {
                final item = details.data;
                if (item.kind == _DragKind.rootLayer && item.layer != null) {
                  _reorderRootLayer(item.layer!, l);
                } else if (item.kind == _DragKind.layerInFolder &&
                           item.layer != null && item.sourceFolder != null) {
                  _moveLayerToRoot(item.layer!, item.sourceFolder!);
                  // Réordonner ensuite à la position visée
                  final idx = widget.rootLayers.indexOf(l);
                  widget.rootLayers.remove(item.layer!);
                  widget.rootLayers.insert(idx, item.layer!);
                  _refresh();
                }
              },
              builder: (ctx2, cand2, rej2) => Draggable<_DragItem>(
                data: _DragItem(kind: _DragKind.rootLayer, layer: l),
                feedback: _dragFeedback(l),
                childWhenDragging: Opacity(opacity: 0.3,
                  child: _PoiLayerTile(
                    layer: l, onChanged: _refresh, onPoiMenu: widget.onPoiMenu,
                    onExport: () => widget.onExport([l]), onDelete: () {},
                  )),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  decoration: BoxDecoration(
                    color: cand2.isNotEmpty ? Colors.blue.withOpacity(.1) : null,
                  ),
                  child: _PoiLayerTile(
                    layer:     l,
                    onChanged: _refresh,
                    onPoiMenu: widget.onPoiMenu,
                    onExport:  () => widget.onExport([l]),
                    onMoveTo:  () => _showMoveToFolderDialog(l),
                    onDelete:  () async {
                      final ok = await showDialog<bool>(context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Supprimer la couche ?'),
                          content: Text('« ${l.label} » (${l.points.length} POI) sera supprimée.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                            FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
                          ],
                        ));
                      if (ok == true) { widget.rootLayers.remove(l); _refresh(); }
                    },
                  ),
                ),
              ),
            )),
          ]),
        ),
      ),
    ]);
  }

  Widget _dragFeedback(PoiLayer l) => Material(
    elevation: 4, borderRadius: BorderRadius.circular(6),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      width: 220,
      decoration: BoxDecoration(
        color: (l.color ?? Colors.teal).withOpacity(.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: l.color ?? Colors.teal)),
      child: Row(children: [
        Icon(Icons.layers, color: l.color ?? Colors.teal, size: 18),
        const SizedBox(width: 6),
        Expanded(child: Text(l.label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            overflow: TextOverflow.ellipsis)),
      ]),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
class _FolderTile extends StatefulWidget {
  final PoiFolder    folder;
  final List<GpxTrack> tracks;
  final VoidCallback onChanged;
  final void Function(BuildContext, PoiLayer, PoiPoint) onPoiMenu;
  final void Function(List<PoiLayer>) onExport;
  final VoidCallback onDelete;
  final void Function(PoiLayer) onMoveOut;
  final void Function(PoiLayer, PoiLayer) onReorderInside;
  const _FolderTile({required this.folder, required this.tracks,
      required this.onChanged, required this.onPoiMenu,
      required this.onExport,  required this.onDelete,
      required this.onMoveOut, required this.onReorderInside});
  @override State<_FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends State<_FolderTile> {
  @override
  Widget build(BuildContext context) {
    final f = widget.folder;
    final total = f.layers.fold<int>(0, (s, l) => s + l.points.length);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      // En-tête dossier
      Container(
        color: Colors.amber.withOpacity(0.08),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 12, right: 4),
          leading: GestureDetector(
            onTap: () { f.expanded = !f.expanded; widget.onChanged(); setState(() {}); },
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.drag_indicator, size: 16, color: Colors.grey),
              Icon(f.expanded ? Icons.folder_open : Icons.folder,
                  color: Colors.amber.shade700, size: 22),
            ]),
          ),
          title: GestureDetector(
            onTap: () { f.expanded = !f.expanded; widget.onChanged(); setState(() {}); },
            child: Text(f.label,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          subtitle: Text('${f.layers.length} couche(s) · $total POI',
              style: const TextStyle(fontSize: 10)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: Icon(f.expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: Colors.amber.shade700),
              onPressed: () { f.expanded = !f.expanded; widget.onChanged(); setState(() {}); },
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            IconButton(
              icon: Icon(f.visible ? Icons.visibility : Icons.visibility_off,
                  size: 16, color: f.visible ? Colors.blue : Colors.grey),
              onPressed: () {
                f.visible = !f.visible;
                for (final l in f.layers) l.visible = f.visible;
                widget.onChanged(); setState(() {});
              },
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            IconButton(
              icon: const Icon(Icons.close, size: 14, color: Colors.red),
              onPressed: widget.onDelete,
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            const SizedBox(width: 4),
          ]),
        ),
      ),
      // Couches du dossier (si déployé) — réordonnables + glissables hors dossier
      if (f.expanded)
        ...f.layers.map((l) => Padding(
          padding: const EdgeInsets.only(left: 16),
          child: DragTarget<_DragItem>(
            onWillAcceptWithDetails: (details) {
              final item = details.data;
              if (item.kind == _DragKind.layerInFolder) {
                return item.sourceFolder == f && item.layer != l;
              }
              return item.kind == _DragKind.rootLayer;
            },
            onAcceptWithDetails: (details) {
              final item = details.data;
              if (item.kind == _DragKind.layerInFolder &&
                  item.layer != null && item.sourceFolder == f) {
                widget.onReorderInside(item.layer!, l);
              } else if (item.kind == _DragKind.rootLayer && item.layer != null) {
                // Couche racine déposée sur une couche du dossier → entre dans le dossier
                f.layers.remove(item.layer);
                final idx = f.layers.indexOf(l);
                f.layers.insert(idx < 0 ? f.layers.length : idx, item.layer!);
                widget.onChanged();
              }
            },
            builder: (ctx, candidates, rejected) => Draggable<_DragItem>(
              data: _DragItem(kind: _DragKind.layerInFolder, layer: l, sourceFolder: f),
              feedback: Material(
                elevation: 4, borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  width: 200,
                  decoration: BoxDecoration(
                    color: (l.color ?? Colors.teal).withOpacity(.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: l.color ?? Colors.teal)),
                  child: Row(children: [
                    Icon(Icons.layers, color: l.color ?? Colors.teal, size: 16),
                    const SizedBox(width: 6),
                    Expanded(child: Text(l.label,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                        overflow: TextOverflow.ellipsis)),
                  ]),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.3, child: _PoiLayerTile(
                layer: l, onChanged: widget.onChanged, onPoiMenu: widget.onPoiMenu,
                onExport: () => widget.onExport([l]), onDelete: () {},
              )),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  color: candidates.isNotEmpty ? Colors.amber.withOpacity(.12) : null,
                ),
                child: _PoiLayerTile(
                  layer:     l,
                  onChanged: widget.onChanged,
                  onPoiMenu: widget.onPoiMenu,
                  onExport:  () => widget.onExport([l]),
                  onDelete:  () async {
                    final ok = await showDialog<bool>(context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Supprimer la couche ?'),
                        content: Text('« ${l.label} » (${l.points.length} POI) sera supprimée du dossier « ${f.label} ».'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red),
                              onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
                        ],
                      ));
                    if (ok == true) { f.layers.remove(l); widget.onChanged(); setState(() {}); }
                  },
                ),
              ),
            ),
          ),
        )),
      const Divider(height: 1),
    ]);
  }
}

class _PoiLayerTile extends StatefulWidget {
  final PoiLayer     layer;
  final VoidCallback onChanged;
  final void Function(BuildContext, PoiLayer, PoiPoint) onPoiMenu;
  final VoidCallback onExport;
  final VoidCallback onDelete;
  final VoidCallback? onMoveTo;
  const _PoiLayerTile({required this.layer, required this.onChanged,
      required this.onPoiMenu, required this.onExport, required this.onDelete,
      this.onMoveTo});
  @override State<_PoiLayerTile> createState() => _PoiLayerTileState();
}

class _PoiLayerTileState extends State<_PoiLayerTile> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final l = widget.layer;
    return Opacity(
      opacity: l.visible ? 1.0 : 0.5,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 12, right: 4),
          leading: GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: l.color.withOpacity(0.15),
                shape: BoxShape.circle,
                border: Border.all(color: l.color, width: 2),
              ),
              child: Center(child: Text('${l.points.length}',
                  style: TextStyle(fontSize: 9, color: l.color, fontWeight: FontWeight.bold))),
            ),
          ),
          title: GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text(l.label,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ),
          subtitle: Text('${l.points.length} POI',
              style: const TextStyle(fontSize: 10)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (l.points.isNotEmpty)
              IconButton(
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: Colors.grey),
                onPressed: () => setState(() => _expanded = !_expanded),
                padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            IconButton(
              icon: Icon(l.visible ? Icons.visibility : Icons.visibility_off,
                  size: 16, color: l.visible ? Colors.blue : Colors.grey),
              onPressed: () { l.visible = !l.visible; widget.onChanged(); setState(() {}); },
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            if (widget.onMoveTo != null)
              IconButton(
                icon: const Icon(Icons.drive_file_move_outline, size: 16,
                    color: Color(0xFF6A1B9A)),
                tooltip: 'Déplacer vers un dossier',
                onPressed: widget.onMoveTo,
                padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            IconButton(
              icon: const Icon(Icons.download, size: 16, color: Color(0xFF003580)),
              tooltip: 'Exporter', onPressed: widget.onExport,
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            IconButton(
              icon: const Icon(Icons.close, size: 14, color: Colors.red),
              onPressed: widget.onDelete,
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            const SizedBox(width: 4),
          ]),
        ),
        if (_expanded)
          ...l.points.map((poi) => ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.only(left: 28, right: 4),
            leading: Text(_poiEmoji(poi.type),
                style: const TextStyle(fontSize: 16)),
            title: Text(poi.name,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
            subtitle: poi.description?.isNotEmpty == true
                ? Text(poi.description!,
                    style: const TextStyle(fontSize: 9, color: Colors.grey),
                    maxLines: 1, overflow: TextOverflow.ellipsis)
                : null,
            trailing: IconButton(
              icon: const Icon(Icons.more_vert, size: 16, color: Colors.grey),
              onPressed: () => widget.onPoiMenu(context, l, poi),
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          )),
        const Divider(height: 1, indent: 12),
      ]),
    );
  }

  String _poiEmoji(String? type) {
    const map = {
      'hotel':'🏨','restaurant':'🍽️','monument':'🏛️','peak':'⛰️',
      'waterfall':'💧','castle':'🏰','museum':'🖼️','village':'🏘️',
      'city':'🏙️','chapel':'⛪','parking':'🅿️','fuel':'⛽',
      'lake':'🌊','forest':'🌲','viewpoint':'🔭','camping':'⛺',
      'attraction':'🎡','ruins':'🏚️','cafe':'☕','cave':'🕳️',
    };
    return map[type] ?? '📍';
  }
}
