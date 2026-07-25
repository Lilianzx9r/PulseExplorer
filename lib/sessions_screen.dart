import 'package:flutter/material.dart';
import 'session_store.dart';

class SessionsScreen extends StatefulWidget {
  final String              currentSessionId;
  final List<VisuSession>   currentSessions;

  const SessionsScreen({
    super.key,
    required this.currentSessionId,
    required this.currentSessions,
  });

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  List<VisuSession> _sessions = [];
  bool    _loading = true;
  String? _statusMsg;
  bool    _statusOk = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = await SessionStore.loadAll();
    setState(() { _sessions = s; _loading = false; });
  }

  void _showStatus(String msg, {bool ok = true}) {
    setState(() { _statusMsg = msg; _statusOk = ok; });
    Future.delayed(const Duration(seconds: 3),
        () { if (mounted) setState(() => _statusMsg = null); });
  }

  Future<void> _delete(VisuSession s) async {
    final ok = await showDialog<bool>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer la session ?'),
        content: Text('"${s.label}" sera supprimée définitivement.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ));
    if (ok != true) return;
    await SessionStore.delete(s.id);
    setState(() => _sessions.remove(s));
  }

  Future<void> _rename(VisuSession s) async {
    final ctrl = TextEditingController(text: s.label);
    final result = await showDialog<String>(context: context,
      builder: (_) => AlertDialog(
        title: const Text('Renommer la session'),
        content: TextField(controller: ctrl, autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()),
              child: const Text('OK')),
        ],
      ));
    if (result == null || result.isEmpty) return;
    s.label = result;
    await SessionStore.upsert(s);
    _load();
  }

  // ── Export vers dossier choisi ───────────────────────────────────────────
  Future<void> _exportSessions() async {
    setState(() => _loading = true);
    try {
      final path = await SessionStore.exportToFile(widget.currentSessions);
      if (path == null) {
        _showStatus('Export annulé');
      } else {
        _showStatus('Sessions exportées :\n$path');
      }
    } catch (e) {
      _showStatus('Erreur export : $e', ok: false);
    } finally {
      setState(() => _loading = false);
    }
  }

  // ── Import depuis fichier choisi ─────────────────────────────────────────
  Future<void> _importSessions() async {
    setState(() => _loading = true);
    try {
      final imported = await SessionStore.importFromFile();
      if (imported == null || imported.isEmpty) {
        _showStatus('Aucune session importée');
        setState(() => _loading = false);
        return;
      }
      // Fusionner : ne pas écraser les sessions existantes de même ID
      final existing = await SessionStore.loadAll();
      int added = 0;
      for (final s in imported) {
        if (!existing.any((e) => e.id == s.id)) {
          await SessionStore.upsert(s);
          added++;
        }
      }
      _showStatus('$added session(s) importée(s)');
      await _load();
    } catch (e) {
      _showStatus('Erreur import : $e', ok: false);
      setState(() => _loading = false);
    }
  }

  // ── Sauvegarder session courante dans dossier ─────────────────────────────
  Future<void> _exportCurrentSession() async {
    setState(() => _loading = true);
    try {
      final current = widget.currentSessions
          .where((s) => s.id == widget.currentSessionId)
          .firstOrNull;
      if (current == null) {
        _showStatus('Aucune session courante à exporter', ok: false);
        setState(() => _loading = false);
        return;
      }
      final path = await SessionStore.exportToFile([current]);
      if (path != null) _showStatus('Session exportée :\n$path');
      else _showStatus('Export annulé');
    } catch (e) {
      _showStatus('Erreur : $e', ok: false);
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: const Text('Sessions sauvegardées',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          // Menu Export/Import
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (v) {
              if (v == 'export_all')     _exportSessions();
              if (v == 'export_current') _exportCurrentSession();
              if (v == 'import')         _importSessions();
            },
            itemBuilder: (_) => [
              const PopupMenuLabel(label: 'Sauvegarde'),
              const PopupMenuItem(value: 'export_current',
                child: Row(children: [
                  Icon(Icons.save, size: 16, color: Color(0xFF003580)),
                  SizedBox(width: 8),
                  Text('Exporter session courante'),
                ])),
              const PopupMenuItem(value: 'export_all',
                child: Row(children: [
                  Icon(Icons.save_alt, size: 16, color: Color(0xFF003580)),
                  SizedBox(width: 8),
                  Text('Exporter toutes les sessions'),
                ])),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'import',
                child: Row(children: [
                  Icon(Icons.upload_file, size: 16, color: Colors.teal),
                  SizedBox(width: 8),
                  Text('Importer des sessions'),
                ])),
            ],
          ),
        ],
      ),
      body: Column(children: [
        // Barre de statut
        if (_statusMsg != null)
          Container(
            width: double.infinity,
            color: _statusOk ? Colors.green.shade50 : Colors.red.shade50,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              Icon(_statusOk ? Icons.check_circle : Icons.error,
                  color: _statusOk ? Colors.green : Colors.red, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_statusMsg!,
                  style: TextStyle(fontSize: 12,
                      color: _statusOk ? Colors.green.shade800 : Colors.red))),
            ]),
          ),

        // Boutons rapides
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('Importer', style: TextStyle(fontSize: 12)),
              onPressed: _loading ? null : _importSessions,
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.save_alt, size: 16, color: Color(0xFF003580)),
              label: const Text('Exporter tout', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF003580)),
              onPressed: _loading ? null : _exportSessions,
            )),
          ]),
        ),

        // Liste sessions
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.history, size: 48, color: Colors.grey),
                  const SizedBox(height: 8),
                  const Text('Aucune session sauvegardée',
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.upload_file, size: 16),
                    label: const Text('Importer depuis un fichier'),
                    onPressed: _importSessions,
                  ),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: _sessions.length,
                  itemBuilder: (ctx, i) {
                    final s = _sessions[i];
                    final isCurrent = s.id == widget.currentSessionId;
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      color: isCurrent ? Colors.blue.shade50 : null,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isCurrent
                              ? const Color(0xFF003580) : Colors.grey.shade300,
                          child: Text('${i+1}', style: TextStyle(
                            color: isCurrent ? Colors.white : Colors.black54,
                            fontWeight: FontWeight.bold)),
                        ),
                        title: Text(s.label,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(
                          '${s.mapSource}  •  '
                          '${s.cityName.isNotEmpty ? s.cityName : "—"}\n'
                          '${s.gpxTracksData.length} tracé(s)  •  '
                          '${s.poiLayersData.length} couche(s) POI  •  '
                          '${s.poiFoldersData.length} dossier(s)\n'
                          '${_fmtDate(s.updatedAt)}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        isThreeLine: true,
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'load')   Navigator.pop(ctx, s);
                            if (v == 'rename') _rename(s);
                            if (v == 'delete') _delete(s);
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'load',
                              child: Row(children: [
                                Icon(Icons.open_in_new, size: 16),
                                SizedBox(width: 8), Text('Charger')])),
                            const PopupMenuItem(value: 'rename',
                              child: Row(children: [
                                Icon(Icons.edit, size: 16),
                                SizedBox(width: 8), Text('Renommer')])),
                            const PopupMenuItem(value: 'delete',
                              child: Row(children: [
                                Icon(Icons.delete, size: 16, color: Colors.red),
                                SizedBox(width: 8),
                                Text('Supprimer',
                                    style: TextStyle(color: Colors.red))])),
                          ],
                        ),
                        onTap: () => Navigator.pop(ctx, s),
                      ),
                    );
                  },
                )),
      ]),
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2,'0')}/'
      '${d.month.toString().padLeft(2,'0')}/${d.year} '
      '${d.hour.toString().padLeft(2,'0')}:'
      '${d.minute.toString().padLeft(2,'0')}';
}

/// Helper widget pour label de section dans PopupMenu
class PopupMenuLabel extends PopupMenuEntry<Never> {
  final String label;
  const PopupMenuLabel({super.key, required this.label});

  @override
  double get height => 32;

  @override
  bool represents(Never? value) => false;

  @override
  State<PopupMenuLabel> createState() => _PopupMenuLabelState();
}

class _PopupMenuLabelState extends State<PopupMenuLabel> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(widget.label, style: TextStyle(
        fontSize: 11, fontWeight: FontWeight.bold,
        color: Colors.grey.shade600)),
  );
}
