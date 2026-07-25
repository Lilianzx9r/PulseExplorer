import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'core/services/vector_map_layer.dart';
import 'package:latlong2/latlong.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'blog_poi_service.dart';
import 'html_poi_extractor.dart';
import 'poi_ai_common.dart';
import 'gpx_track.dart';
import 'poi_edit_dialog.dart';
import 'core/services/poi_import_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Écran principal — saisie texte + pipeline analyse
// ─────────────────────────────────────────────────────────────────────────────
class BlogPoiScreen extends StatefulWidget {
  final List<PoiLayer>  rootLayers;
  final List<PoiFolder> folders;
  final List<GpxTrack>  tracks;
  final VoidCallback    onImported;

  const BlogPoiScreen({
    super.key,
    required this.rootLayers,
    required this.folders,
    required this.tracks,
    required this.onImported,
  });

  @override
  State<BlogPoiScreen> createState() => _BlogPoiScreenState();
}

class _BlogPoiScreenState extends State<BlogPoiScreen>
    with SingleTickerProviderStateMixin {

  late final TabController _tabs;
  final _textCtrl = TextEditingController(
      text: HtmlPoiExtractor.lastInputText);

  bool   _analyzing = false;
  bool   _resolving = false;
  bool   _fetching  = false;
  String _status    = '';
  int    _progressDone  = 0;
  int    _progressTotal = 0;
  String? _error;

  List<BlogPoi> _pois = [];
  int _replacedCount = 0;   // POI existants remplacés via fusion

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  // ── Pipeline ───────────────────────────────────────────────────────────────
  // ── Import JSON structuré ──────────────────────────────────────────────────
  Future<void> _importJson() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom, allowedExtensions: ['json'], withData: true);
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    String content;
    try {
      content = f.bytes != null
          ? String.fromCharCodes(f.bytes!)
          : await File(f.path!).readAsString();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur lecture : $e'),
              backgroundColor: Colors.red));
      return;
    }
    setState(() {
      _analyzing = false; _resolving = false; _fetching = false;
      _error = null; _pois = []; _status = '📂 Analyse du fichier JSON...';
    });
    try {
      final pois = BlogPoiService.parseStructuredJson(content);
      if (pois.isEmpty) {
        setState(() => _error = 'Aucun POI trouvé dans le fichier JSON');
        return;
      }
      final withoutCoords = pois.where((p) => !p.hasCoords).length;
      if (withoutCoords > 0) {
        setState(() {
          _pois = pois; _resolving = true;
          _status = '🗺️ Résolution de $withoutCoords coordonnées...';
          _progressDone = 0; _progressTotal = withoutCoords;
        });
        await BlogPoiService.resolveCoords(pois, onProgress: (d, t) {
          if (mounted) setState(() { _progressDone = d; _progressTotal = t; });
        });
      }
      setState(() { _resolving = false; _fetching = true; _status = '🖼️ Recherche images...'; });
      await BlogPoiService.fetchImages(
        pois.where((p) => p.hasCoords && p.imageUrl == null).toList(),
        onProgress: (d, t) {
          if (mounted) setState(() { _progressDone = d; _progressTotal = t; });
        },
      );
      final existing = [
        ...widget.rootLayers.expand((l) => l.points),
        ...widget.folders.expand((f) => f.layers.expand((l) => l.points)),
      ];
      BlogPoiService.checkDuplicates(pois, existing);
      final dupCount = pois.where((p) => p.isDuplicate).length;
      setState(() {
        _pois = pois; _fetching = false;
        _status = '✅ ${pois.where((p) => p.hasCoords).length}/${pois.length} POI'
            '${dupCount > 0 ? " · ⚠️ $dupCount doublon(s)" : ""}'
            ' — sélectionnez et importez';
      });
      _tabs.animateTo(1);
    } catch (e) {
      setState(() { _fetching = false; _resolving = false; _error = e.toString(); });
    }
  }

  /// Copie le prompt commun + le texte saisi, pour utilisation avec un agent
  /// IA externe (ChatGPT, Claude, Gemini...). Le JSON obtenu se réimporte via
  /// le bouton "Importer un JSON structuré" ci-dessous.
  Future<void> _copyPromptForExternalAi() async {
    final text = _textCtrl.text.trim();
    final body = text.isEmpty ? '(coller votre texte ici)' : text;
    final fullPrompt = '$kCommonPoiPrompt$body';
    await Clipboard.setData(ClipboardData(text: fullPrompt));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text(
          '📋 Prompt copié ! Collez-le dans ChatGPT/Claude/Gemini, récupérez le '
          'JSON, puis utilisez "Importer un JSON structuré" ci-dessous.'),
      duration: Duration(seconds: 5),
    ));
  }

  Future<void> _analyze() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    if (!HtmlPoiExtractor.hasApiKey) {
      setState(() => _error = 'Clé API OpenRouter requise dans Extraction POI');
      return;
    }

    setState(() {
      _analyzing = true; _resolving = false; _fetching = false;
      _error = null; _pois = []; _status = '🤖 Analyse IA en cours…';
    });

    try {
      // Mémoriser le texte
      HtmlPoiExtractor.lastInputText = text;

      // Étape 1 : analyse IA
      final pois = await BlogPoiService.analyzeText(text);
      if (!mounted) return;
      setState(() {
        _pois = pois;
        _status = '📍 ${pois.length} lieux extraits — résolution coordonnées…';
        _analyzing = false; _resolving = true;
        _progressDone = 0; _progressTotal = pois.where((p) => !p.hasCoords).length;
      });

      // Étape 2 : résolution coordonnées Nominatim + IA
      await BlogPoiService.resolveCoords(pois, onProgress: (done, total) {
        if (mounted) setState(() {
          _progressDone = done; _progressTotal = total;
          _status = '🗺️ Géolocalisation $done/$total…';
        });
      });
      if (!mounted) return;

      final withCoords = pois.where((p) => p.hasCoords).length;
      setState(() {
        _resolving = false; _fetching = true;
        _status = '🖼️ Recherche images ($withCoords lieux)…';
        _progressDone = 0; _progressTotal = withCoords;
      });

      // Étape 3 : images DuckDuckGo
      await BlogPoiService.fetchImages(
        pois.where((p) => p.hasCoords).toList(),
        onProgress: (done, total) {
          if (mounted) setState(() {
            _progressDone = done; _progressTotal = total;
            _status = '🖼️ Images $done/$total…';
          });
        },
      );
      if (!mounted) return;

      // Détecter les doublons avec les POI existants
      final existing = [
        ...widget.rootLayers.expand((l) => l.points),
        ...widget.folders.expand((f) => f.layers.expand((l) => l.points)),
      ];
      BlogPoiService.checkDuplicates(pois, existing);
      final dupCount = pois.where((p) => p.isDuplicate).length;

      setState(() {
        _fetching = false;
        _status = '✅ ${withCoords}/${pois.length} lieux géolocalisés'
            '${dupCount > 0 ? " · ⚠️ $dupCount doublon(s)" : ""}'
            ' — sélectionnez et importez';
      });

      // Passer sur l'onglet carte
      _tabs.animateTo(1);

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analyzing = false; _resolving = false; _fetching = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ── Édition POI ────────────────────────────────────────────────────────────
  // ── Édition POI avec fusion doublon ─────────────────────────────────────────
  Future<void> _editPoi(BlogPoi poi, {PoiPoint? existingPoi}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => PoiEditDialog(
        poi: poi,
        existingPoi: existingPoi,
        allExisting: [
          ...widget.rootLayers.expand((l) => l.points),
          ...widget.folders.expand((f) => f.layers.expand((l) => l.points)),
        ],
        onReplaceExisting: existingPoi == null ? null : (updated) {
          // Remplacer le POI existant dans ses couches
          for (final l in widget.rootLayers) {
            final idx = l.points.indexWhere((p) => p.name == existingPoi.name);
            if (idx >= 0) { l.points[idx] = updated; break; }
          }
          for (final f in widget.folders) {
            for (final l in f.layers) {
              final idx = l.points.indexWhere((p) => p.name == existingPoi.name);
              if (idx >= 0) { l.points[idx] = updated; break; }
            }
          }
          widget.onImported();
          setState(() { poi.isDuplicate = false; poi.selected = false; _replacedCount++; });
        },
      ),
    );
    if (saved == true) setState(() {});
  }


  // ── Import POI ─────────────────────────────────────────────────────────────
  /// Chaque analyse de blog est regroupée automatiquement dans un dossier
  /// "Blog — JJ/MM" (un dossier par jour d'analyse, pas de prompt).
  Future<void> _importSelected() async {
    final selected = _pois.where((p) => p.selected && p.hasCoords).toList();
    if (selected.isEmpty) return;

    final now = DateTime.now();
    final folderName = PoiImportService.datedFolderLabel('Blog', now);
    final layerName = 'Analyse ${now.hour.toString().padLeft(2,"0")}:'
        '${now.minute.toString().padLeft(2,"0")}';

    final layer = PoiImportService.buildLayer(
      selected.map((p) => p.toPoiPoint()).toList(),
      label: layerName,
    );
    PoiImportService.fileInto(
      layer: layer, rootLayers: widget.rootLayers, folders: widget.folders,
      folderLabel: folderName,
    );

    widget.onImported();

    if (mounted) {
      final addedCount = selected.length;
      final parts = <String>[
        '✅ $addedCount POI ajouté${addedCount > 1 ? "s" : ""}',
        if (_replacedCount > 0)
          '🔄 $_replacedCount remplacé${_replacedCount > 1 ? "s" : ""}',
      ];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${parts.join(" · ")} — dossier « $folderName »'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 4),
      ));
      Navigator.pop(context);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isRunning = _analyzing || _resolving || _fetching;
    return Scaffold(
      backgroundColor: const Color(0xFF1a1a2e),
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: const Text('Analyse Blog → POI',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: Colors.amber,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: [
            const Tab(text: '📝 Texte'),
            Tab(text: '🗺️ Résultats (${_pois.where((p)=>p.hasCoords).length})'),
          ],
        ),
        actions: [
          if (_pois.isNotEmpty)
            TextButton.icon(
              onPressed: _importSelected,
              icon: const Icon(Icons.add_location_alt, color: Colors.amber),
              label: Text(
                'Importer (${_pois.where((p) => p.selected && p.hasCoords).length})',
                style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _buildInputTab(isRunning),
          _buildMapTab(),
        ],
      ),
    );
  }

  Widget _buildInputTab(bool isRunning) {
    return Column(children: [
      // Zone de saisie
      Expanded(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _textCtrl,
            maxLines: null,
            expands: true,
            style: const TextStyle(fontSize: 13, color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Collez ici le texte de votre blog, guide touristique, '
                  'article de voyage…\n\nL\'IA identifiera automatiquement tous les lieux '
                  'et recherchera leurs coordonnées et photos.',
              hintStyle: TextStyle(color: Colors.white30, fontSize: 12),
              filled: true,
              fillColor: const Color(0xFF16213e),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF0f3460)),
              ),
            ),
          ),
        ),
      ),

      // Statut + progression
      if (_status.isNotEmpty || _error != null)
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _error != null
                ? Colors.red.shade900.withOpacity(.3)
                : const Color(0xFF0f1e3c),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _error != null ? Colors.red.shade700 : const Color(0xFF0f3460)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_error ?? _status,
                style: TextStyle(
                    fontSize: 12,
                    color: _error != null ? Colors.red.shade300 : Colors.white70)),
            if (isRunning && _progressTotal > 0) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: _progressTotal > 0 ? _progressDone / _progressTotal : null,
                backgroundColor: const Color(0xFF0f3460),
                color: Colors.amber,
              ),
            ],
          ]),
        ),

      // Info modèle
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(children: [
          const Icon(Icons.psychology, size: 12, color: Colors.white30),
          const SizedBox(width: 4),
          Expanded(child: Text(
            HtmlPoiExtractor.hasApiKey
                ? 'Modèle : ${HtmlPoiExtractor.selectedModel}'
                : '⚠️ Clé API manquante — configurer dans Extraction POI',
            style: const TextStyle(fontSize: 10, color: Colors.white30),
            overflow: TextOverflow.ellipsis,
          )),
        ]),
      ),

      // Bouton analyser
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: isRunning ? null : _analyze,
            icon: isRunning
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.auto_awesome),
            label: Text(
              isRunning ? _status.split('—').first.trim() : 'Analyser le texte',
              overflow: TextOverflow.ellipsis,
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
              backgroundColor: const Color(0xFFe4a010),
              foregroundColor: Colors.black,
              textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              disabledBackgroundColor: const Color(0xFF333),
            ),
          ),
        ),
      ),

      // Copier le prompt pour un agent IA externe
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _copyPromptForExternalAi,
            icon: const Icon(Icons.content_copy, size: 16),
            label: const Text('Copier le prompt pour IA externe'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
              foregroundColor: Colors.deepPurpleAccent,
              side: const BorderSide(color: Colors.deepPurpleAccent),
            ),
          ),
        ),
      ),

      // Bouton importer JSON structuré
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: isRunning ? null : _importJson,
            icon: const Icon(Icons.file_open, size: 18),
            label: const Text('Importer un JSON structuré'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 44),
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Color(0xFF0f3460)),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _buildMapTab() {
    final withCoords = _pois.where((p) => p.hasCoords).toList();
    if (withCoords.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.map_outlined, size: 60, color: Colors.white24),
        const SizedBox(height: 12),
        const Text('Les résultats apparaîtront ici\naprès l\'analyse',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14)),
      ]));
    }

    return _BlogMapView(
      pois:       withCoords,
      allPois:    _pois,
      rootLayers: widget.rootLayers,
      folders:    widget.folders,
      tracks:     widget.tracks,
      replacedCount: _replacedCount,
      onToggle:   (poi) => setState(() => poi.selected = !poi.selected),
      onEdit:     (poi) {
        final existing = [
          ...widget.rootLayers.expand((l) => l.points),
          ...widget.folders.expand((f) => f.layers.expand((l) => l.points)),
        ];
        _editPoi(poi, existingPoi: BlogPoiService.findDuplicatePoiPoint(poi, existing));
      },
      onSelectAll: () => setState(() {
        final allSel = withCoords.every((p) => p.selected);
        for (final p in withCoords) p.selected = !allSel;
      }),
      onImport:   _importSelected,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Vue carte + liste des fiches
// ─────────────────────────────────────────────────────────────────────────────
class _BlogMapView extends StatefulWidget {
  final List<BlogPoi>   pois;
  final List<BlogPoi>   allPois;
  final List<PoiLayer>  rootLayers;
  final List<PoiFolder> folders;
  final List<GpxTrack>  tracks;
  final int             replacedCount;
  final void Function(BlogPoi) onToggle;
  final void Function(BlogPoi) onEdit;
  final VoidCallback onSelectAll;
  final VoidCallback onImport;

  const _BlogMapView({
    required this.pois,
    required this.allPois,
    required this.rootLayers,
    required this.folders,
    required this.tracks,
    required this.replacedCount,
    required this.onToggle,
    required this.onEdit,
    required this.onSelectAll,
    required this.onImport,
  });

  @override
  State<_BlogMapView> createState() => _BlogMapViewState();
}

class _BlogMapViewState extends State<_BlogMapView> {
  late final MapController _mapCtrl;
  BlogPoi? _selected;
  final _scrollCtrl = ScrollController();
  bool   _showExistingLayers = true;
  bool   _showTracks         = true;
  final  Map<String, bool> _layerVisible = {};
  double _mapHeight = 220.0;   // hauteur redimensionnable de la carte
  int    _viewMode  = 1;       // 0=liste, 1=2 colonnes, 2=1 colonne

  static const _colors = {
    'restaurant': Colors.orange,
    'hotel':      Colors.blue,
    'monument':   Colors.purple,
    'castle':     Colors.deepPurple,
    'museum':     Colors.teal,
    'church':     Colors.indigo,
    'viewpoint':  Colors.green,
    'peak':       Colors.brown,
    'park':       Colors.lightGreen,
    'beach':      Colors.cyan,
    'district':   Colors.blueGrey,
    'village':    Colors.amber,
    'city':       Colors.red,
  };

  Color _color(String type) =>
      (_colors[type] ?? Colors.deepOrange) as Color;

  Widget _layerToggle(String label, bool active, Color color, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? color : Colors.white24),
        ),
        child: Text(label, style: TextStyle(
          fontSize: 10, color: active ? color : Colors.white38,
          fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ),
    );

  @override
  void initState() {
    super.initState();
    _mapCtrl = MapController();
  }

  @override
  void dispose() {
    _mapCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _focusPoi(BlogPoi poi) {
    setState(() => _selected = poi);
    _mapCtrl.move(LatLng(poi.lat!, poi.lon!), 14.0);
    // Scroll vers la fiche
    final idx = widget.pois.indexOf(poi);
    if (idx >= 0) {
      _scrollCtrl.animateTo(
        idx * 200.0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final allLats = widget.pois.map((p) => p.lat!).toList();
    final allLons = widget.pois.map((p) => p.lon!).toList();
    final centerLat = allLats.reduce((a,b)=>a+b) / allLats.length;
    final centerLon = allLons.reduce((a,b)=>a+b) / allLons.length;

    final selCount = widget.pois.where((p)=>p.selected).length;
    final noCoords = widget.allPois.where((p)=>!p.hasCoords).length;

    return Column(children: [
      // Barre outils
      Container(
        color: const Color(0xFF0f1e3c),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(children: [
          Expanded(child: Text(
            '${widget.pois.length} géolocalisés · $selCount sélectionnés'
            '${noCoords > 0 ? ' · $noCoords sans coords' : ''}',
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          )),
          TextButton(
            onPressed: widget.onSelectAll,
            child: Text(
              widget.pois.every((p)=>p.selected) ? 'Tout désélect.' : 'Tout sélect.',
              style: const TextStyle(fontSize: 11, color: Colors.amber)),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: selCount > 0 ? widget.onImport : null,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: Text('Importer ($selCount)',
                style: const TextStyle(fontSize: 11)),
          ),
        ]),
      ),

      // Barre couches existantes
      if (widget.rootLayers.isNotEmpty || widget.folders.isNotEmpty || widget.tracks.isNotEmpty)
        Container(
          color: const Color(0xFF0a1628),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(children: [
              const Text('Couches : ', style: TextStyle(fontSize: 10, color: Colors.white38)),
              if (widget.tracks.isNotEmpty)
                _layerToggle('🗺️ GPX (${widget.tracks.length})',
                    _showTracks, Colors.blue,
                    () => setState(() => _showTracks = !_showTracks)),
              ...[ ...widget.rootLayers,
                   ...widget.folders.expand((f) => f.layers)
              ].map((l) => _layerToggle(
                  l.label, _layerVisible[l.label] ?? true,
                  l.color ?? Colors.teal,
                  () => setState(() =>
                      _layerVisible[l.label] = !(_layerVisible[l.label] ?? true)))),
            ]),
          ),
        ),

      // Barre outils vue + resize
      _buildViewToolbar(),

      // Carte redimensionnable
      SizedBox(
        height: _mapHeight,
        child: FlutterMap(
          mapController: _mapCtrl,
          options: MapOptions(
            initialCenter: LatLng(centerLat, centerLon),
            initialZoom: 10,
          ),
          children: [
            const AppMapLayer(),
            // Tracés GPX existants
            if (_showTracks)
              PolylineLayer(polylines: [
                for (final t in widget.tracks)
                  if (t.data.trackPoints.isNotEmpty)
                    Polyline(
                      points: t.data.trackPoints
                          .map((p) => LatLng(p.lat, p.lon)).toList(),
                      color: t.color.withOpacity(.7),
                      strokeWidth: 2.5,
                    ),
              ]),
            // POI des couches existantes
            MarkerLayer(markers: [
              for (final l in [...widget.rootLayers,
                              ...widget.folders.expand((f) => f.layers)])
                if (_layerVisible[l.label] ?? true)
                  for (final p in l.points)
                    Marker(
                      point: LatLng(p.lat, p.lon),
                      width: 20, height: 20,
                      child: Tooltip(
                        message: p.name,
                        child: Container(
                          decoration: BoxDecoration(
                            color: (l.color ?? Colors.teal).withOpacity(.85),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: const Center(child: Icon(Icons.circle,
                              size: 7, color: Colors.white)),
                        ),
                      ),
                    ),
            ]),
            // Nouveaux POI extraits
            MarkerLayer(
              markers: widget.pois.map((poi) {
                final color = poi.isDuplicate ? Colors.orange : _color(poi.type);
                final isSel = poi == _selected;
                return Marker(
                  point: LatLng(poi.lat!, poi.lon!),
                  width: isSel ? 36 : 28,
                  height: isSel ? 36 : 28,
                  child: GestureDetector(
                    onTap: () => _focusPoi(poi),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        color: poi.selected ? color : Colors.grey,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSel ? Colors.white : Colors.white70,
                          width: isSel ? 3 : 1.5,
                        ),
                        boxShadow: isSel ? [BoxShadow(
                          color: color.withOpacity(.5),
                          blurRadius: 8, spreadRadius: 2,
                        )] : null,
                      ),
                      child: Center(child: Text(
                        _typeEmoji(poi.type),
                        style: const TextStyle(fontSize: 13),
                      )),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),

      // Séparateur drag pour redimensionner la carte
      GestureDetector(
        onVerticalDragUpdate: (d) => setState(() {
          _mapHeight = (_mapHeight + d.delta.dy).clamp(80.0, 450.0);
        }),
        child: Container(
          height: 18,
          color: const Color(0xFF0a1628),
          child: Center(child: Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2)),
          )),
        ),
      ),

      // Liste / Mosaïque des fiches
      Expanded(child: _buildPoiList()),
    ]);
  }

  String _typeEmoji(String type) {
    const m = {
      'restaurant':'🍽️','hotel':'🏨','monument':'🏛️','castle':'🏰',
      'museum':'🖼️','church':'⛪','viewpoint':'🔭','peak':'⛰️',
      'park':'🌳','beach':'🏖️','district':'🏙️','village':'🏘️',
      'city':'🏙️','shop':'🛍️','activity':'🎯','nature':'🌿',
      'street':'🛣️','market':'🏪',
    };
    return m[type] ?? '📍';
  }

  // ── Barre outils : mode vue + sélection rapide ────────────────────────────
  Widget _buildViewToolbar() {
    final selCount = widget.allPois.where((p) => p.selected).length;
    return Container(
      color: const Color(0xFF0f1e3c),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(children: [
        // Modes d'affichage
        _modeBtn(Icons.list, 0, 'Liste'),
        const SizedBox(width: 4),
        _modeBtn(Icons.grid_view, 1, '2 colonnes'),
        const SizedBox(width: 4),
        _modeBtn(Icons.crop_square, 2, '1 colonne'),
        const Spacer(),
        // Compteur remplacements
        if (widget.replacedCount > 0) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.teal.withOpacity(.2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.teal.withOpacity(.5))),
            child: Text('🔄 ${widget.replacedCount} remplacé${widget.replacedCount > 1 ? "s" : ""}',
                style: const TextStyle(fontSize: 9, color: Colors.tealAccent)),
          ),
          const SizedBox(width: 6),
        ],
        // Sélection rapide
        Text('$selCount/${widget.allPois.length}',
            style: const TextStyle(fontSize: 11, color: Colors.white54)),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: widget.onSelectAll,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.amber.withOpacity(.5)),
              borderRadius: BorderRadius.circular(12)),
            child: Text(
              widget.allPois.every((p) => p.selected)
                  ? 'Tout désélect.' : 'Tout sélect.',
              style: const TextStyle(fontSize: 10, color: Colors.amber)),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: selCount > 0 ? widget.onImport : null,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.green,
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: 10)),
          child: Text('Import ($selCount)',
              style: const TextStyle(fontSize: 11)),
        ),
      ]),
    );
  }

  Widget _modeBtn(IconData icon, int mode, String tooltip) => Tooltip(
    message: tooltip,
    child: GestureDetector(
      onTap: () => setState(() => _viewMode = mode),
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: _viewMode == mode
              ? Colors.amber.withOpacity(.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: _viewMode == mode ? Colors.amber : Colors.white24)),
        child: Icon(icon, size: 16,
            color: _viewMode == mode ? Colors.amber : Colors.white38),
      ),
    ),
  );

  // ── Liste / Mosaïque selon le mode ────────────────────────────────────────
  Widget _buildPoiList() {
    final pois = widget.allPois;
    if (_viewMode == 0) {
      // Mode liste
      return ListView.builder(
        controller: _scrollCtrl,
        itemCount: pois.length,
        itemBuilder: (ctx, i) => _poiCardWidget(pois[i]),
      );
    }
    // Mode mosaïque : 1 ou 2 colonnes
    final cols = _viewMode == 1 ? 2 : 1;
    return GridView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.all(6),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: cols == 2 ? 0.85 : 2.2,
      ),
      itemCount: pois.length,
      itemBuilder: (ctx, i) => _poiCardWidget(pois[i]),
    );
  }

  Widget _poiCardWidget(BlogPoi poi) => _PoiCard(
    poi:        poi,
    isSelected: poi.selected,
    isFocused:  poi == _selected,
    compact:    _viewMode == 1,
    onTap:      () { if (poi.hasCoords) _focusPoi(poi); },
    onEdit:     () => widget.onEdit(poi),
    onToggle:   () => widget.onToggle(poi),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Fiche POI individuelle
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// _PoiCard — fiche individuelle avec fond grisé si doublon
// ─────────────────────────────────────────────────────────────────────────────
class _PoiCard extends StatelessWidget {
  final BlogPoi  poi;
  final bool     isSelected;
  final bool     isFocused;
  final bool     compact;       // mode 2 colonnes = plus compact
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  const _PoiCard({
    required this.poi, required this.isSelected,
    required this.isFocused, this.compact = false,
    required this.onTap, required this.onEdit, required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final hasCoords = poi.hasCoords;
    final isDup     = poi.isDuplicate;

    return GestureDetector(
      onTap: onTap, onLongPress: onEdit,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: EdgeInsets.symmetric(
            horizontal: compact ? 0 : 8, vertical: compact ? 0 : 4),
        decoration: BoxDecoration(
          color: isDup
              ? Colors.grey.shade800
              : isFocused
                  ? const Color(0xFF1a2f5e)
                  : isSelected
                      ? const Color(0xFF1e3a6e)
                      : const Color(0xFF16213e),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isFocused
                ? Colors.white
                : isDup
                    ? Colors.orange.shade400
                    : isSelected ? Colors.amber : const Color(0xFF0f3460),
            width: isFocused ? 2 : (isDup || isSelected ? 1.5 : 1),
          ),
        ),
        child: Stack(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Miniature image
            ClipRRect(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(9)),
              child: SizedBox(width: 88, height: 96,
                child: Stack(fit: StackFit.expand, children: [
                  poi.imageUrl != null
                      ? Image.network(poi.imageUrl!, fit: BoxFit.cover,
                          errorBuilder: (_,__,___) => _imgPlaceholder(poi.type))
                      : _imgPlaceholder(poi.type),
                  // Overlay grisé + badge DOUBLON sur la miniature
                  if (isDup)
                    Container(
                      color: Colors.black54,
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade700,
                          borderRadius: BorderRadius.circular(4)),
                        child: const Text('DOUBLON',
                            style: TextStyle(color: Colors.white,
                                fontSize: 9, fontWeight: FontWeight.bold,
                                letterSpacing: 0.5)),
                      ),
                    ),
                ]),
              ),
            ),

            // Contenu
            Expanded(child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 40, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(poi.name,
                      style: TextStyle(
                          color: isDup ? Colors.orange.shade200 : Colors.white,
                          fontWeight: FontWeight.bold, fontSize: 13),
                      overflow: TextOverflow.ellipsis)),
                  _coordBadge(poi.coordSource),
                ]),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: Colors.white10,
                      borderRadius: BorderRadius.circular(4)),
                  child: Text(poi.type,
                      style: const TextStyle(fontSize: 9, color: Colors.white54)),
                ),
                const SizedBox(height: 4),
                Text(poi.description,
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                if (poi.tips != null) ...[
                  const SizedBox(height: 3),
                  Text('💡 ${poi.tips!}',
                      style: const TextStyle(fontSize: 10, color: Colors.amber),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
                if (!hasCoords)
                  const Text('⚠️ Coordonnées non trouvées',
                      style: TextStyle(fontSize: 9, color: Colors.red)),
                if (isDup) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.merge_type, size: 11, color: Colors.orange),
                    const SizedBox(width: 3),
                    Expanded(child: Text(
                      'Existe déjà : "${poi.duplicateName}"',
                      style: const TextStyle(fontSize: 9, color: Colors.orange),
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
                  ]),
                ],
              ]),
            )),
          ]),

          // Boutons droite
          Positioned(top: 4, right: 4,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Éditer (+ fusion si doublon)
              _iconBtn(
                icon: isDup ? Icons.merge_type : Icons.edit,
                color: isDup ? Colors.orange : Colors.white38,
                tooltip: isDup ? 'Éditer / Fusionner avec le doublon' : 'Modifier',
                onTap: onEdit,
              ),
              const SizedBox(height: 2),
              // Sélection
              if (hasCoords)
                Transform.scale(scale: 0.85, child: Checkbox(
                  value: isSelected, onChanged: (_) => onToggle(),
                  activeColor: Colors.amber,
                  side: const BorderSide(color: Colors.white38),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                )),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _imgPlaceholder(String type) => Container(
    color: const Color(0xFF0f3460),
    child: Center(child: Text(_typeEmoji(type),
        style: const TextStyle(fontSize: 28))));

  Widget _iconBtn({required IconData icon, required Color color,
      required String tooltip, required VoidCallback onTap}) =>
    Tooltip(message: tooltip,
      child: GestureDetector(onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.black38, borderRadius: BorderRadius.circular(6)),
          child: Icon(icon, size: 16, color: color),
        )));

  Widget _coordBadge(CoordSource src) {
    final (label, color) = switch(src) {
      CoordSource.both      => ('N+IA', Colors.green),
      CoordSource.nominatim => ('OSM',  Colors.blue),
      CoordSource.ai        => ('IA',   Colors.purple),
      CoordSource.manual    => ('✎',   Colors.amber),
      CoordSource.unknown   => ('?',   Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(.25),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(.5))),
      child: Text(label, style: TextStyle(fontSize: 9, color: color,
          fontWeight: FontWeight.bold)));
  }

  String _typeEmoji(String type) => const {
    'restaurant':'🍽️','hotel':'🏨','monument':'🏛️','castle':'🏰',
    'museum':'🖼️','church':'⛪','viewpoint':'🔭','peak':'⛰️',
    'park':'🌳','beach':'🏖️','district':'🏙️','village':'🏘️',
    'city':'🏙️','shop':'🛍️','activity':'🎯','nature':'🌿',
    'street':'🛣️','market':'🏪',
  }[type] ?? '📍';
}

