import 'package:flutter/material.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';

/// Écran de gestion des dossiers POI : créer, renommer, déplacer couches
class PoiFolderManager extends StatefulWidget {
  final List<PoiFolder> folders;
  final List<PoiLayer>  rootLayers;   // couches sans dossier
  final String          sessionLabel;

  const PoiFolderManager({
    super.key,
    required this.folders,
    required this.rootLayers,
    required this.sessionLabel,
  });

  @override
  State<PoiFolderManager> createState() => _PoiFolderManagerState();
}

class _PoiFolderManagerState extends State<PoiFolderManager> {

  Future<void> _createFolder() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Nouveau dossier'),
        content: TextField(controller: ctrl, autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Nom du dossier', border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Créer')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() => widget.folders.add(PoiFolder(label: name, layers: [])));
  }

  Future<void> _renameFolder(PoiFolder folder) async {
    final ctrl = TextEditingController(text: folder.label);
    final name = await showDialog<String>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Renommer'),
        content: TextField(controller: ctrl, autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) setState(() => folder.label = name);
  }

  // Déplace une couche racine vers un dossier
  Future<void> _moveLayerToFolder(PoiLayer layer) async {
    final folder = await showDialog<PoiFolder>(context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Déplacer vers un dossier'),
        children: widget.folders.map((f) => SimpleDialogOption(
          onPressed: () => Navigator.pop(context, f),
          child: Row(children: [
            Icon(Icons.folder, color: Colors.amber.shade700, size: 18),
            const SizedBox(width: 8),
            Text(f.label),
          ]),
        )).toList(),
      ),
    );
    if (folder == null) return;
    setState(() {
      widget.rootLayers.remove(layer);
      folder.layers.add(layer);
    });
  }

  // Retire une couche d'un dossier → racine
  void _moveLayerToRoot(PoiLayer layer, PoiFolder folder) {
    setState(() {
      folder.layers.remove(layer);
      widget.rootLayers.add(layer);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Dossiers POI', style: TextStyle(fontWeight: FontWeight.bold)),
          Text(widget.sessionLabel,
              style: const TextStyle(fontSize: 10, color: Colors.white70)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder),
            tooltip: 'Nouveau dossier',
            onPressed: _createFolder,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Couches sans dossier
          if (widget.rootLayers.isNotEmpty) ...[
            _sectionHeader('📂 Sans dossier (${widget.rootLayers.length})'),
            ...widget.rootLayers.map((l) => Card(
              margin: const EdgeInsets.only(bottom: 4),
              child: ListTile(
                dense: true,
                leading: Container(width: 12, height: 12,
                    decoration: BoxDecoration(color: l.color, shape: BoxShape.circle)),
                title: Text(l.label, style: const TextStyle(fontSize: 13)),
                subtitle: Text('${l.points.length} POI', style: const TextStyle(fontSize: 11)),
                trailing: widget.folders.isEmpty ? null : IconButton(
                  icon: const Icon(Icons.drive_file_move, size: 18, color: Color(0xFF003580)),
                  tooltip: 'Déplacer vers un dossier',
                  onPressed: () => _moveLayerToFolder(l),
                ),
              ),
            )),
            const SizedBox(height: 8),
          ],

          // Dossiers
          ...widget.folders.map((folder) => Card(
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: Colors.amber.shade200)),
            child: ExpansionTile(
              leading: Icon(Icons.folder_open, color: Colors.amber.shade700),
              title: Text(folder.label,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              subtitle: Text(
                '${folder.layers.length} couche${folder.layers.length > 1 ? "s" : ""}'
                '  •  ${folder.layers.fold<int>(0, (s, l) => s + l.points.length)} POI'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                // Renommer
                IconButton(
                  icon: const Icon(Icons.edit, size: 16),
                  onPressed: () => _renameFolder(folder),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 4),
                // Supprimer dossier (les couches reviennent à la racine)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                  onPressed: () async {
                    final ok = await showDialog<bool>(context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Supprimer le dossier ?'),
                        content: Text(
                          'Les ${folder.layers.length} couches seront remises à la racine.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false),
                              child: const Text('Annuler')),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Supprimer')),
                        ],
                      ));
                    if (ok == true) {
                      setState(() {
                        widget.rootLayers.addAll(folder.layers);
                        widget.folders.remove(folder);
                      });
                    }
                  },
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 4),
              ]),
              children: [
                if (folder.layers.isEmpty)
                  const Padding(padding: EdgeInsets.all(12),
                      child: Text('Dossier vide', style: TextStyle(color: Colors.grey))),
                ...folder.layers.map((l) => ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 32, right: 8),
                  leading: Container(width: 10, height: 10,
                      decoration: BoxDecoration(color: l.color, shape: BoxShape.circle)),
                  title: Text(l.label, style: const TextStyle(fontSize: 12)),
                  subtitle: Text('${l.points.length} POI',
                      style: const TextStyle(fontSize: 10)),
                  trailing: IconButton(
                    icon: const Icon(Icons.drive_file_move_rtl,
                        size: 16, color: Colors.teal),
                    tooltip: 'Sortir du dossier',
                    onPressed: () => _moveLayerToRoot(l, folder),
                    padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                  ),
                )),
              ],
            ),
          )),

          if (widget.folders.isEmpty && widget.rootLayers.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(children: [
                  Icon(Icons.folder_off, size: 48, color: Colors.grey),
                  SizedBox(height: 8),
                  Text('Aucune couche POI chargée',
                      style: TextStyle(color: Colors.grey)),
                ]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(title, style: const TextStyle(
        fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
  );
}
