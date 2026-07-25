import 'dart:io';
import 'package:flutter/material.dart';
import 'backup_service.dart';
import 'migration_service.dart';
import 'session_store.dart';
import 'poi_layer.dart';
import 'poi_folder.dart';
import 'gpx_track.dart';

class BackupScreen extends StatefulWidget {
  final List<VisuSession> sessions;
  final List<PoiLayer>    poiLayers;
  final List<PoiFolder>   poiFolders;
  final List<GpxTrack>    tracks;
  final Future<void> Function(BackupData data) onImported;

  const BackupScreen({
    super.key,
    required this.sessions,
    required this.poiLayers,
    required this.poiFolders,
    required this.tracks,
    required this.onImported,
  });

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  bool    _isSaving             = false;
  bool    _isLoading            = false;
  bool    _isMigrating          = false;
  bool?   _migrationAvailable;
  String? _lastSaved;
  String? _message;
  bool    _isError              = false;

  @override
  void initState() {
    super.initState();
    _checkMigration();
  }

  Future<void> _checkMigration() async {
    final available = await MigrationService.isAvailable();
    if (mounted) setState(() => _migrationAvailable = available);
  }

  void _show(String msg, {bool error = false}) =>
      setState(() { _message = msg; _isError = error; });

  // ── Sauvegarder ──────────────────────────────────────────────────────────
  Future<void> _save() async {
    setState(() { _isSaving = true; _message = null; });
    try {
      final path = await BackupService.save(
        context:    context,
        sessions:   widget.sessions,
        poiLayers:  widget.poiLayers,
        poiFolders: widget.poiFolders,
        tracks:     widget.tracks,
      );
      if (path != null) {
        setState(() => _lastSaved = path);
        _show('✅ Sauvegardé dans\n$path');
      } else {
        _show('Sauvegarde annulée', error: true);
      }
    } catch (e) {
      _show('Erreur : $e', error: true);
    } finally {
      setState(() => _isSaving = false);
    }
  }

  // ── Importer .pgpx ───────────────────────────────────────────────────────
  Future<void> _import() async {
    setState(() { _isLoading = true; _message = null; });
    try {
      final data = await BackupService.load(context);
      if (data == null) return;

      if (!mounted) return;

      // Prévisualisation avant d'appliquer
      final confirmed = await _showImportConfirm(data);
      if (confirmed != true) return;

      await widget.onImported(data);
      _show('✅ Importé : ${data.sessions.length} sessions, '
            '${data.poiLayers.length} couches POI, '
            '${data.poiFolders.length} dossiers, '
            '${data.tracks.length} tracé(s) GPX\n'
            '(sauvegardé le ${_fmtDate(data.savedAt)})');
    } catch (e) {
      _show('Erreur import : $e', error: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── Importer ancienne base JSON ──────────────────────────────────────────
  // ── Migration automatique depuis booking_gpx ──────────────────────────────
  Future<void> _migrate() async {
    setState(() { _isMigrating = true; _message = null; });
    try {
      final result = await MigrationService.readAll();
      if (result == null || result.isEmpty) {
        _show(
          'Impossible de lire les données de l\'ancienne app.\n'
          'Installez d\'abord booking_gpx_export (inclus dans le zip).',
          error: true);
        return;
      }

      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.swap_horiz, color: Color(0xFF003580)),
            SizedBox(width: 8),
            Text('Migration détectée'),
          ]),
          content: Text(
            'Données trouvées dans booking_gpx :\n\n'
            '${result.summary}\n\n'
            'Tout sera fusionné avec PulseGpx.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Annuler')),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Migrer')),
          ],
        ),
      );
      if (confirmed != true) return;

      final data = BackupData(
        sessions:   result.sessions,
        poiLayers:  result.poiLayers,
        poiFolders: result.poiFolders,
        tracks:     [],
        savedAt:    DateTime.now(),
        version:    'migration',
      );
      await widget.onImported(data);
      _show('✅ Migré : ${result.summary}');
    } catch (e) {
      _show('Erreur migration : $e', error: true);
    } finally {
      setState(() => _isMigrating = false);
    }
  }

  Future<void> _importLegacy() async {
    setState(() { _isLoading = true; _message = null; });
    try {
      final sessions = await BackupService.loadLegacySessions(context);
      if (sessions == null || sessions.isEmpty) return;

      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Importer ancienne base'),
          content: Text(
            '${sessions.length} session${sessions.length > 1 ? "s" : ""} trouvée${sessions.length > 1 ? "s" : ""}.\n\n'
            'Mode de fusion :'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Annuler')),
            OutlinedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Fusionner (ajouter)')),
          ],
        ),
      );
      if (confirmed != true) return;

      // Construire un BackupData avec juste les sessions
      final data = BackupData(
        sessions:   sessions,
        poiLayers:  [],
        poiFolders: [],
        tracks:     [],
        savedAt:    DateTime.now(),
        version:    'legacy',
      );
      await widget.onImported(data);
      _show('✅ ${sessions.length} sessions importées');
    } catch (e) {
      _show('Erreur : $e', error: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<bool?> _showImportConfirm(BackupData data) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.restore, color: Color(0xFF003580)),
          SizedBox(width: 8),
          Text('Confirmer l\'import'),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          _infoRow('📅', 'Sauvegardé le', _fmtDate(data.savedAt)),
          _infoRow('🗂️', 'Sessions',      '${data.sessions.length}'),
          _infoRow('🗺️', 'Tracés GPX',    '${data.tracks.length}'),
          _infoRow('📍', 'Couches POI',   '${data.poiLayers.length}'),
          _infoRow('📁', 'Dossiers',      '${data.poiFolders.length}'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: const Text(
              '⚠️ Les données seront fusionnées avec celles existantes.',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Importer')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF003580),
        foregroundColor: Colors.white,
        title: const Text('Sauvegarde & Import',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Stats actuelles ──────────────────────────────────────────────
          Card(
            color: Colors.blue.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Données actuelles',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                _statRow(Icons.history,  '${widget.sessions.length} session${widget.sessions.length > 1 ? "s" : ""}'),
                _statRow(Icons.route,    '${widget.tracks.length} tracé${widget.tracks.length > 1 ? "s" : ""} GPX'),
                _statRow(Icons.location_on, '${widget.poiLayers.length} couche${widget.poiLayers.length > 1 ? "s" : ""} POI'),
                _statRow(Icons.folder,   '${widget.poiFolders.length} dossier${widget.poiFolders.length > 1 ? "s" : ""}'),
              ]),
            ),
          ),

          const SizedBox(height: 24),

          // ── Sauvegarder ──────────────────────────────────────────────────
          _section('💾  Sauvegarder'),
          const Text(
            'Exporte toutes vos données dans un fichier .pgpx '
            '(sessions, POI, dossiers) dans Documents/PulseGpx.',
            style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: _isSaving
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_alt),
            label: Text(_isSaving ? 'Sauvegarde...' : 'Sauvegarder maintenant'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              backgroundColor: const Color(0xFF003580)),
          ),

          const SizedBox(height: 28),

          // ── Migration automatique ────────────────────────────────────────────
          if (_migrationAvailable == true) ...[
            _section('🔄  Migration depuis booking_gpx'),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Row(children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 20),
                const SizedBox(width: 8),
                const Expanded(child: Text(
                  'L\'ancienne app booking_gpx est détectée.\n'
                  'Vous pouvez importer vos sessions automatiquement.',
                  style: TextStyle(fontSize: 12))),
              ]),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _isMigrating ? null : _migrate,
              icon: _isMigrating
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.swap_horiz),
              label: Text(_isMigrating ? 'Migration...' : 'Migrer depuis booking_gpx'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                backgroundColor: Colors.green.shade700),
            ),
            const SizedBox(height: 28),
          ] else if (_migrationAvailable == false) ...[
            _section('🔄  Migration depuis booking_gpx'),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(children: [
                Icon(Icons.info_outline, color: Colors.grey, size: 18),
                SizedBox(width: 8),
                Expanded(child: Text(
                  'booking_gpx non détecté sur cet appareil.\n'
                  'Utilisez l\'import .pgpx ou .json ci-dessous.',
                  style: TextStyle(fontSize: 12, color: Colors.grey))),
              ]),
            ),
            const SizedBox(height: 28),
          ] else ...[
            _section('🔄  Migration depuis booking_gpx'),
            const LinearProgressIndicator(),
            const SizedBox(height: 28),
          ],

          // ── Importer ─────────────────────────────────────────────────────
          _section('📥  Importer'),
          const Text(
            'Restaurez depuis un fichier .pgpx ou fusionnez avec une base existante.',
            style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 10),

          // Import .pgpx
          OutlinedButton.icon(
            onPressed: _isLoading ? null : _import,
            icon: _isLoading
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.restore),
            label: const Text('Importer un fichier .pgpx'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48)),
          ),
          const SizedBox(height: 8),

          // Import ancienne base JSON
          OutlinedButton.icon(
            onPressed: _isLoading ? null : _importLegacy,
            icon: const Icon(Icons.history, color: Colors.orange),
            label: const Text('Importer une ancienne base (.json)'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              foregroundColor: Colors.orange,
              side: const BorderSide(color: Colors.orange)),
          ),

          // Message de statut
          if (_message != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isError ? Colors.red.shade50 : Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isError ? Colors.red.shade200 : Colors.green.shade200),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(_isError ? Icons.error_outline : Icons.check_circle_outline,
                    color: _isError ? Colors.red : Colors.green, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(_message!,
                    style: TextStyle(
                        fontSize: 12,
                        color: _isError ? Colors.red.shade700 : Colors.green.shade700))),
              ]),
            ),
          ],

          const SizedBox(height: 28),

          // ── Format ───────────────────────────────────────────────────────
          _section('ℹ️  Format .pgpx'),
          const Text(
            'Le fichier .pgpx est un ZIP contenant :\n'
            '  • manifest.json — version et métadonnées\n'
            '  • sessions.json — historique des sessions\n'
            '  • poi_layers.json — tous les points d\'intérêt\n'
            '  • poi_folders.json — organisation en dossiers\n'
            '  • tracks/index.json — index des tracés GPX\n\n'
            'Il peut être ouvert et inspecté avec n\'importe quel '
            'gestionnaire de fichiers ZIP.',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        ]),
      ),
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
  );

  Widget _statRow(IconData icon, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      Icon(icon, size: 16, color: Colors.blue.shade700),
      const SizedBox(width: 8),
      Text(text, style: const TextStyle(fontSize: 13)),
    ]),
  );

  Widget _infoRow(String emoji, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Text(emoji, style: const TextStyle(fontSize: 14)),
      const SizedBox(width: 8),
      Text('$label : ', style: const TextStyle(fontSize: 13, color: Colors.grey)),
      Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    ]),
  );

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2,'0')}/${d.month.toString().padLeft(2,'0')}/${d.year} '
      '${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
}
