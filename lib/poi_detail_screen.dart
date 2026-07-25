import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'poi_layer.dart';
import 'poi_web_search_screen.dart';
import 'poi_field_search.dart';

class PoiDetailScreen extends StatefulWidget {
  final PoiPoint poi;
  final Color    color;
  const PoiDetailScreen({super.key, required this.poi, required this.color});

  @override
  State<PoiDetailScreen> createState() => _PoiDetailScreenState();
}

class _PoiDetailScreenState extends State<PoiDetailScreen> {
  late final TextEditingController _nameC;
  late final TextEditingController _latC;
  late final TextEditingController _lonC;
  late final TextEditingController _descC;
  String?      _type;
  List<String> _localPhotos = [];
  List<String> _webPhotoUrls = [];
  List<String> _descImages   = [];
  bool         _searchingCoords = false;
  bool         _searchingDesc   = false;
  bool         _searchingPhotos = false;
  String?      _coordsStatus;

  static const _types = [
    ('📍', 'poi',        "Point d'intérêt"),
    ('🏨', 'hotel',      'Hôtel'),
    ('🍽️', 'restaurant', 'Restaurant'),
    ('🏛️', 'monument',   'Monument'),
    ('⛰️', 'peak',       'Sommet'),
    ('💧', 'waterfall',  'Cascade'),
    ('🏰', 'castle',     'Château'),
    ('🖼️', 'museum',     'Musée'),
    ('🏘️', 'village',    'Village'),
    ('🏙️', 'city',       'Ville'),
    ('⛪', 'chapel',     'Chapelle'),
    ('🅿️', 'parking',    'Parking'),
    ('⛽', 'fuel',       'Station'),
    ('🌊', 'lake',       'Lac'),
    ('🌲', 'forest',     'Forêt'),
  ];

  @override
  void initState() {
    super.initState();
    _nameC = TextEditingController(text: widget.poi.name);
    _latC  = TextEditingController(text: widget.poi.lat.toStringAsFixed(6));
    _lonC  = TextEditingController(text: widget.poi.lon.toStringAsFixed(6));
    _descC = TextEditingController(text: widget.poi.description ?? '');
    _type  = widget.poi.type;
    _localPhotos  = List.from(widget.poi.localPhotos);
    _webPhotoUrls = List.from(widget.poi.photoUrls);
    _descImages   = _extractImagesFromDesc(widget.poi.description ?? '');
  }

  @override
  void dispose() {
    _nameC.dispose(); _latC.dispose();
    _lonC.dispose();  _descC.dispose();
    super.dispose();
  }

  // ── Images dans la description ────────────────────────────────────────────
  List<String> _extractImagesFromDesc(String desc) {
    final imgs = <String>[];
    final re = RegExp(r'\[img:([^\]]+)\]');
    for (final m in re.allMatches(desc)) {
      imgs.add(m.group(1)!);
    }
    return imgs;
  }

  void _syncDescImages() {
    final base = _descC.text.replaceAll(RegExp(r'\n?\[img:[^\]]+\]'), '').trimRight();
    final tags  = _descImages.map((u) => '[img:$u]').join('\n');
    _descC.text = tags.isEmpty ? base : '$base\n$tags';
  }

  Future<void> _pasteImageUrl() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Presse-papiers vide'),
            duration: Duration(seconds: 1)));
      return;
    }
    final isImg = text.startsWith('http') &&
        (text.contains('.jpg') || text.contains('.jpeg') ||
         text.contains('.png') || text.contains('.webp') ||
         text.contains('.gif') || text.contains('imgur') ||
         text.contains('wikimedia') || text.contains('upload'));
    if (isImg && !_descImages.contains(text)) {
      setState(() { _descImages.add(text); _syncDescImages(); });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Image ajoutée'), backgroundColor: Colors.teal,
        duration: Duration(seconds: 1)));
    } else {
      final pos = _descC.selection.baseOffset;
      final cur = _descC.text;
      setState(() {
        _descC.text = pos >= 0 && pos <= cur.length
            ? cur.substring(0, pos) + text + cur.substring(pos)
            : cur + (cur.isEmpty ? '' : '\n') + text;
      });
    }
  }

  Future<void> _insertLink() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('URL image'),
        content: TextField(controller: ctrl, autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://...', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Ajouter')),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    setState(() { if (!_descImages.contains(url)) _descImages.add(url); _syncDescImages(); });
  }

  // ── Recherche champs (mêmes recherches que l'édition POI via blog/IA) ──────
  Future<void> _searchCoords() async {
    final q = _nameC.text.trim().isEmpty ? widget.poi.name : _nameC.text.trim();
    setState(() { _searchingCoords = true; _coordsStatus = 'Recherche…'; });
    try {
      final results = await PoiFieldSearch.searchCoords(q);
      if (!mounted) return;
      if (results.isEmpty) {
        setState(() => _coordsStatus = '❌ Aucun résultat pour "$q"');
        return;
      }
      final picked = await PoiFieldSearch.pickCoordsDialog(context, results);
      if (picked != null && mounted) {
        setState(() {
          _latC.text = picked.lat.toStringAsFixed(6);
          _lonC.text = picked.lon.toStringAsFixed(6);
          _coordsStatus = '✅ ${picked.display.split(',').first}';
        });
      } else if (mounted) {
        setState(() => _coordsStatus = null);
      }
    } catch (e) {
      if (mounted) setState(() => _coordsStatus = '❌ Erreur : $e');
    } finally {
      if (mounted) setState(() => _searchingCoords = false);
    }
  }

  Future<void> _searchDescriptionField() async {
    final q = _nameC.text.trim().isEmpty ? widget.poi.name : _nameC.text.trim();
    setState(() => _searchingDesc = true);
    try {
      final extract = await PoiFieldSearch.searchDescription(q);
      if (extract != null) {
        if (!mounted) return;
        final choice = await PoiFieldSearch.confirmDescriptionDialog(context, extract);
        if (choice == 'replace' && mounted) setState(() => _descC.text = extract);
        if (choice == 'append'  && mounted) {
          setState(() => _descC.text = '${_descC.text}\n$extract'.trim());
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Aucun résumé Wikipedia pour "$q"'),
          backgroundColor: Colors.orange));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Erreur Wikipedia : $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _searchingDesc = false);
    }
  }

  Future<void> _searchPhotosField() async {
    final q = _nameC.text.trim().isEmpty ? widget.poi.name : _nameC.text.trim();
    setState(() => _searchingPhotos = true);
    try {
      final urls = await PoiFieldSearch.searchPhotos(q);
      if (urls.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Aucune image trouvée pour "$q"'),
            backgroundColor: Colors.orange));
        return;
      }
      if (!mounted) return;
      final picked = await PoiFieldSearch.pickPhotosDialog(context, urls, q);
      if (picked.isNotEmpty && mounted) {
        setState(() {
          for (final u in picked) {
            if (!_webPhotoUrls.contains(u)) _webPhotoUrls.add(u);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _searchingPhotos = false);
    }
  }

  // ── Recherche web ─────────────────────────────────────────────────────────
  Future<void> _openWebSearch() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => PoiWebSearchScreen(
        poiName: _nameC.text.isNotEmpty ? _nameC.text : widget.poi.name,
        lat: double.tryParse(_latC.text) ?? widget.poi.lat,
        lon: double.tryParse(_lonC.text) ?? widget.poi.lon,
      )),
    );
    if (result == null || !mounted) return;
    // Photos téléchargées localement
    final locals = (result['localPhotos'] as List?)?.cast<String>() ?? [];
    for (final p in locals) {
      if (!_localPhotos.contains(p)) setState(() => _localPhotos.add(p));
    }
    // Photos URL
    final urls = (result['photoUrls'] as List?)?.cast<String>() ?? [];
    for (final u in urls) {
      if (!_webPhotoUrls.contains(u)) setState(() => _webPhotoUrls.add(u));
    }
    final desc = result['description'] as String?;
    if (desc != null && desc.isNotEmpty) {
      if (_descC.text.isEmpty) {
        setState(() => _descC.text = desc);
      } else {
        final ok = await showDialog<bool>(context: context,
          builder: (_) => AlertDialog(
            title: const Text('Remplacer la description ?'),
            content: Text(desc, maxLines: 4, overflow: TextOverflow.ellipsis),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false),
                  child: const Text('Non')),
              FilledButton(onPressed: () => Navigator.pop(context, true),
                  child: const Text('Oui')),
            ],
          ));
        if (ok == true && mounted) setState(() => _descC.text = desc);
      }
    }
  }

  // ── Photos galerie / caméra ───────────────────────────────────────────────
  Future<void> _addPhoto(bool fromCamera) async {
    if (fromCamera && (Platform.isAndroid || Platform.isIOS)) {
      // Caméra uniquement sur mobile — file_picker ne supporte pas la caméra
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image, withData: false);
      if (result == null || result.files.isEmpty) return;
      final path = result.files.first.path;
      if (path != null) setState(() => _localPhotos.add(path));
    } else {
      // Galerie / fichier image — toutes plateformes
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image, allowMultiple: true, withData: false);
      if (result == null) return;
      final paths = result.files
          .where((f) => f.path != null).map((f) => f.path!).toList();
      if (paths.isNotEmpty) setState(() => _localPhotos.addAll(paths));
    }
  }

  void _removePhoto(String path) =>
      setState(() => _localPhotos.remove(path));

  // ── Sauvegarder ───────────────────────────────────────────────────────────
  void _save() {
    final lat = double.tryParse(_latC.text);
    final lon = double.tryParse(_lonC.text);
    if (lat == null || lon == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Coordonnées invalides')));
      return;
    }
    Navigator.pop(context, PoiPoint(
      name:        _nameC.text.trim(),
      lat:         lat, lon: lon,
      description: _descC.text.trim().isEmpty ? null : _descC.text.trim(),
      type:        _type,
      localPhotos: _localPhotos,
      photoUrls:   _webPhotoUrls,
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: widget.color,
        foregroundColor: Colors.white,
        title: Text(_nameC.text.isEmpty ? 'Nouveau POI' : _nameC.text,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [IconButton(icon: const Icon(Icons.check), onPressed: _save)],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // Nom
          TextField(controller: _nameC,
            decoration: const InputDecoration(
              labelText: 'Nom', prefixIcon: Icon(Icons.label),
              border: OutlineInputBorder()),
            onChanged: (_) => setState(() {})),
          const SizedBox(height: 12),

          // Coordonnées
          Row(children: [
            const Text('Coordonnées',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const Spacer(),
            PoiFieldSearch.searchButton(
              icon: Icons.search,
              tooltip: 'Rechercher via Nominatim',
              loading: _searchingCoords,
              onTap: _searchCoords,
            ),
          ]),
          const SizedBox(height: 4),
          if (_coordsStatus != null)
            Padding(padding: const EdgeInsets.only(bottom: 4),
              child: Text(_coordsStatus!,
                  style: TextStyle(fontSize: 11,
                      color: _coordsStatus!.startsWith('✅')
                          ? Colors.green : Colors.orange))),
          Row(children: [
            Expanded(child: TextField(controller: _latC,
              decoration: const InputDecoration(
                labelText: 'Latitude', border: OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _lonC,
              decoration: const InputDecoration(
                labelText: 'Longitude', border: OutlineInputBorder()),
              keyboardType: const TextInputType.numberWithOptions(
                  decimal: true, signed: true))),
          ]),
          const SizedBox(height: 12),

          // Type
          const Text('Type :', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6,
            children: _types.map((t) => FilterChip(
              label: Text('${t.$1} ${t.$3}',
                  style: const TextStyle(fontSize: 11)),
              selected: _type == t.$2,
              onSelected: (_) => setState(() => _type = t.$2),
              selectedColor: widget.color.withOpacity(0.2),
              checkmarkColor: widget.color,
            )).toList()),
          const SizedBox(height: 12),

          // Description
          Row(children: [
            const Text('Description / notes',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const Spacer(),
            PoiFieldSearch.searchButton(
              icon: Icons.auto_stories,
              tooltip: 'Chercher sur Wikipedia',
              loading: _searchingDesc,
              onTap: _searchDescriptionField,
            ),
            const SizedBox(width: 4),
            PoiFieldSearch.searchButton(
              icon: Icons.image_search,
              tooltip: 'Rechercher des photos (DDG + Wikimedia)',
              loading: _searchingPhotos,
              onTap: _searchPhotosField,
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.travel_explore, color: Colors.purple, size: 20),
              tooltip: 'Rechercher sur le web',
              onPressed: _openWebSearch),
            IconButton(
              icon: const Icon(Icons.content_paste, color: Colors.teal, size: 20),
              tooltip: "Coller une URL image",
              onPressed: _pasteImageUrl),
            IconButton(
              icon: const Icon(Icons.link, color: Colors.blue, size: 20),
              tooltip: 'Insérer une URL image',
              onPressed: _insertLink),
          ]),
          const SizedBox(height: 4),

          // Prévisualisation images collées
          if (_descImages.isNotEmpty) ...[
            SizedBox(
              height: 80,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _descImages.length,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (_, i) => Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(_descImages[i],
                      width: 80, height: 80, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 80, height: 80,
                        color: Colors.grey.shade200,
                        child: const Icon(Icons.broken_image, color: Colors.grey)))),
                  Positioned(top: 2, right: 2,
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _descImages.removeAt(i); _syncDescImages(); }),
                      child: Container(
                        decoration: const BoxDecoration(
                            color: Colors.red, shape: BoxShape.circle),
                        child: const Icon(Icons.close,
                            color: Colors.white, size: 14)))),
                ]),
              ),
            ),
            const SizedBox(height: 6),
          ],

          TextField(
            controller: _descC,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: 'Notes, informations...',
              border: OutlineInputBorder(),
              alignLabelWithHint: true),
          ),
          const SizedBox(height: 16),

          // Photos
          Row(children: [
            const Text('Photos',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.photo_library, color: Colors.blue),
              tooltip: 'Galerie',
              onPressed: () => _addPhoto(false)),
            if (Platform.isAndroid || Platform.isIOS)
              IconButton(
                icon: const Icon(Icons.camera_alt, color: Colors.green),
                tooltip: 'Appareil photo',
                onPressed: () => _addPhoto(true)),
          ]),

          if (_localPhotos.isEmpty && _webPhotoUrls.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300)),
              child: Column(children: [
                Icon(Icons.add_photo_alternate,
                    size: 40, color: Colors.grey.shade400),
                const SizedBox(height: 8),
                Text('Galerie, appareil photo ou recherche web 🌐',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
              ]),
            ),

          if (_localPhotos.isNotEmpty) _buildPhotoGrid(_localPhotos, local: true),

          if (_webPhotoUrls.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Photos web (${_webPhotoUrls.length})',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 6),
            _buildPhotoGrid(_webPhotoUrls, local: false),
          ],

          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('Enregistrer'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              backgroundColor: widget.color)),
        ]),
      ),
    );
  }

  Widget _buildPhotoGrid(List<String> paths, {required bool local}) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: paths.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3, crossAxisSpacing: 6, mainAxisSpacing: 6),
      itemBuilder: (context, i) {
        final path = paths[i];
        return GestureDetector(
          onTap: () => _showFullPhoto(path, local: local),
          onLongPress: local ? () => _removePhoto(path) : null,
          child: Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: local
                  ? Image.file(File(path), fit: BoxFit.cover,
                      width: double.infinity, height: double.infinity,
                      errorBuilder: (_, __, ___) => _photoError())
                  : Image.network(path, fit: BoxFit.cover,
                      width: double.infinity, height: double.infinity,
                      errorBuilder: (_, __, ___) => _photoError()),
            ),
            if (local)
              Positioned(top: 2, right: 2,
                child: GestureDetector(
                  onTap: () => _removePhoto(path),
                  child: Container(
                    decoration: const BoxDecoration(
                        color: Colors.red, shape: BoxShape.circle),
                    child: const Icon(Icons.close, color: Colors.white, size: 14)))),
          ]),
        );
      },
    );
  }

  Widget _photoError() => Container(
    color: Colors.grey.shade200,
    child: const Icon(Icons.broken_image, color: Colors.grey));

  void _showFullPhoto(String path, {required bool local}) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(child: InteractiveViewer(
        child: local ? Image.file(File(path)) : Image.network(path))),
    )));
  }
}
