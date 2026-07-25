import 'package:flutter/material.dart';
import 'gpx_track.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'elevation_3d_screen.dart';
import 'elevation_api_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Panel principal
// ─────────────────────────────────────────────────────────────────────────────
class LayersPanel extends StatefulWidget {
  final List<GpxTrack>  tracks;
  final List<PoiLayer>  poiLayers;
  final List<PoiFolder> poiFolders;
  final VoidCallback    onChanged;
  final void Function(BuildContext ctx, PoiPoint poi, PoiLayer layer)? onPoiMenu;
  /// Affiche le profil altimétrique 2D EN INCRUSTATION sur la carte (voir
  /// route_elevation_profile.dart), en plus de la vue 3D plein écran.
  final ValueChanged<GpxTrack>? onShowMapProfile;

  const LayersPanel({
    super.key,
    required this.tracks,
    required this.poiLayers,
    required this.poiFolders,
    required this.onChanged,
    this.onPoiMenu,
    this.onShowMapProfile,
  });

  @override
  State<LayersPanel> createState() => _LayersPanelState();
}

class _LayersPanelState extends State<LayersPanel>
    with SingleTickerProviderStateMixin {

  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // En-tête
        Container(
          decoration: const BoxDecoration(
            color: Color(0xFF003580),
            borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
          ),
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                const Icon(Icons.layers, color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Expanded(child: Text(
                  '${widget.tracks.length} GPX  •  ${_totalPoi} POI',
                  style: const TextStyle(color: Colors.white,
                      fontWeight: FontWeight.bold, fontSize: 12),
                )),
                _hdrBtn(Icons.visibility,     'Tout afficher', _showAll),
                _hdrBtn(Icons.visibility_off, 'Tout masquer',  _hideAll),
              ]),
            ),
            TabBar(
              controller: _tabs,
              indicatorColor: Colors.white,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              tabs: [
                Tab(text: '🥾 GPX (${widget.tracks.length})'),
                Tab(text: '📍 POI (${_totalPoi})'),
              ],
            ),
          ]),
        ),

        Flexible(
          child: TabBarView(
            controller: _tabs,
            children: [
              _GpxTab(
                tracks:    widget.tracks,
                onChanged: () { widget.onChanged(); setState(() {}); },
                onShowMapProfile: widget.onShowMapProfile,
              ),
              _PoiTab(
                rootLayers: widget.poiLayers,
                folders:    widget.poiFolders,
                onChanged:  () { widget.onChanged(); setState(() {}); },
                onPoiMenu:  widget.onPoiMenu,
              ),
            ],
          ),
        ),
      ]),
    );
  }

  int get _totalPoi {
    int n = widget.poiLayers.fold(0, (s, l) => s + l.points.length);
    for (final f in widget.poiFolders) {
      n += f.layers.fold(0, (s, l) => s + l.points.length);
    }
    return n;
  }

  void _showAll() {
    for (final t in widget.tracks)    t.visible = true;
    for (final l in widget.poiLayers) l.visible = true;
    for (final f in widget.poiFolders) {
      f.visible = true;
      for (final l in f.layers) l.visible = true;
    }
    widget.onChanged(); setState(() {});
  }

  void _hideAll() {
    for (final t in widget.tracks)    t.visible = false;
    for (final l in widget.poiLayers) l.visible = false;
    for (final f in widget.poiFolders) {
      f.visible = false;
      for (final l in f.layers) l.visible = false;
    }
    widget.onChanged(); setState(() {});
  }

  Widget _hdrBtn(IconData icon, String tip, VoidCallback fn) => IconButton(
    icon: Icon(icon, color: Colors.white70, size: 18),
    tooltip: tip, padding: EdgeInsets.zero,
    constraints: const BoxConstraints(), onPressed: fn,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Onglet GPX
// ─────────────────────────────────────────────────────────────────────────────
class _GpxTab extends StatefulWidget {
  final List<GpxTrack> tracks;
  final VoidCallback   onChanged;
  final ValueChanged<GpxTrack>? onShowMapProfile;
  const _GpxTab({required this.tracks, required this.onChanged, this.onShowMapProfile});
  @override State<_GpxTab> createState() => _GpxTabState();
}

class _GpxTabState extends State<_GpxTab> {
  @override
  Widget build(BuildContext context) {
    if (widget.tracks.isEmpty) return _empty('Aucun tracé GPX chargé');
    return ReorderableListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: widget.tracks.length,
      proxyDecorator: _proxy,
      onReorder: (oldIdx, newIdx) {
        if (newIdx > oldIdx) newIdx--;
        final t = widget.tracks.removeAt(oldIdx);
        widget.tracks.insert(newIdx, t);
        widget.onChanged();
        setState(() {});
      },
      itemBuilder: (ctx, i) {
        final t = widget.tracks[i];
        return _GpxRow(
          key: ValueKey('gpx_${t.hashCode}_$i'),
          track: t,
          onToggle: () { t.visible = !t.visible; widget.onChanged(); setState(() {}); },
          onRemove: () async {
            final ok = await _confirmDelete(context,
              'Supprimer le tracé ?',
              '« ${t.displayName} » sera retiré de la session.');
            if (!ok) return;
            widget.tracks.removeAt(i); widget.onChanged(); setState(() {});
          },
          onShow3DProfile: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => Elevation3DScreen(track: t))),
          onShowMapProfile: widget.onShowMapProfile == null
              ? null : () => widget.onShowMapProfile!(t),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Onglet POI — drag & drop entre dossiers + visibilité dossiers
// ─────────────────────────────────────────────────────────────────────────────

/// Représente un élément de la liste plate
sealed class _Item {
  String get key;
  bool get draggable;
}

class _RootLayerItem implements _Item {
  final PoiLayer layer;
  _RootLayerItem(this.layer);
  @override String get key => 'root__${layer.id}';
  @override bool   get draggable => true;
}

class _FolderItem implements _Item {
  final PoiFolder folder;
  _FolderItem(this.folder);
  @override String get key => 'folder__${folder.id}';
  @override bool   get draggable => true;
}

class _FolderLayerItem implements _Item {
  final PoiFolder folder;
  final PoiLayer  layer;
  _FolderLayerItem(this.folder, this.layer);
  @override String get key => 'fl__${folder.id}__${layer.id}';
  @override bool   get draggable => true;
}

class _EmptyFolderItem implements _Item {
  final PoiFolder folder;
  _EmptyFolderItem(this.folder);
  @override String get key => 'empty__${folder.id}';
  @override bool   get draggable => false;
}

class _PoiTab extends StatefulWidget {
  final List<PoiLayer>  rootLayers;
  final List<PoiFolder> folders;
  final VoidCallback    onChanged;
  final void Function(BuildContext ctx, PoiPoint poi, PoiLayer layer)? onPoiMenu;

  const _PoiTab({
    required this.rootLayers,
    required this.folders,
    required this.onChanged,
    this.onPoiMenu,
  });

  @override State<_PoiTab> createState() => _PoiTabState();
}

class _PoiTabState extends State<_PoiTab> {

  List<_Item> _buildItems() {
    final items = <_Item>[];

    // Couches racine (sans dossier)
    for (final l in widget.rootLayers) {
      items.add(_RootLayerItem(l));
    }

    // Dossiers
    for (final folder in widget.folders) {
      items.add(_FolderItem(folder));
      if (folder.expanded) {
        if (folder.layers.isEmpty) {
          items.add(_EmptyFolderItem(folder));
        } else {
          for (final l in folder.layers) {
            items.add(_FolderLayerItem(folder, l));
          }
        }
      }
    }

    return items;
  }

  // ── Drag & drop ──────────────────────────────────────────────────────────
  void _handleReorder(List<_Item> items, int oldIdx, int newIdx) {
    if (newIdx > oldIdx) newIdx--;

    final moved  = items[oldIdx];
    final target = newIdx < items.length ? items[newIdx] : null;

    if (!moved.draggable) return;

    // ── Couche racine déplacée ──
    if (moved is _RootLayerItem) {
      final l = moved.layer;
      widget.rootLayers.remove(l);

      if (target is _FolderItem) {
        // Dépôt sur dossier → dans ce dossier
        target.folder.layers.insert(0, l);
      } else if (target is _FolderLayerItem) {
        // Dépôt sur couche dans dossier → dans ce dossier
        final idx = target.folder.layers.indexOf(target.layer);
        target.folder.layers.insert(idx < 0 ? 0 : idx, l);
      } else if (target is _RootLayerItem) {
        // Réordonner dans racine
        final idx = widget.rootLayers.indexOf(target.layer);
        widget.rootLayers.insert(idx < 0 ? 0 : idx, l);
      } else {
        // Fin de liste
        widget.rootLayers.add(l);
      }

    // ── Couche dans dossier déplacée ──
    } else if (moved is _FolderLayerItem) {
      final srcFolder = moved.folder;
      final l = moved.layer;
      srcFolder.layers.remove(l);

      if (target is _FolderItem) {
        if (target.folder.id == srcFolder.id) {
          // Même dossier — remettre en tête
          srcFolder.layers.insert(0, l);
        } else {
          target.folder.layers.insert(0, l);
        }
      } else if (target is _FolderLayerItem) {
        if (target.folder.id == srcFolder.id) {
          // Même dossier — réordonner
          final idx = srcFolder.layers.indexOf(target.layer);
          srcFolder.layers.insert(idx < 0 ? 0 : idx, l);
        } else {
          // Autre dossier
          final idx = target.folder.layers.indexOf(target.layer);
          target.folder.layers.insert(idx < 0 ? 0 : idx, l);
        }
      } else if (target is _RootLayerItem) {
        // Vers racine
        final idx = widget.rootLayers.indexOf(target.layer);
        widget.rootLayers.insert(idx < 0 ? 0 : idx, l);
      } else if (target is _EmptyFolderItem) {
        target.folder.layers.add(l);
      } else {
        // Fin de liste ou dossier fermé → racine
        widget.rootLayers.add(l);
      }

    // ── Dossier déplacé ──
    } else if (moved is _FolderItem) {
      final folder = moved.folder;
      widget.folders.remove(folder);

      if (target is _FolderItem) {
        final idx = widget.folders.indexOf(target.folder);
        widget.folders.insert(idx < 0 ? 0 : idx, folder);
      } else {
        widget.folders.add(folder);
      }
    }

    widget.onChanged();
    setState(() {});
  }

  // ── Créer un nouveau dossier ──────────────────────────────────────────────
  Future<void> _newFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nouveau dossier'),
        content: TextField(controller: ctrl, autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Nom', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('Créer')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      widget.folders.add(PoiFolder(label: name, layers: [], expanded: true));
      widget.onChanged();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _buildItems();

    if (items.isEmpty) return _empty('Aucun POI chargé');

    return Column(children: [
      // Bouton nouveau dossier
      Padding(
        padding: const EdgeInsets.all(6),
        child: OutlinedButton.icon(
          onPressed: _newFolder,
          icon: const Icon(Icons.create_new_folder, size: 16),
          label: const Text('Nouveau dossier', style: TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(double.infinity, 36),
            foregroundColor: Colors.amber.shade700,
          ),
        ),
      ),
      Flexible(
        child: ReorderableListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          proxyDecorator: _proxy,
          itemCount: items.length,
          onReorder: (o, n) => _handleReorder(items, o, n),
          itemBuilder: (ctx, i) {
            final item = items[i];
            return KeyedSubtree(
              key: ValueKey(item.key),
              child: _buildTile(item),
            );
          },
        ),
      ),
    ]);
  }

  Widget _buildTile(_Item item) {
    if (item is _RootLayerItem) {
      return _PoiLayerRow(
        layer: item.layer,
        indent: 0,
        targetFolders: widget.folders,
        onToggle: () {
          item.layer.visible = !item.layer.visible;
          widget.onChanged(); setState(() {});
        },
        onRemove: () async {
            final ok = await _confirmDelete(context,
              'Supprimer la couche ?',
              '« ${item.layer.label} » (${item.layer.points.length} POI) sera supprimée.');
            if (!ok) return;
            widget.rootLayers.remove(item.layer);
            widget.onChanged(); setState(() {});
          },
        onMoveToFolder: (folder) {
          widget.rootLayers.remove(item.layer);
          folder.layers.add(item.layer);
          widget.onChanged(); setState(() {});
        },
        onPoiMenu: widget.onPoiMenu,
      );
    }

    if (item is _FolderItem) {
      final folder = item.folder;
      return _FolderRow(
        folder: folder,
        onToggleExpand: () {
          folder.expanded = !folder.expanded;
          widget.onChanged(); setState(() {});
        },
        onToggleVisible: () {
          folder.visible = !folder.visible;
          for (final l in folder.layers) l.visible = folder.visible;
          widget.onChanged(); setState(() {});
        },
        onRemove: () async {
          final ok = await _confirmDelete(context,
            'Supprimer le dossier ?',
            '« ${folder.label} » sera supprimé. Ses ${folder.layers.length} couche(s) seront déplacées hors dossier.');
          if (!ok) return;
          widget.rootLayers.addAll(folder.layers);
          widget.folders.remove(folder);
          widget.onChanged(); setState(() {});
        },
      );
    }

    if (item is _FolderLayerItem) {
      final folder = item.folder;
      final layer  = item.layer;
      final otherFolders = widget.folders.where((f) => f.id != folder.id).toList();
      return _PoiLayerRow(
        layer: layer,
        indent: 20.0,
        targetFolders: otherFolders,
        onToggle: () {
          layer.visible = !layer.visible;
          widget.onChanged(); setState(() {});
        },
        onRemove: () async {
          final ok = await _confirmDelete(context,
            'Supprimer la couche ?',
            '« ${layer.label} » (${layer.points.length} POI) sera supprimée du dossier « ${folder.label} ».');
          if (!ok) return;
          folder.layers.remove(layer);
          widget.onChanged(); setState(() {});
        },
        onMoveToFolder: (target) {
          folder.layers.remove(layer);
          target.layers.add(layer);
          widget.onChanged(); setState(() {});
        },
        onMoveToRoot: () {
          folder.layers.remove(layer);
          widget.rootLayers.add(layer);
          widget.onChanged(); setState(() {});
        },
        onPoiMenu: widget.onPoiMenu,
      );
    }

    if (item is _EmptyFolderItem) {
      return Container(
        key: ValueKey(item.key),
        margin: const EdgeInsets.only(left: 32, right: 8, top: 2, bottom: 2),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: const Text('Dossier vide — déposez des couches ici',
            style: TextStyle(fontSize: 11, color: Colors.grey),
            textAlign: TextAlign.center),
      );
    }

    return const SizedBox.shrink();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets de lignes
// ─────────────────────────────────────────────────────────────────────────────

/// Propose de récupérer l'altitude d'un tracé via l'API OpenTopoData
/// (gratuite, sans clé) quand le GPX ne contient pas de données <ele>.
Future<void> _offerElevationFetch(
    BuildContext context, GpxTrack track, VoidCallback onDone) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Récupérer l\'altitude ?'),
      content: Text(
          'Le tracé « ${track.displayName} » ne contient pas de données '
          'd\'altitude. Les récupérer depuis OpenTopoData '
          '(modèle de terrain SRTM, gratuit, sans compte) ?\n\n'
          '${track.data.trackPoints.length} points — l\'opération peut '
          'prendre quelques secondes.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(context, true),
            child: const Text('Récupérer')),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  String status = 'Démarrage…';
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => StatefulBuilder(builder: (dialogCtx, setDlg) {
      // Lancer la récupération une seule fois
      Future.microtask(() async {
        final enriched = await ElevationApiService.enrichTrackElevation(
          track.data,
          onStatus: (s) { status = s; if (dialogCtx.mounted) setDlg(() {}); },
        );
        track.data = enriched;
        if (dialogCtx.mounted) Navigator.pop(dialogCtx);
      });
      return AlertDialog(
        content: Row(children: [
          const SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 16),
          Expanded(child: Text(status, style: const TextStyle(fontSize: 13))),
        ]),
      );
    }),
  );

  if (!context.mounted) return;
  final hasEleNow = track.data.trackPoints.any((p) => p.ele != null && p.ele!.isFinite);
  if (hasEleNow) {
    onDone();
  } else {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('❌ Impossible de récupérer l\'altitude (service indisponible ou zone non couverte)'),
      backgroundColor: Colors.red));
  }
}

class _GpxRow extends StatelessWidget {
  final GpxTrack     track;
  final VoidCallback onToggle;
  final Future<void> Function() onRemove;
  final VoidCallback? onShow3DProfile;
  final VoidCallback? onShowMapProfile;
  const _GpxRow({super.key, required this.track,
      required this.onToggle, required this.onRemove, this.onShow3DProfile,
      this.onShowMapProfile});

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: track.visible ? 1.0 : 0.45,
    child: ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 8, right: 4),
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.drag_handle, size: 16, color: Colors.grey),
        const SizedBox(width: 4),
        Container(width: 14, height: 14,
          decoration: BoxDecoration(color: track.color, shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5))),
      ]),
      title: Text(track.displayName,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis),
      subtitle: Text('${track.data.trackPoints.length} pts'
          '${track.data.waypoints.isNotEmpty ? " • ${track.data.waypoints.length} wpts" : ""}',
          style: const TextStyle(fontSize: 10)),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (onShow3DProfile != null) ...[
          Builder(builder: (context) {
            final hasEle = track.data.trackPoints
                .any((p) => p.ele != null && p.ele!.isFinite);
            return IconButton(
              icon: Icon(Icons.terrain, size: 18,
                  color: hasEle ? Colors.deepOrange : Colors.grey.shade400),
              tooltip: hasEle
                  ? 'Profil altimétrique 3D'
                  : 'Récupérer l\'altitude (aucune donnée dans ce GPX)',
              onPressed: hasEle ? onShow3DProfile
                  : () => _offerElevationFetch(context, track, onShow3DProfile!),
              padding: EdgeInsets.zero, constraints: const BoxConstraints());
          }),
        ],
        if (onShowMapProfile != null)
          Builder(builder: (context) {
            final hasEle = track.data.trackPoints
                .any((p) => p.ele != null && p.ele!.isFinite);
            return IconButton(
              icon: Icon(Icons.show_chart, size: 18,
                  color: hasEle ? Colors.deepOrange : Colors.grey.shade400),
              tooltip: hasEle
                  ? 'Afficher le profil sur la carte'
                  : 'Récupérer l\'altitude (aucune donnée dans ce GPX)',
              onPressed: hasEle ? onShowMapProfile
                  : () => _offerElevationFetch(context, track, onShowMapProfile!),
              padding: EdgeInsets.zero, constraints: const BoxConstraints());
          }),
        _rowActions(onToggle, track.visible, onRemove),
      ]),
    ),
  );
}

class _FolderRow extends StatelessWidget {
  final PoiFolder    folder;
  final VoidCallback onToggleExpand;
  final VoidCallback onToggleVisible;
  final Future<void> Function() onRemove;

  const _FolderRow({super.key, required this.folder,
      required this.onToggleExpand, required this.onToggleVisible,
      required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final total = folder.layers.fold<int>(0, (s, l) => s + l.points.length);
    return Opacity(
      opacity: folder.visible ? 1.0 : 0.45,
      child: Container(
        color: Colors.amber.withOpacity(0.06),
        child: ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 8, right: 4),
          leading: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.drag_handle, size: 16, color: Colors.grey),
            const SizedBox(width: 2),
            // Tap sur l'icône dossier pour expand/collapse
            GestureDetector(
              onTap: onToggleExpand,
              child: Icon(
                folder.expanded ? Icons.folder_open : Icons.folder,
                color: Colors.amber.shade700, size: 20),
            ),
          ]),
          title: GestureDetector(
            onTap: onToggleExpand,
            child: Text(folder.label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis),
          ),
          subtitle: Text(
            '${folder.layers.length} couche${folder.layers.length != 1 ? "s" : ""} • $total POI',
            style: const TextStyle(fontSize: 10)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            // Bouton expand/collapse explicite
            IconButton(
              icon: Icon(
                folder.expanded ? Icons.expand_less : Icons.expand_more,
                size: 18, color: Colors.amber.shade700),
              onPressed: onToggleExpand,
              tooltip: folder.expanded ? 'Réduire' : 'Déployer',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints()),
            // Bouton visibilité carte
            IconButton(
              icon: Icon(
                folder.visible ? Icons.visibility : Icons.visibility_off,
                size: 16,
                color: folder.visible ? Colors.blue : Colors.grey),
              onPressed: onToggleVisible,
              tooltip: folder.visible ? 'Masquer sur la carte' : 'Afficher sur la carte',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints()),
            // Bouton supprimer
            IconButton(
              icon: const Icon(Icons.close, size: 14, color: Colors.red),
              onPressed: onRemove,
              tooltip: 'Supprimer le dossier (couches conservées)',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints()),
            const SizedBox(width: 2),
          ]),
        ),
      ),
    );
  }
}

class _PoiLayerRow extends StatelessWidget {
  final PoiLayer         layer;
  final double           indent;
  final List<PoiFolder>  targetFolders;
  final VoidCallback     onToggle;
  final Future<void> Function()     onRemove;
  final void Function(PoiFolder) onMoveToFolder;
  final VoidCallback?    onMoveToRoot;
  final void Function(BuildContext ctx, PoiPoint poi, PoiLayer layer)? onPoiMenu;

  const _PoiLayerRow({super.key,
      required this.layer, required this.indent,
      required this.targetFolders, required this.onToggle,
      required this.onRemove, required this.onMoveToFolder,
      this.onMoveToRoot, this.onPoiMenu});

  @override
  Widget build(BuildContext context) {
    final hasMoveTargets = targetFolders.isNotEmpty || onMoveToRoot != null;
    final leading = Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.drag_handle, size: 16, color: Colors.grey),
      const SizedBox(width: 4),
      Container(width: 12, height: 12,
        decoration: BoxDecoration(color: layer.color, shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5))),
    ]);
    final trailing = Row(mainAxisSize: MainAxisSize.min, children: [
      if (hasMoveTargets)
        _MoveButton(layer: layer, targetFolders: targetFolders,
            onMoveToFolder: onMoveToFolder, onMoveToRoot: onMoveToRoot),
      _rowActions(onToggle, layer.visible, onRemove),
    ]);

    if (onPoiMenu != null && layer.points.isNotEmpty) {
      return Opacity(
        opacity: layer.visible ? 1.0 : 0.45,
        child: ExpansionTile(
          tilePadding: EdgeInsets.only(left: 8 + indent, right: 4),
          leading: leading,
          title: Text(layer.label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis),
          subtitle: Text('${layer.points.length} POI',
              style: const TextStyle(fontSize: 10)),
          trailing: trailing,
          children: layer.points.map((poi) => ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: EdgeInsets.only(left: 24.0 + indent, right: 0),
            leading: Text(_poiEmoji(poi.type),
                style: const TextStyle(fontSize: 15)),
            title: Text(poi.name,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis),
            subtitle: poi.description != null && poi.description!.isNotEmpty
                ? Text(poi.description!,
                    style: const TextStyle(fontSize: 9, color: Colors.grey),
                    maxLines: 1, overflow: TextOverflow.ellipsis)
                : Text('${poi.lat.toStringAsFixed(4)}, ${poi.lon.toStringAsFixed(4)}',
                    style: const TextStyle(fontSize: 9, color: Colors.grey)),
            trailing: SizedBox(
              width: 40,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(40, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => onPoiMenu?.call(context, poi, layer),
                child: const Icon(Icons.more_vert, size: 18, color: Colors.blueGrey),
              ),
            ),
          )).toList(),
        ),
      );
    }

    return Opacity(
      opacity: layer.visible ? 1.0 : 0.45,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: 8 + indent, right: 4),
        leading: leading,
        title: Text(layer.label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            overflow: TextOverflow.ellipsis),
        subtitle: Text('${layer.points.length} POI',
            style: const TextStyle(fontSize: 10)),
        trailing: trailing,
      ),
    );
  }

  String _poiEmoji(String? type) {
    const map = {
      'hotel': '🏨', 'restaurant': '🍽️', 'monument': '🏛️', 'peak': '⛰️',
      'waterfall': '💧', 'castle': '🏰', 'museum': '🖼️', 'village': '🏘️',
      'city': '🏙️', 'chapel': '⛪', 'parking': '🅿️', 'fuel': '⛽',
      'lake': '🌊', 'forest': '🌲', 'viewpoint': '🔭', 'camping': '⛺',
      'attraction': '🎡', 'ruins': '🏚️', 'cafe': '☕', 'cave': '🕳️',
    };
    return map[type] ?? '📍';
  }
}

class _MoveButton extends StatelessWidget {
  final PoiLayer         layer;
  final List<PoiFolder>  targetFolders;
  final void Function(PoiFolder) onMoveToFolder;
  final VoidCallback?    onMoveToRoot;

  const _MoveButton({required this.layer, required this.targetFolders,
      required this.onMoveToFolder, this.onMoveToRoot});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<dynamic>(
      icon: const Icon(Icons.drive_file_move_outlined, size: 16, color: Colors.blue),
      tooltip: 'Déplacer',
      itemBuilder: (_) => [
        if (onMoveToRoot != null)
          const PopupMenuItem(value: '__root__',
            child: Row(children: [
              Icon(Icons.folder_off, size: 16, color: Colors.grey),
              SizedBox(width: 8), Text('Sans dossier'),
            ])),
        ...targetFolders.map((f) => PopupMenuItem(value: f,
          child: Row(children: [
            Icon(Icons.folder, size: 16, color: Colors.amber.shade700),
            const SizedBox(width: 8), Text(f.label),
          ]))),
      ],
      onSelected: (v) {
        if (v == '__root__') onMoveToRoot?.call();
        else if (v is PoiFolder) onMoveToFolder(v);
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────
// Helper asynchrone de confirmation — retourne true si l'utilisateur confirme
Future<bool> _confirmDelete(BuildContext context, String title, String content) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Supprimer')),
      ],
    ),
  );
  return ok == true;
}

Widget _rowActions(VoidCallback onToggle, bool visible, Future<void> Function() onRemove) =>
  Row(mainAxisSize: MainAxisSize.min, children: [
    IconButton(
      icon: Icon(visible ? Icons.visibility : Icons.visibility_off,
          size: 16, color: visible ? Colors.blue : Colors.grey),
      onPressed: onToggle, padding: EdgeInsets.zero,
      constraints: const BoxConstraints()),
    IconButton(
      icon: const Icon(Icons.close, size: 14, color: Colors.red),
      onPressed: onRemove, padding: EdgeInsets.zero,
      constraints: const BoxConstraints()),
    const SizedBox(width: 2),
  ]);

Widget _proxy(Widget child, int index, Animation<double> animation) =>
  Material(elevation: 4, borderRadius: BorderRadius.circular(6), child: child);

Widget _empty(String msg) => Center(
  child: Padding(padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.layers_clear, size: 40, color: Colors.grey.shade300),
      const SizedBox(height: 8),
      Text(msg, style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
    ])),
);
