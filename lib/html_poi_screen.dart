import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'core/services/vector_map_layer.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'html_poi_extractor.dart';
import 'app_dirs.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'poi_geocoder.dart';
import 'gpx_track.dart';
import 'poi_ai_common.dart';
import 'core/services/poi_import_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Écran d'extraction POI via IA
// ─────────────────────────────────────────────────────────────────────────────
class HtmlPoiScreen extends StatefulWidget {
  final List<PoiLayer>  rootLayers;
  final List<PoiFolder> folders;
  final List<GpxTrack>  tracks;
  final VoidCallback    onImported;

  const HtmlPoiScreen({
    super.key,
    required this.rootLayers,
    required this.folders,
    required this.tracks,
    required this.onImported,
  });

  @override
  State<HtmlPoiScreen> createState() => _HtmlPoiScreenState();
}

class _HtmlPoiScreenState extends State<HtmlPoiScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  final _htmlController      = TextEditingController();
  final _apiKeyController    = TextEditingController(text: HtmlPoiExtractor.apiKey);
  final _promptController    = TextEditingController(
      text: HtmlPoiExtractor.hasCustomPrompt ? HtmlPoiExtractor.activePrompt : '');
  late final _defaultPromptController = TextEditingController(
      text: HtmlPoiExtractor.hasEditedDefaultPrompt
          ? HtmlPoiExtractor.editedDefaultPrompt : '');

  String?       _error;
  List<PoiPoint> _preview     = [];
  GeoFragments? _fragments;
  String        _aiRaw        = '';
  String        _aiModel      = '';
  int           _aiCount      = 0;
  int           _localCount   = 0;
  bool          _isLoading    = false;
  bool          _isGeocoding  = false;
  bool          _isFetchingImages = false;
  bool          _isResolvingCoords = false;
  int           _resolvedCount = 0;
  int           _resolveTotal  = 0;
  String        _geocodeStatus = '';
  int           _geocodeDone  = 0;
  int           _geocodeTotal = 0;

  // Sélection pour import
  final Set<int> _selectedIndices = {};

  // Doublons (indices des _preview qui existent déjà dans les couches)
  final Set<int> _duplicateIndices = {};
  final Map<int, String> _duplicateNames = {};

  String         _selectedModel = HtmlPoiExtractor.selectedModel;
  List<({String id, String label})> _models = HtmlPoiExtractor.kFreeModels;
  bool  _loadingModels = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    if (HtmlPoiExtractor.lastInputText.isNotEmpty) {
      _htmlController.text = HtmlPoiExtractor.lastInputText;
    }
    _fetchModels();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _htmlController.dispose();
    _apiKeyController.dispose();
    _promptController.dispose();
    _defaultPromptController.dispose();
    super.dispose();
  }

  // ── Chargement modèles ─────────────────────────────────────────────────────
  Future<void> _fetchModels({bool forceRefresh = false}) async {
    setState(() => _loadingModels = true);
    try {
      final models = await AppDirs.fetchOpenRouterModels(
        apiKey: HtmlPoiExtractor.apiKey, forceRefresh: forceRefresh);
      if (mounted && models.isNotEmpty) {
        setState(() {
          _models = models;
          if (!_models.any((m) => m.id == _selectedModel)) {
            _selectedModel = _models.first.id;
            HtmlPoiExtractor.setModel(_selectedModel);
          }
        });
      }
    } catch (_) {}
    finally { if (mounted) setState(() => _loadingModels = false); }
  }

  // ── Copier prompt pour agent externe ──────────────────────────────────────
  Future<void> _copyPromptForExternalAi() async {
    final input = _htmlController.text.trim();
    final cleaned = input.isEmpty
        ? '(coller votre texte ici)'
        : HtmlPoiExtractor.stripHtmlForPrompt(input);
    await Clipboard.setData(ClipboardData(text: '$kCommonPoiPrompt$cleaned'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('📋 Prompt copié ! Collez dans ChatGPT/Claude/Gemini, '
          'puis importez le JSON via "Analyser un blog → Importer un JSON structuré".'),
      duration: Duration(seconds: 5),
    ));
  }

  // ── Helpers internes ──────────────────────────────────────────────────────

  /// Distance approx entre deux coords en mètres
  static double _distM(double lat1, double lon1, double lat2, double lon2) {
    final dlat = (lat2 - lat1) * 111320;
    final dlon = (lon2 - lon1) * 111320 * _cos(lat1 * 3.14159 / 180);
    return (dlat * dlat + dlon * dlon) < 0 ? 0 : _sqrt(dlat * dlat + dlon * dlon);
  }

  static double _cos(double x) {
    double r = 1, t = 1;
    for (int i = 1; i <= 8; i++) { t *= -x*x/(2*i*(2*i-1)); r += t; }
    return r;
  }

  static double _sqrt(double x) {
    if (x <= 0) return 0;
    double s = x / 2;
    for (int i = 0; i < 20; i++) s = (s + x / s) / 2;
    return s;
  }

  /// Similarité de noms (Dice bigrammes, 0..1)
  static double _nameSim(String a, String b) {
    final na = a.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final nb = b.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (na.isEmpty || nb.isEmpty) return 0;
    if (na == nb) return 1.0;
    Set<String> bg(String s) {
      final set = <String>{};
      for (int i = 0; i < s.length - 1; i++) set.add(s.substring(i, i+2));
      return set;
    }
    final ba = bg(na), bb = bg(nb);
    final common = ba.intersection(bb).length;
    if (ba.length + bb.length == 0) return 0;
    return 2 * common / (ba.length + bb.length);
  }

  /// Recherche une image DuckDuckGo pour un POI
  static Future<String?> _fetchDdgImage(String query) async {
    try {
      final init = await http.get(
        Uri.parse('https://duckduckgo.com/?q=${Uri.encodeComponent(query)}&iax=images&ia=images'),
        headers: {'User-Agent': 'Mozilla/5.0 (compatible)'},
      ).timeout(const Duration(seconds: 8));
      final vqd = RegExp(r'vqd=([\d-]+)').firstMatch(init.body)?.group(1);
      if (vqd == null) return null;
      final img = await http.get(
        Uri.parse('https://duckduckgo.com/i.js?q=${Uri.encodeComponent(query)}&vqd=$vqd&f=,,,,,'),
        headers: {'User-Agent': 'Mozilla/5.0 (compatible)', 'Referer': 'https://duckduckgo.com/'},
      ).timeout(const Duration(seconds: 8));
      if (img.statusCode != 200) return null;
      final data = json.decode(img.body) as Map;
      final results = data['results'] as List? ?? [];
      for (final r in results.take(5)) {
        final url = r['image']?.toString() ?? '';
        if (url.isNotEmpty) return url;
      }
    } catch (_) {}
    return null;
  }

  // ── Extraction IA ─────────────────────────────────────────────────────────
  Future<void> _extract() async {
    final input = _htmlController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Collez du texte ou du HTML dans le champ');
      return;
    }
    HtmlPoiExtractor.setModel(_selectedModel);
    HtmlPoiExtractor.setApiKey(_apiKeyController.text);
    HtmlPoiExtractor.setCustomPrompt(
        _promptController.text.trim().isEmpty ? null : _promptController.text.trim());

    setState(() {
      _isLoading = true; _error = null; _preview = []; _fragments = null;
      _aiRaw = ''; _aiModel = ''; _aiCount = 0; _localCount = 0;
      _selectedIndices.clear(); _duplicateIndices.clear(); _duplicateNames.clear();
    });
    try {
      var result = await HtmlPoiExtractor.extract(input);
      if (!mounted) return;

      // Recherche de photos pour les POI qui n'en ont pas encore (alignement
      // avec le pipeline blog_poi_service.dart, qui fait déjà cette étape).
      try {
        final enrichedPoints = await HtmlPoiExtractor.enrichPhotos(result.points);
        result = (
          points: enrichedPoints,
          fragments: result.fragments,
          aiRaw: result.aiRaw,
          aiModel: result.aiModel,
          aiCount: result.aiCount,
          localCount: result.localCount,
        );
      } catch (_) {
        // La recherche de photo est un enrichissement facultatif : on ne
        // bloque pas l'affichage des POI extraits si elle échoue.
      }
      if (!mounted) return;

      // Vérifier doublons
      final allExisting = [
        ...widget.rootLayers.expand((l) => l.points),
        ...widget.folders.expand((f) => f.layers.expand((l) => l.points)),
      ];
      final dupIdx = <int>{};
      final dupNames = <int, String>{};
      for (int i = 0; i < result.points.length; i++) {
        final p = result.points[i];
        for (final e in allExisting) {
          final dist = _distM(p.lat, p.lon, e.lat, e.lon);
          if (dist < 100 || _nameSim(p.name, e.name) > 0.8) {
            dupIdx.add(i);
            dupNames[i] = e.name;
            break;
          }
        }
      }

      setState(() {
        _preview    = result.points;
        _fragments  = result.fragments;
        _aiRaw      = result.aiRaw;
        _aiModel    = result.aiModel;
        _aiCount    = result.aiCount;
        _localCount = result.localCount;
        _duplicateIndices.addAll(dupIdx);
        _duplicateNames.addAll(dupNames);
        // Tout sélectionner sauf doublons
        for (int i = 0; i < result.points.length; i++) {
          if (!dupIdx.contains(i)) _selectedIndices.add(i);
        }
      });

      if (result.points.isEmpty) {
        setState(() => _error = 'Aucun POI extrait du texte');
      } else {
        // Résoudre les coords manquantes via Nominatim, puis chercher images
        _resolveAndFetch();
        _tabController.animateTo(1); // onglet résultats
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── Résolution coords manquantes + images ────────────────────────────────
  Future<void> _resolveAndFetch() async {
    if (_preview.isEmpty) return;

    // Étape 1 : résoudre coords manquantes via Nominatim
    final noCoords = [
      for (int i = 0; i < _preview.length; i++)
        if (_preview[i].type == 'no_coords') i,
    ];
    if (noCoords.isNotEmpty) {
      setState(() { _isResolvingCoords = true; _resolvedCount = 0; _resolveTotal = noCoords.length; });
      for (final i in noCoords) {
        if (!mounted) return;
        final p = _preview[i];
        setState(() => _geocodeStatus = 'Résolution : ${p.name}…');
        try {
          final res = await PoiGeocoder.search(p.name);
          if (res != null && mounted) {
            setState(() {
              _preview[i] = p.copyWith(lat: res.lat, lon: res.lon, type: 'coord');
              _resolvedCount++;
            });
          }
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 1100)); // rate limit Nominatim
      }
      if (mounted) setState(() { _isResolvingCoords = false; _geocodeStatus = ''; });
    }

    // Étape 2 : rechercher images
    setState(() => _isFetchingImages = true);
    for (int i = 0; i < _preview.length; i++) {
      if (!mounted) return;
      final p = _preview[i];
      if (p.type == 'no_coords') continue; // pas d'image si pas de coords
      if (p.photoUrls.isNotEmpty) continue; // déjà une image
      try {
        final url = await _fetchDdgImage(p.name);
        if (url != null && mounted) setState(() => _preview[i] = p.copyWith(photoUrls: [url]));
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    }
    if (mounted) setState(() => _isFetchingImages = false);
  }

  // ── Géocodage noms locaux ─────────────────────────────────────────────────
  Future<void> _geocodeLocalNames() async {
    if (_fragments == null || _fragments!.geoNames.isEmpty) return;
    setState(() {
      _isGeocoding = true; _geocodeDone = 0;
      _geocodeTotal = _fragments!.geoNames.length;
    });
    for (final name in _fragments!.geoNames) {
      if (!mounted) return;
      setState(() => _geocodeStatus = 'Géocodage : $name…');
      try {
        final res = await PoiGeocoder.search(name);
        if (res != null && mounted) {
          final pt = PoiPoint(name: name, lat: res.lat, lon: res.lon, type: 'address');
          final dup = _preview.any((p) =>
              (p.lat - res.lat).abs() < 0.001 && (p.lon - res.lon).abs() < 0.001);
          if (!dup) setState(() { _preview.add(pt); _selectedIndices.add(_preview.length - 1); });
        }
      } catch (_) {}
      if (mounted) setState(() => _geocodeDone++);
      await Future.delayed(const Duration(milliseconds: 1200));
    }
    if (mounted) setState(() { _isGeocoding = false; _geocodeStatus = ''; });
  }

  // ── Import ─────────────────────────────────────────────────────────────────
  Future<void> _import() async {
    final selected = [
      for (int i = 0; i < _preview.length; i++)
        if (_selectedIndices.contains(i)) _preview[i],
    ];
    if (selected.isEmpty) return;
    // Créer une couche POI avec les éléments sélectionnés
    final layerName = 'IA — ${DateTime.now().day}/${DateTime.now().month}';
    final layer = PoiImportService.buildLayer(selected, label: layerName);
    PoiImportService.fileInto(
      layer: layer, rootLayers: widget.rootLayers, folders: widget.folders,
    );
    widget.onImported();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ ${selected.length} POI ajoutés dans "$layerName"'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 3),
      ));
      Navigator.pop(context);
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Extraction POI'),
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        actions: [
          if (_preview.isNotEmpty)
            TextButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.add_location_alt, color: Colors.amber),
              label: Text(
                'Importer (${_selectedIndices.length})',
                style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold),
              ),
            ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.amber,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: [
            const Tab(icon: Icon(Icons.edit_note, size: 18), text: 'Saisie'),
            Tab(
              icon: const Icon(Icons.list_alt, size: 18),
              text: _preview.isNotEmpty
                  ? 'Résultats (${_preview.length})' : 'Résultats',
            ),
            const Tab(icon: Icon(Icons.map, size: 18), text: 'Carte'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildInputTab(),
          _buildResultsTab(),
          _buildMapTab(),
        ],
      ),
    );
  }

  // ── Onglet saisie ─────────────────────────────────────────────────────────
  Widget _buildInputTab() {
    final isRunning = _isLoading || _isGeocoding;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Champ texte
        TextField(
          controller: _htmlController,
          maxLines: 8,
          style: const TextStyle(fontSize: 12),
          decoration: const InputDecoration(
            hintText: 'Collez ici le texte de votre blog, article, guide...',
            border: OutlineInputBorder(),
            labelText: 'Texte à analyser',
          ),
        ),
        const SizedBox(height: 10),

        // Paramètres IA
        ExpansionTile(
          title: Row(children: [
            const Icon(Icons.settings, size: 16, color: Colors.grey),
            const SizedBox(width: 6),
            Text('Paramètres IA (OpenRouter)',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade800)),
          ]),
          initiallyExpanded: !HtmlPoiExtractor.hasApiKey,
          children: [
            // Clé API
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: TextField(
                controller: _apiKeyController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Clé API OpenRouter',
                  border: const OutlineInputBorder(),
                  helperText: 'Gratuit sur openrouter.ai (inscription requise)',
                  suffixIcon: TextButton(
                    onPressed: () => HtmlPoiExtractor.setApiKey(_apiKeyController.text),
                    child: const Text('OK'),
                  ),
                ),
              ),
            ),
            // Modèle
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(children: [
                Expanded(child: DropdownButtonFormField<String>(
                  value: _models.any((m) => m.id == _selectedModel)
                      ? _selectedModel : _models.first.id,
                  decoration: const InputDecoration(
                    labelText: 'Modèle IA', border: OutlineInputBorder()),
                  items: _models.map((m) => DropdownMenuItem(
                      value: m.id,
                      child: Text(m.label,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: (v) {
                    if (v != null) { setState(() => _selectedModel = v); HtmlPoiExtractor.setModel(v); }
                  },
                )),
                const SizedBox(width: 6),
                IconButton(
                  icon: _loadingModels
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh),
                  onPressed: _loadingModels ? null : () => _fetchModels(forceRefresh: true),
                ),
              ]),
            ),
            // Prompt personnalisé
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Prompt personnalisé (remplace le prompt par défaut)',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                TextField(
                  controller: _promptController,
                  maxLines: 4,
                  style: const TextStyle(fontSize: 11),
                  decoration: InputDecoration(
                    hintText: 'Vide = prompt par défaut',
                    hintStyle: const TextStyle(color: Colors.grey),
                    border: const OutlineInputBorder(),
                    helperText: HtmlPoiExtractor.hasCustomPrompt
                        ? '✏️ Prompt personnalisé actif' : null,
                    suffixIcon: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      if (HtmlPoiExtractor.hasCustomPrompt)
                        IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          tooltip: 'Supprimer le prompt personnalisé',
                          onPressed: () => setState(() {
                            HtmlPoiExtractor.setCustomPrompt(null);
                            _promptController.clear();
                          }),
                        ),
                      IconButton(
                        icon: const Icon(Icons.save, size: 18),
                        tooltip: 'Sauvegarder',
                        onPressed: () => setState(() {
                          HtmlPoiExtractor.setCustomPrompt(_promptController.text);
                        }),
                      ),
                    ]),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ]),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Cadre analyse
        if (_fragments != null)
          _AnalysisCard(
            fragments: _fragments!, aiRaw: _aiRaw, aiModel: _aiModel,
            aiCount: _aiCount, localCount: _localCount,
            hasApiKey: HtmlPoiExtractor.hasApiKey,
            hasPrompt: HtmlPoiExtractor.hasCustomPrompt,
            activePromptPreview: HtmlPoiExtractor.hasCustomPrompt
                ? HtmlPoiExtractor.activePrompt.substring(
                    0, HtmlPoiExtractor.activePrompt.length.clamp(0, 80))
                : null,
          ),
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade300)),
            child: Row(children: [
              Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 12))),
            ]),
          ),

        // Boutons
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: isRunning ? null : _extract,
            icon: _isLoading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.auto_awesome),
            label: Text(_isLoading ? 'Analyse en cours...' : 'Extraire les lieux'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              backgroundColor: const Color(0xFF003580)),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _copyPromptForExternalAi,
          icon: const Icon(Icons.content_copy, size: 16),
          label: const Text('Copier le prompt pour IA externe (ChatGPT, Claude...)'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 44),
            foregroundColor: Colors.deepPurple,
            side: const BorderSide(color: Colors.deepPurple)),
        ),
      ]),
    );
  }

  // ── Onglet résultats ──────────────────────────────────────────────────────
  Widget _buildResultsTab() {
    if (_preview.isEmpty) {
      return const Center(child: Text('Lancez l\'extraction pour voir les résultats',
          style: TextStyle(color: Colors.grey)));
    }
    return Column(children: [
      // Barre statut
      Container(
        color: Colors.green.shade50,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Icon(Icons.check_circle, color: Colors.green.shade700, size: 16),
          const SizedBox(width: 6),
          Expanded(child: Text(
            '${_preview.length} lieux · ${_selectedIndices.length} sélectionnés'
            '${_duplicateIndices.isNotEmpty ? " · ⚠️ ${_duplicateIndices.length} doublons" : ""}'
            '${_preview.where((p) => p.type == "no_coords").isNotEmpty ? " · ❓ ${_preview.where((p) => p.type == "no_coords").length} sans coords" : ""}'
            '${_isResolvingCoords ? " · 🔍 résolution ${_resolvedCount}/${_resolveTotal}…" : ""}'
            '${_isFetchingImages ? " · 🖼️ images…" : ""}',
            style: TextStyle(color: Colors.green.shade800,
                fontWeight: FontWeight.w500, fontSize: 12),
          )),
          TextButton(
            onPressed: () => setState(() {
              if (_selectedIndices.length == _preview.length) {
                _selectedIndices.clear();
              } else {
                _selectedIndices.addAll(List.generate(_preview.length, (i) => i));
              }
            }),
            child: Text(
              _selectedIndices.length == _preview.length ? 'Désélect. tout' : 'Tout sélect.',
              style: const TextStyle(fontSize: 11)),
          ),
        ]),
      ),

      // Liste fiches enrichies
      Expanded(child: ListView.builder(
        itemCount: _preview.length,
        itemBuilder: (ctx, i) {
          final p = _preview[i];
          final isDup = _duplicateIndices.contains(i);
          final isSel = _selectedIndices.contains(i);
          return _PoiResultCard(
            poi:      p,
            index:    i,
            isSelected: isSel,
            isDuplicate: isDup,
            duplicateName: _duplicateNames[i],
            onToggle: () => setState(() {
              if (isSel) _selectedIndices.remove(i);
              else       _selectedIndices.add(i);
            }),
            onDelete: () => setState(() {
              _preview.removeAt(i);
              _selectedIndices.remove(i);
              _duplicateIndices.remove(i);
            }),
            onTap: () => _tabController.animateTo(2), // aller sur la carte
          );
        },
      )),
    ]);
  }

  // ── Onglet carte ─────────────────────────────────────────────────────────
  Widget _buildMapTab() {
    return _PoiMapPreview(
      newPois:    _preview,
      selected:   _selectedIndices,
      rootLayers: widget.rootLayers,
      folders:    widget.folders,
      tracks:     widget.tracks,
      onToggle: (i) => setState(() {
        if (_selectedIndices.contains(i)) _selectedIndices.remove(i);
        else _selectedIndices.add(i);
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fiche POI enrichie dans la liste résultats
// ─────────────────────────────────────────────────────────────────────────────
class _PoiResultCard extends StatelessWidget {
  final PoiPoint poi;
  final int      index;
  final bool     isSelected;
  final bool     isDuplicate;
  final String?  duplicateName;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  const _PoiResultCard({
    required this.poi, required this.index, required this.isSelected,
    required this.isDuplicate, this.duplicateName,
    required this.onToggle, required this.onDelete, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: poi.type == 'no_coords'
                ? Colors.red.shade50
                : isDuplicate ? Colors.orange.shade50 : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: poi.type == 'no_coords'
                ? Colors.red.shade300
                : isDuplicate
                    ? Colors.orange.shade400
                    : isSelected ? Colors.blue.shade400 : Colors.grey.shade300,
            width: isSelected || isDuplicate ? 1.5 : 1,
          ),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(.05),
              blurRadius: 3, offset: const Offset(0, 1))],
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Miniature image ou emoji
          ClipRRect(
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(7)),
            child: SizedBox(
              width: 72, height: 80,
              child: poi.photoUrls.isNotEmpty
                  ? Image.network(poi.photoUrls.first,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _emojiThumb())
                  : _emojiThumb(),
            ),
          ),

          // Contenu
          Expanded(child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(poi.name,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    overflow: TextOverflow.ellipsis)),
                // Badge type
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.shade100,
                    borderRadius: BorderRadius.circular(4)),
                  child: Text(poi.type ?? 'poi',
                      style: const TextStyle(fontSize: 9, color: Colors.blueGrey)),
                ),
              ]),
              const SizedBox(height: 2),
              poi.type == 'no_coords'
                ? Row(children: [
                    const Icon(Icons.location_off, size: 11, color: Colors.red),
                    const SizedBox(width: 3),
                    const Text('Coordonnées non trouvées',
                        style: TextStyle(fontSize: 10, color: Colors.red,
                            fontStyle: FontStyle.italic)),
                  ])
                : Text('${poi.lat.toStringAsFixed(5)}, ${poi.lon.toStringAsFixed(5)}',
                    style: const TextStyle(fontSize: 9, fontFamily: 'monospace',
                        color: Colors.grey)),
              if (poi.description != null) ...[
                const SizedBox(height: 3),
                Text(poi.description!,
                    style: const TextStyle(fontSize: 11, color: Colors.black87),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
              if (isDuplicate) ...[
                const SizedBox(height: 3),
                Row(children: [
                  const Icon(Icons.warning_amber, size: 12, color: Colors.orange),
                  const SizedBox(width: 3),
                  Expanded(child: Text(
                    'Doublon : "${duplicateName ?? "?"}"',
                    style: const TextStyle(fontSize: 10, color: Colors.orange),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
              ],
            ]),
          )),

          // Checkbox + supprimer
          Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Checkbox(
              value: poi.type != 'no_coords' && isSelected,
              onChanged: poi.type == 'no_coords' ? null : (_) => onToggle(),
              activeColor: Colors.blue,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 14, color: Colors.red),
              onPressed: onDelete,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _emojiThumb() => Container(
    color: Colors.grey.shade100,
    child: Center(child: Text(_typeEmoji(poi.type),
        style: const TextStyle(fontSize: 26))));

  String _typeEmoji(String? t) => const {
    'place': '🏛️', 'city': '🏙️', 'village': '🏘️', 'quartier': '🏙️',
    'hotel': '🏨', 'restaurant': '🍽️', 'cafe': '☕', 'bar': '🍺',
    'monument': '🗿', 'monument_religieux': '⛪', 'palais': '🏰',
    'musee': '🖼️', 'marche': '🏪', 'parc': '🌳', 'jardin': '🌷',
    'plage': '🏖️', 'point_de_vue': '🔭', 'spot_photo': '📸',
    'stade': '🏟️', 'spectacle': '🎭', 'shopping': '🛍️',
    'nature': '🌿', 'rue_pittoresque': '🛣️', 'coord': '📍',
  }[t] ?? '📌';
}

// ─────────────────────────────────────────────────────────────────────────────
// Carte prévisualisation : nouveaux POI + couches existantes
// ─────────────────────────────────────────────────────────────────────────────
class _PoiMapPreview extends StatefulWidget {
  final List<PoiPoint>  newPois;
  final Set<int>        selected;
  final List<PoiLayer>  rootLayers;
  final List<PoiFolder> folders;
  final List<GpxTrack>  tracks;
  final void Function(int) onToggle;

  const _PoiMapPreview({
    required this.newPois, required this.selected,
    required this.rootLayers, required this.folders,
    required this.tracks, required this.onToggle,
  });

  @override
  State<_PoiMapPreview> createState() => _PoiMapPreviewState();
}

class _PoiMapPreviewState extends State<_PoiMapPreview> {
  late final MapController _mc;
  bool _showExistingPoi = true;
  bool _showTracks      = true;
  // Visibilité par couche
  final Map<String, bool> _layerVisible = {};

  @override
  void initState() {
    super.initState();
    _mc = MapController();
  }

  @override
  void dispose() { _mc.dispose(); super.dispose(); }

  List<PoiLayer> get _allLayers => [
    ...widget.rootLayers,
    ...widget.folders.expand((f) => f.layers),
  ];

  bool _isLayerVisible(PoiLayer l) => _layerVisible[l.label] ?? true;

  @override
  Widget build(BuildContext context) {
    if (widget.newPois.isEmpty) {
      return const Center(child: Text('Lancez l\'extraction pour voir les résultats',
          style: TextStyle(color: Colors.grey)));
    }

    // Centre de la carte
    final allLat = widget.newPois.map((p) => p.lat).toList();
    final allLon = widget.newPois.map((p) => p.lon).toList();
    final cLat = allLat.reduce((a,b) => a+b) / allLat.length;
    final cLon = allLon.reduce((a,b) => a+b) / allLon.length;

    return Column(children: [
      // Barre de filtres couches
      Container(
        color: const Color(0xFFF5F5F5),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            // Toggle POI existants
            _layerChip(
              label: '📍 POI existants',
              active: _showExistingPoi,
              color: Colors.teal,
              onTap: () => setState(() => _showExistingPoi = !_showExistingPoi),
            ),
            const SizedBox(width: 6),
            // Toggle tracés GPX
            if (widget.tracks.isNotEmpty)
              _layerChip(
                label: '🗺️ Tracés GPX (${widget.tracks.length})',
                active: _showTracks,
                color: Colors.blue,
                onTap: () => setState(() => _showTracks = !_showTracks),
              ),
            const SizedBox(width: 6),
            // Une puce par couche POI existante
            if (_showExistingPoi)
              ..._allLayers.map((l) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _layerChip(
                  label: l.label,
                  active: _isLayerVisible(l),
                  color: l.color ?? Colors.teal,
                  onTap: () => setState(() =>
                      _layerVisible[l.label] = !_isLayerVisible(l)),
                ),
              )),
            // Nouveaux POI (toujours visibles)
            _layerChip(
              label: '✨ Nouveaux (${widget.newPois.length})',
              active: true,
              color: Colors.deepOrange,
              onTap: () {},
            ),
          ]),
        ),
      ),

      // Carte
      Expanded(child: FlutterMap(
        mapController: _mc,
        options: MapOptions(
          initialCenter: LatLng(cLat, cLon),
          initialZoom: 12,
        ),
        children: [
          const AppMapLayer(),

          // Tracés GPX existants
          if (_showTracks)
            PolylineLayer(polylines: [
              for (final t in widget.tracks)
                if (t.data.trackPoints.isNotEmpty)
                  Polyline(
                    points: t.data.trackPoints.map((p) => LatLng(p.lat, p.lon)).toList(),
                    color: Colors.blue.withOpacity(0.7),
                    strokeWidth: 2.5,
                  ),
            ]),

          // POI existants
          if (_showExistingPoi)
            MarkerLayer(markers: [
              for (final l in _allLayers)
                if (_isLayerVisible(l))
                  for (final p in l.points)
                    Marker(
                      point: LatLng(p.lat, p.lon),
                      width: 22, height: 22,
                      child: Container(
                        decoration: BoxDecoration(
                          color: (l.color ?? Colors.teal).withOpacity(.85),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: const Center(child: Icon(Icons.circle, size: 8, color: Colors.white)),
                      ),
                    ),
            ]),

          // Nouveaux POI extraits par l'IA (seulement ceux avec coords valides)
          MarkerLayer(markers: [
            for (int i = 0; i < widget.newPois.length; i++)
              if (widget.newPois[i].type != 'no_coords') ...[
              Marker(
                point: LatLng(widget.newPois[i].lat, widget.newPois[i].lon),
                width: widget.selected.contains(i) ? 34 : 26,
                height: widget.selected.contains(i) ? 34 : 26,
                child: GestureDetector(
                  onTap: () => widget.onToggle(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: widget.selected.contains(i)
                          ? Colors.deepOrange : Colors.deepOrange.withOpacity(.4),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: widget.selected.contains(i) ? Colors.white : Colors.orange,
                        width: widget.selected.contains(i) ? 2.5 : 1.5,
                      ),
                      boxShadow: widget.selected.contains(i) ? [
                        BoxShadow(color: Colors.deepOrange.withOpacity(.4),
                            blurRadius: 6, spreadRadius: 2),
                      ] : null,
                    ),
                    child: Center(child: Text(
                      _typeEmoji(widget.newPois[i].type),
                      style: const TextStyle(fontSize: 13),
                    )),
                  ),
                ),
              ),
            ],
          ]),
        ],
      )),
    ]);
  }

  Widget _layerChip({
    required String label, required bool active,
    required Color color, required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: active ? color.withOpacity(.15) : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: active ? color : Colors.grey.shade400),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: active ? color : Colors.grey,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
    ),
  );

  String _typeEmoji(String? t) => const {
    'place': '🏛️', 'city': '🏙️', 'hotel': '🏨', 'restaurant': '🍽️',
    'monument': '🗿', 'monument_religieux': '⛪', 'palais': '🏰',
    'musee': '🖼️', 'marche': '🏪', 'parc': '🌳', 'point_de_vue': '🔭',
    'stade': '🏟️', 'spot_photo': '📸', 'quartier': '🏙️',
  }[t] ?? '📌';
}

// ═══════════════════════════════════════════════════════════════════════════
// _AnalysisCard — inchangée
// ═══════════════════════════════════════════════════════════════════════════
class _AnalysisCard extends StatefulWidget {
  final GeoFragments fragments;
  final String  aiRaw, aiModel;
  final int     aiCount, localCount;
  final bool    hasApiKey, hasPrompt;
  final String? activePromptPreview;

  const _AnalysisCard({
    required this.fragments, required this.aiRaw, required this.aiModel,
    required this.aiCount, required this.localCount,
    required this.hasApiKey, required this.hasPrompt, this.activePromptPreview,
  });

  @override
  State<_AnalysisCard> createState() => _AnalysisCardState();
}

class _AnalysisCardState extends State<_AnalysisCard> {
  bool _showRaw = false;

  @override
  Widget build(BuildContext context) {
    final hasAiResult = widget.aiRaw.isNotEmpty;
    final aiEmpty = hasAiResult && widget.aiCount == 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('📊 Analyse', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          const Spacer(),
          if (hasAiResult)
            GestureDetector(
              onTap: () => setState(() => _showRaw = !_showRaw),
              child: Text(_showRaw ? 'Masquer JSON' : 'Voir JSON IA',
                  style: TextStyle(fontSize: 10, color: Colors.blue.shade700,
                      decoration: TextDecoration.underline)),
            ),
        ]),
        const SizedBox(height: 6),
        _row('🔍 Local', widget.fragments.summary, Colors.blueGrey.shade700),
        const SizedBox(height: 2),
        if (!widget.hasApiKey)
          _row('⚠️ IA', 'Pas de clé API OpenRouter', Colors.orange.shade700)
        else if (!hasAiResult)
          _row('⏳ IA', 'En attente…', Colors.grey)
        else if (aiEmpty) ...[
          _row('🤖 IA', 'Modèle : ${widget.aiModel}', Colors.purple.shade700),
          _row('❌ IA', 'Aucun POI retourné', Colors.red.shade700),
        ] else ...[
          _row('🤖 IA', '${widget.aiModel}  •  ${widget.aiCount} POI', Colors.purple.shade700),
        ],
        if (_showRaw && hasAiResult) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade900, borderRadius: BorderRadius.circular(6)),
            child: SelectableText(widget.aiRaw,
                style: const TextStyle(fontSize: 9, color: Colors.greenAccent, fontFamily: 'monospace')),
          ),
        ],
      ]),
    );
  }

  Widget _row(String label, String value, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: RichText(text: TextSpan(
      style: TextStyle(fontSize: 11, color: color),
      children: [
        TextSpan(text: '$label : ', style: const TextStyle(fontWeight: FontWeight.bold)),
        TextSpan(text: value),
      ],
    )),
  );
}
