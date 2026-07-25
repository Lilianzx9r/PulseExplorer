import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'blog_poi_service.dart';
import 'poi_layer.dart';
import 'poi_field_search.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Dialog d'édition enrichi d'un BlogPoi
// — fusion doublon champ par champ avec checkboxes ordonnées
// — recherche Nominatim pour coordonnées
// — recherche DuckDuckGo + Wikimedia pour photos
// — recherche Wikipedia pour description
// ─────────────────────────────────────────────────────────────────────────────
class PoiEditDialog extends StatefulWidget {
  final BlogPoi     poi;
  final PoiPoint?   existingPoi;
  final List<PoiPoint> allExisting;
  final void Function(PoiPoint updated)? onReplaceExisting;

  const PoiEditDialog({
    super.key,
    required this.poi,
    this.existingPoi,
    required this.allExisting,
    this.onReplaceExisting,
  });

  @override
  State<PoiEditDialog> createState() => _PoiEditDialogState();
}

class _PoiEditDialogState extends State<PoiEditDialog> {
  late final TextEditingController _name, _desc, _tips, _lat, _lon;
  late String _type;
  late List<String> _photos;
  int? _fullscreenPhotoIdx;

  // États de chargement par champ
  bool _searchingCoords = false;
  bool _searchingDesc   = false;
  bool _searchingPhotos = false;
  String? _coordsStatus;

  // Résultats Nominatim (liste pour choix)
  List<NominatimResult> _coordResults = [];
  bool _showCoordResults = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.poi.name);
    _desc = TextEditingController(text: widget.poi.description);
    _tips = TextEditingController(text: widget.poi.tips ?? '');
    _lat  = TextEditingController(text: widget.poi.lat?.toStringAsFixed(6) ?? '');
    _lon  = TextEditingController(text: widget.poi.lon?.toStringAsFixed(6) ?? '');
    _type = widget.poi.type;
    _photos = [
      if (widget.poi.imageUrl != null) widget.poi.imageUrl!,
      ...?widget.existingPoi?.photoUrls,
    ];
  }

  @override
  void dispose() {
    for (final c in [_name, _desc, _tips, _lat, _lon]) c.dispose();
    super.dispose();
  }

  // ── Recherche coordonnées Nominatim ────────────────────────────────────────
  Future<void> _searchCoords() async {
    final q = _name.text.trim().isEmpty ? widget.poi.name : _name.text.trim();
    setState(() { _searchingCoords = true; _coordsStatus = 'Recherche…'; _coordResults = []; _showCoordResults = false; });
    try {
      final results = await PoiFieldSearch.searchCoords(q);
      if (results.isEmpty) {
        setState(() => _coordsStatus = '❌ Aucun résultat pour "$q"');
      } else {
        setState(() {
          _coordResults    = results;
          _showCoordResults = true;
          _coordsStatus    = '${results.length} résultat(s) — choisissez :';
        });
      }
    } catch (e) {
      setState(() => _coordsStatus = '❌ Erreur : $e');
    } finally {
      setState(() => _searchingCoords = false);
    }
  }

  void _applyCoords(NominatimResult r) {
    setState(() {
      _lat.text = r.lat.toStringAsFixed(6);
      _lon.text = r.lon.toStringAsFixed(6);
      _showCoordResults = false;
      _coordsStatus = '✅ ${r.display.split(',').first}';
    });
  }

  // ── Recherche description Wikipedia ───────────────────────────────────────
  Future<void> _searchDescription() async {
    final q = _name.text.trim().isEmpty ? widget.poi.name : _name.text.trim();
    setState(() { _searchingDesc = true; });
    try {
      final extract = await PoiFieldSearch.searchDescription(q);
      if (extract != null) {
        if (!mounted) return;
        final choice = await PoiFieldSearch.confirmDescriptionDialog(context, extract);
        if (choice == 'replace') setState(() => _desc.text = extract);
        if (choice == 'append')  setState(() => _desc.text = '${_desc.text}\n$extract'.trim());
      } else {
        if (mounted) _showSnack('Aucun résumé Wikipedia pour "$q"', Colors.orange);
      }
    } catch (e) {
      if (mounted) _showSnack('Erreur Wikipedia : $e', Colors.red);
    } finally {
      if (mounted) setState(() => _searchingDesc = false);
    }
  }

  // ── Recherche photos DuckDuckGo + Wikimedia ────────────────────────────────
  Future<void> _searchPhotos() async {
    final q = _name.text.trim().isEmpty ? widget.poi.name : _name.text.trim();
    setState(() => _searchingPhotos = true);
    try {
      final urls = await PoiFieldSearch.searchPhotos(q);
      if (urls.isEmpty) {
        if (mounted) _showSnack('Aucune image trouvée pour "$q"', Colors.orange);
        return;
      }
      if (!mounted) return;
      final picked = await PoiFieldSearch.pickPhotosDialog(context, urls, q);
      if (picked.isNotEmpty) {
        setState(() {
          for (final u in picked) {
            if (!_photos.contains(u)) _photos.insert(0, u);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _searchingPhotos = false);
    }
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg), backgroundColor: color,
      duration: const Duration(seconds: 3)));
  }

  // ── Save / Replace ─────────────────────────────────────────────────────────
  void _save() {
    widget.poi.name        = _name.text.trim().isNotEmpty ? _name.text.trim() : widget.poi.name;
    widget.poi.description = _desc.text.trim().isNotEmpty ? _desc.text.trim() : widget.poi.description;
    widget.poi.tips        = _tips.text.trim().isNotEmpty ? _tips.text.trim() : null;
    widget.poi.type        = _type;
    widget.poi.imageUrl    = _photos.isNotEmpty ? _photos.first : null;
    final nl = double.tryParse(_lat.text.trim());
    final ml = double.tryParse(_lon.text.trim());
    if (nl != null && ml != null && nl >= -90 && nl <= 90 && ml >= -180 && ml <= 180) {
      widget.poi.lat = nl; widget.poi.lon = ml;
      widget.poi.coordSource = CoordSource.manual;
    }
    if (widget.poi.name != widget.poi.duplicateName) widget.poi.isDuplicate = false;
    Navigator.pop(context, true);
  }

  void _replaceExisting() {
    if (widget.existingPoi == null || widget.onReplaceExisting == null) return;
    final nl = double.tryParse(_lat.text.trim()) ?? widget.poi.lat ?? widget.existingPoi!.lat;
    final ml = double.tryParse(_lon.text.trim()) ?? widget.poi.lon ?? widget.existingPoi!.lon;
    final updated = PoiPoint(
      name: _name.text.trim().isNotEmpty ? _name.text.trim() : widget.existingPoi!.name,
      lat: nl, lon: ml,
      description: _desc.text.trim().isNotEmpty ? _desc.text.trim() : widget.existingPoi!.description,
      type: _type, photoUrls: _photos,
    );
    widget.onReplaceExisting!(updated);
    Navigator.pop(context, false);
  }

  // ── Build principal ────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final hasExisting = widget.existingPoi != null;
    return Dialog(
      backgroundColor: const Color(0xFF16213e),
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 780),
        child: Column(children: [
          // Titre
          Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(children: [
              Icon(hasExisting ? Icons.merge_type : Icons.edit,
                  color: hasExisting ? Colors.orange : Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(
                hasExisting ? 'Modifier / Fusionner' : 'Modifier le lieu',
                style: const TextStyle(color: Colors.white,
                    fontWeight: FontWeight.bold, fontSize: 15))),
              IconButton(icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                  onPressed: () => Navigator.pop(context, false)),
            ]),
          ),

          // Corps scrollable
          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(children: [

              // Nom
              _fieldRow(
                child: _simpleField(_name, 'Nom', Icons.place),
              ),

              // Coordonnées avec recherche Nominatim
              _fieldRow(
                label: 'Coordonnées',
                actions: [
                  PoiFieldSearch.searchButton(
                    icon: Icons.search,
                    tooltip: 'Rechercher via Nominatim',
                    loading: _searchingCoords,
                    onTap: _searchCoords,
                  ),
                  PoiFieldSearch.searchButton(
                    icon: Icons.my_location,
                    tooltip: 'Copier coords actuelles',
                    onTap: () => Clipboard.setData(ClipboardData(
                        text: '${_lat.text}, ${_lon.text}')),
                  ),
                ],
                child: Column(children: [
                  Row(children: [
                    Expanded(child: _simpleField(_lat, 'Latitude', Icons.gps_fixed)),
                    const SizedBox(width: 8),
                    Expanded(child: _simpleField(_lon, 'Longitude', Icons.gps_fixed)),
                  ]),
                  if (_coordsStatus != null)
                    Padding(padding: const EdgeInsets.only(top: 4),
                      child: Text(_coordsStatus!,
                          style: TextStyle(fontSize: 10,
                              color: _coordsStatus!.startsWith('✅')
                                  ? Colors.green : Colors.orange))),
                  // Liste résultats Nominatim
                  if (_showCoordResults && _coordResults.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0a1628),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF0f3460))),
                      child: Column(children: _coordResults.map((r) =>
                        ListTile(
                          dense: true,
                          title: Text(r.display.split(',').take(3).join(', '),
                              style: const TextStyle(color: Colors.white, fontSize: 11),
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text('${r.lat.toStringAsFixed(4)}, ${r.lon.toStringAsFixed(4)} · ${r.type}',
                              style: const TextStyle(color: Colors.white38, fontSize: 9)),
                          trailing: const Icon(Icons.check, color: Colors.amber, size: 16),
                          onTap: () => _applyCoords(r),
                        )).toList()),
                    ),
                ]),
              ),

              // Description avec recherche Wikipedia
              _fieldRow(
                label: 'Description',
                actions: [
                  PoiFieldSearch.searchButton(
                    icon: Icons.auto_stories,
                    tooltip: 'Chercher sur Wikipedia',
                    loading: _searchingDesc,
                    onTap: _searchDescription,
                  ),
                ],
                child: hasExisting
                    ? _MergeField(
                        label: 'Description', icon: Icons.description,
                        ctrl: _desc, maxLines: 3,
                        options: [widget.poi.description,
                            widget.existingPoi!.description ?? '']
                            .where((v) => v.trim().isNotEmpty).toSet().toList())
                    : _simpleField(_desc, 'Description', Icons.description, maxLines: 3),
              ),

              // Tips
              _fieldRow(
                child: _simpleField(_tips, 'Conseil pratique', Icons.lightbulb_outline),
              ),

              // Type
              const SizedBox(height: 4),
              _typeDropdown(),
              const SizedBox(height: 12),

              // Photos avec recherche
              _fieldRow(
                label: 'Photos',
                actions: [
                  PoiFieldSearch.searchButton(
                    icon: Icons.image_search,
                    tooltip: 'Rechercher des images (DDG + Wikimedia)',
                    loading: _searchingPhotos,
                    onTap: _searchPhotos,
                  ),
                  PoiFieldSearch.searchButton(
                    icon: Icons.add_link,
                    tooltip: 'Ajouter une URL manuellement',
                    onTap: _addPhotoUrl,
                  ),
                ],
                child: _photosSection(),
              ),
            ]),
          )),

          // Actions
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFF0f3460)))),
            child: hasExisting
                ? Column(children: [
                    Row(children: [
                      Expanded(child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(context, false),
                        icon: const Icon(Icons.close, size: 16),
                        label: const Text('Annuler'),
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white54,
                            side: const BorderSide(color: Color(0xFF0f3460))),
                      )),
                      const SizedBox(width: 8),
                      Expanded(child: FilledButton.icon(
                        onPressed: _save,
                        icon: const Icon(Icons.add_location_alt, size: 16),
                        label: const Text('Garder les 2'),
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.deepOrange),
                      )),
                    ]),
                    const SizedBox(height: 8),
                    SizedBox(width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _replaceExisting,
                        icon: const Icon(Icons.swap_horiz, size: 16),
                        label: const Text('Remplacer le POI existant'),
                        style: FilledButton.styleFrom(backgroundColor: Colors.teal),
                      )),
                  ])
                : Row(children: [
                    Expanded(child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white54,
                          side: const BorderSide(color: Color(0xFF0f3460))),
                      child: const Text('Annuler'),
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save, size: 16),
                      label: const Text('Sauvegarder'),
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.amber, foregroundColor: Colors.black),
                    )),
                  ]),
          ),
        ]),
      ),
    );
  }

  // ── Helpers UI ─────────────────────────────────────────────────────────────

  /// Rangée avec label optionnel + boutons d'action à droite
  Widget _fieldRow({
    String? label, List<Widget> actions = const [], required Widget child,
  }) =>
    Padding(padding: const EdgeInsets.only(bottom: 10), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (label != null || actions.isNotEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              if (label != null)
                Text(label, style: const TextStyle(
                    color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w600)),
              const Spacer(),
              ...actions.map((a) => Padding(
                  padding: const EdgeInsets.only(left: 4), child: a)),
            ])),
        child,
      ]));

  Widget _simpleField(TextEditingController ctrl, String label, IconData icon,
      {int maxLines = 1}) =>
    TextField(
      controller: ctrl, maxLines: maxLines,
      style: const TextStyle(color: Colors.white, fontSize: 12),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
        prefixIcon: Icon(icon, size: 16, color: Colors.white38),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF0f3460))),
        focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: Colors.amber)),
        border: const OutlineInputBorder()),
    );

  Widget _typeDropdown() {
    const types = ['restaurant','hotel','monument','monument_religieux','palais',
        'musee','place','marche','quartier','stade','site_historique',
        'site_naturel','site_archeologique','village','port','plage','pont',
        'rue_pittoresque','point_de_vue','spot_photo','shopping','cafe','bar',
        'spectacle','experience','parc','jardin','nature','poi','autre'];
    return DropdownButtonFormField<String>(
      value: types.contains(_type) ? _type : 'poi',
      dropdownColor: const Color(0xFF0f1e3c),
      style: const TextStyle(color: Colors.white, fontSize: 12),
      decoration: const InputDecoration(
        labelText: 'Type',
        labelStyle: TextStyle(color: Colors.white54, fontSize: 12),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        enabledBorder: OutlineInputBorder(
            borderSide: BorderSide(color: Color(0xFF0f3460))),
        border: OutlineInputBorder()),
      items: types.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
      onChanged: (v) { if (v != null) setState(() => _type = v); },
    );
  }

  Widget _photosSection() => Column(children: [
    if (_photos.isEmpty)
      const Padding(padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('Aucune photo', style: TextStyle(color: Colors.white30, fontSize: 11)))
    else
      SizedBox(height: 88, child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _photos.length,
        onReorder: (old, ne) => setState(() {
          final u = _photos.removeAt(old);
          _photos.insert(ne > old ? ne - 1 : ne, u);
        }),
        itemBuilder: (ctx, i) => GestureDetector(
          key: ValueKey(_photos[i]),
          onTap: () => setState(() => _fullscreenPhotoIdx = i),
          child: Stack(children: [
            Container(width: 76, margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: i == 0 ? Colors.amber : const Color(0xFF0f3460),
                  width: i == 0 ? 2 : 1)),
              child: ClipRRect(borderRadius: BorderRadius.circular(5),
                child: Image.network(_photos[i], fit: BoxFit.cover,
                    errorBuilder: (_,__,___) => const Icon(
                        Icons.broken_image, color: Colors.white30)))),
            if (i == 0)
              Positioned(top: 2, left: 2, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: Colors.amber,
                    borderRadius: BorderRadius.circular(3)),
                child: const Text('⭐', style: TextStyle(fontSize: 8)))),
            Positioned(top: 2, right: 8, child: GestureDetector(
              onTap: () => setState(() => _photos.removeAt(i)),
              child: Container(padding: const EdgeInsets.all(2),
                decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 10, color: Colors.white)))),
          ]),
        ),
      )),
    if (_photos.isNotEmpty)
      const Padding(padding: EdgeInsets.only(top: 2),
        child: Text('Glisser pour réordonner · ⭐ = principale',
            style: TextStyle(fontSize: 9, color: Colors.white24))),
    if (_fullscreenPhotoIdx != null && _fullscreenPhotoIdx! < _photos.length)
      GestureDetector(
        onTap: () => setState(() => _fullscreenPhotoIdx = null),
        child: Container(margin: const EdgeInsets.only(top: 8), height: 180,
          width: double.infinity,
          child: ClipRRect(borderRadius: BorderRadius.circular(8),
            child: Image.network(_photos[_fullscreenPhotoIdx!], fit: BoxFit.contain,
                errorBuilder: (_,__,___) => const Icon(Icons.broken_image, color: Colors.white30))))),
  ]);

  Future<void> _addPhotoUrl() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF16213e),
        title: const Text('Ajouter une photo par URL',
            style: TextStyle(color: Colors.white, fontSize: 14)),
        content: TextField(controller: ctrl, autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 12),
          decoration: const InputDecoration(
            hintText: 'https://...', hintStyle: TextStyle(color: Colors.white30),
            border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(context, v.trim())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler', style: TextStyle(color: Colors.white54))),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: Colors.lightBlue),
            child: const Text('Ajouter')),
        ],
      ));
    if (url != null && url.isNotEmpty) setState(() => _photos.insert(0, url));
  }
}



// ─────────────────────────────────────────────────────────────────────────────
// _MergeField — champ texte avec checkboxes ordonnées pour fusionner
// ─────────────────────────────────────────────────────────────────────────────
class _MergeField extends StatefulWidget {
  final String label;
  final IconData icon;
  final TextEditingController ctrl;
  final List<String> options;
  final int maxLines;

  const _MergeField({required this.label, required this.icon,
      required this.ctrl, required this.options, this.maxLines = 1});

  @override
  State<_MergeField> createState() => _MergeFieldState();
}

class _MergeFieldState extends State<_MergeField> {
  final List<int> _checked = [];

  void _toggle(int idx) {
    setState(() {
      _checked.contains(idx) ? _checked.remove(idx) : _checked.add(idx);
      widget.ctrl.text = _checked
          .map((i) => widget.options[i])
          .join(widget.maxLines > 1 ? '\n' : ' · ');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(controller: widget.ctrl, maxLines: widget.maxLines,
        style: const TextStyle(color: Colors.white, fontSize: 12),
        decoration: InputDecoration(
          labelText: widget.label,
          labelStyle: const TextStyle(color: Colors.white54, fontSize: 12),
          prefixIcon: Icon(widget.icon, size: 16, color: Colors.white38),
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          enabledBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF0f3460))),
          focusedBorder: const OutlineInputBorder(
              borderSide: BorderSide(color: Colors.amber)),
          border: const OutlineInputBorder()),
      ),
      if (widget.options.length > 1) ...[
        const SizedBox(height: 4),
        ...widget.options.asMap().entries.map((e) {
          final checked = _checked.contains(e.key);
          return GestureDetector(
            onTap: () => _toggle(e.key),
            child: Container(
              margin: const EdgeInsets.only(bottom: 3),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: checked ? Colors.amber.withOpacity(.15) : Colors.white.withOpacity(.04),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: checked ? Colors.amber : const Color(0xFF0f3460))),
              child: Row(children: [
                if (checked)
                  Container(width: 18, height: 18, margin: const EdgeInsets.only(right: 6),
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Colors.amber, shape: BoxShape.circle),
                    child: Text('${_checked.indexOf(e.key)+1}',
                        style: const TextStyle(fontSize: 10, color: Colors.black,
                            fontWeight: FontWeight.bold)))
                else
                  const SizedBox(width: 24),
                Expanded(child: Text(
                  e.value.length > 80 ? '${e.value.substring(0,80)}…' : e.value,
                  style: TextStyle(fontSize: 10,
                    color: checked ? Colors.amber : Colors.white38,
                    fontStyle: checked ? FontStyle.normal : FontStyle.italic))),
                Icon(checked ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 16, color: checked ? Colors.amber : Colors.white30),
              ]),
            ),
          );
        }),
        const Text('☝️ Cochez dans l\'ordre pour concaténer',
            style: TextStyle(fontSize: 9, color: Colors.white24)),
      ],
    ]);
  }
}

