import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Centralise les dossiers de l'app, la persistance des préférences légères,
/// et la récupération dynamique des modèles OpenRouter
class AppDirs {
  AppDirs._();

  static String? _lastExportDir;
  static String? _lastImportDir;

  // ── Dossier config interne ──────────────────────────────────────────────────
  static Future<Directory> _configDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/PulseGpx/.config');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Dossier où sont copiés les fichiers de carte vectorielle (.pmtiles)
  /// importés localement — stockage privé de l'app (fonctionne sans
  /// permission supplémentaire sur Android, y compris en stockage
  /// applicatif restreint/scoped storage).
  static Future<Directory> mapsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/PulseGpx/maps');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ── Persistance clé API + modèle ───────────────────────────────────────────
  // Sérialise les écritures pour éviter les conflits d'accès concurrents sur
  // Windows (PathAccessException: file already in use).
  static Future<void>? _saveChain;

  static Future<void> saveAiPrefs({
    required String apiKey,
    required String model,
    String?         customPrompt,
    String?         editedDefaultPrompt,
    String?         lastInputText,
  }) async {
    // Chaîne chaque appel après le précédent : une seule écriture à la fois.
    final previous = _saveChain ?? Future.value();
    final completer = previous.then((_) async {
      try {
        final dir  = await _configDir();
        final file = File('${dir.path}/ai_prefs.json');
        final tmp  = File('${dir.path}/ai_prefs.json.tmp');
        await tmp.writeAsString(jsonEncode({
          'apiKey':              apiKey,
          'model':               model,
          'customPrompt':        customPrompt,
          'editedDefaultPrompt': editedDefaultPrompt,
          'lastInputText':       lastInputText,
        }));
        // Remplacement atomique — évite les écritures partielles/verrouillées
        await tmp.rename(file.path);
      } catch (_) {
        // Échec silencieux : la persistance des préférences n'est pas critique
      }
    });
    _saveChain = completer;
    return completer;
  }

  static Future<Map<String, String?>> loadAiPrefs() async {
    try {
      final dir  = await _configDir();
      final file = File('${dir.path}/ai_prefs.json');
      if (!await file.exists()) return {};
      final j = jsonDecode(await file.readAsString()) as Map;
      return {
        'apiKey':              j['apiKey']              as String?,
        'model':               j['model']               as String?,
        'customPrompt':        j['customPrompt']        as String?,
        'editedDefaultPrompt': j['editedDefaultPrompt'] as String?,
        'lastInputText':       j['lastInputText']       as String?,
      };
    } catch (_) {
      return {};
    }
  }

  // ── Persistance des réglages radars / limitations de vitesse ───────────────
  // Avant, ces réglages (visibilité de la couche, alerte radar souhaitée)
  // vivaient uniquement en mémoire dans SpeedCameraController/
  // SpeedLimitController — recréés à chaque écran (carte principale,
  // navigation), ils repartaient donc de zéro à chaque fois (l'alerte radar
  // devait être réactivée manuellement à chaque session, sans mémoire du
  // choix précédent de l'utilisateur).
  static Future<void> saveSpeedCameraPrefs({
    required bool layerEnabled, required bool alertWanted,
  }) async {
    try {
      final dir  = await _configDir();
      final file = File('${dir.path}/speed_camera_prefs.json');
      final tmp  = File('${dir.path}/speed_camera_prefs.json.tmp');
      await tmp.writeAsString(jsonEncode({
        'layerEnabled': layerEnabled, 'alertWanted': alertWanted,
      }));
      await tmp.rename(file.path);
    } catch (_) {}
  }

  static Future<({bool layerEnabled, bool alertWanted})> loadSpeedCameraPrefs() async {
    try {
      final dir  = await _configDir();
      final file = File('${dir.path}/speed_camera_prefs.json');
      if (!await file.exists()) return (layerEnabled: false, alertWanted: false);
      final j = jsonDecode(await file.readAsString()) as Map;
      return (
        layerEnabled: j['layerEnabled'] as bool? ?? false,
        alertWanted:  j['alertWanted']  as bool? ?? false,
      );
    } catch (_) {
      return (layerEnabled: false, alertWanted: false);
    }
  }

  static Future<void> saveSpeedLimitPrefs({required bool layerEnabled}) async {
    try {
      final dir  = await _configDir();
      final file = File('${dir.path}/speed_limit_prefs.json');
      final tmp  = File('${dir.path}/speed_limit_prefs.json.tmp');
      await tmp.writeAsString(jsonEncode({'layerEnabled': layerEnabled}));
      await tmp.rename(file.path);
    } catch (_) {}
  }

  static Future<bool> loadSpeedLimitPrefs() async {
    try {
      final dir  = await _configDir();
      final file = File('${dir.path}/speed_limit_prefs.json');
      if (!await file.exists()) return false;
      final j = jsonDecode(await file.readAsString()) as Map;
      return j['layerEnabled'] as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  // ── Persistance des zones de cartes pré-chargées ────────────────────────────
  // Permet de visualiser sur la carte quelles zones ont déjà été
  // téléchargées (auparavant : aucune trace conservée, impossible de savoir
  // sans re-parcourir manuellement la zone si elle était déjà en cache).
  static Future<List<Map<String, dynamic>>> loadCachedZones() async {
    try {
      final dir  = await _configDir();
      final file = File('${dir.path}/cached_zones.json');
      if (!await file.exists()) return [];
      final list = jsonDecode(await file.readAsString()) as List;
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveCachedZones(List<Map<String, dynamic>> zones) async {
    try {
      final dir  = await _configDir();
      final file = File('${dir.path}/cached_zones.json');
      final tmp  = File('${dir.path}/cached_zones.json.tmp');
      await tmp.writeAsString(jsonEncode(zones));
      await tmp.rename(file.path);
    } catch (_) {}
  }

  // ── Persistance de la source de carte vectorielle (PMTiles) ────────────────
  // Chemin du fichier .pmtiles importé localement (copié dans le dossier de
  // documents de l'app — voir importPmtilesFile ci-dessous), mémorisé pour
  // être rechargé automatiquement à chaque démarrage sans réimport.
  static Future<void> savePmtilesPath(String? path) async {
    try {
      final dir  = await _configDir();
      final file = File('${dir.path}/pmtiles_source.json');
      if (path == null) {
        if (await file.exists()) await file.delete();
        return;
      }
      final tmp  = File('${dir.path}/pmtiles_source.json.tmp');
      await tmp.writeAsString(jsonEncode({'path': path}));
      await tmp.rename(file.path);
    } catch (_) {}
  }

  static Future<String?> loadPmtilesPath() async {
    try {
      final dir  = await _configDir();
      final file = File('${dir.path}/pmtiles_source.json');
      if (!await file.exists()) return null;
      final j = jsonDecode(await file.readAsString()) as Map;
      final path = j['path'] as String?;
      // Le fichier a pu être supprimé/déplacé entre-temps (utilisateur,
      // nettoyage OS...) — dans ce cas on ne le propose pas comme source
      // valide plutôt que de planter au chargement de la carte.
      if (path != null && !(await File(path).exists())) return null;
      return path;
    } catch (_) {
      return null;
    }
  }

  // ── Récupération dynamique des modèles OpenRouter ─────────────────────────
  /// Retourne la liste des modèles gratuits disponibles sur OpenRouter.
  /// Cache en mémoire + fichier JSON (TTL 24h).
  static List<({String id, String label})>? _cachedModels;
  static DateTime? _cacheTime;

  static Future<List<({String id, String label})>> fetchOpenRouterModels({
    String? apiKey,
    bool forceRefresh = false,
  }) async {
    // Cache mémoire valide moins de 24h
    if (!forceRefresh &&
        _cachedModels != null &&
        _cacheTime != null &&
        DateTime.now().difference(_cacheTime!) < const Duration(hours: 24)) {
      return _cachedModels!;
    }

    // Cache disque
    final dir        = await _configDir();
    final cacheFile  = File('${dir.path}/openrouter_models.json');
    if (!forceRefresh && await cacheFile.exists()) {
      try {
        final age = DateTime.now().difference(
            (await cacheFile.lastModified()));
        if (age < const Duration(hours: 24)) {
          final cached = jsonDecode(await cacheFile.readAsString()) as List;
          _cachedModels = cached.map((e) => (
            id:    e['id']    as String,
            label: e['label'] as String,
          )).toList();
          _cacheTime = DateTime.now();
          return _cachedModels!;
        }
      } catch (_) {}
    }

    // Appel API OpenRouter
    try {
      final headers = <String, String>{
        'User-Agent': 'PulseGpx/1.0',
        'Accept':     'application/json',
      };
      if (apiKey != null && apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer $apiKey';
      }
      final resp = await http.get(
        Uri.parse('https://openrouter.ai/api/v1/models'),
        headers: headers,
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }

      final data   = jsonDecode(resp.body) as Map;
      final models = (data['data'] as List).cast<Map>();

      // Garder uniquement les modèles gratuits (pricing.prompt == "0")
      final free = models.where((m) {
        final pricing = m['pricing'] as Map?;
        final prompt  = pricing?['prompt']?.toString() ?? '1';
        return prompt == '0' || prompt == '0.0';
      }).toList();

      // Trier par nom
      free.sort((a, b) => (a['name'] as String? ?? '')
          .compareTo(b['name'] as String? ?? ''));

      final result = free.map((m) {
        final id    = m['id'] as String;
        final name  = (m['name'] as String? ?? id);
        // Indicateur de contexte si disponible
        final ctx   = m['context_length'] as int?;
        final label = ctx != null
            ? '$name (${(ctx / 1000).round()}k)'
            : name;
        return (id: id, label: label);
      }).toList();

      // Sauvegarder le cache disque
      await cacheFile.writeAsString(jsonEncode(
          result.map((m) => {'id': m.id, 'label': m.label}).toList()));
      _cachedModels = result;
      _cacheTime    = DateTime.now();
      return result;

    } catch (e) {
      // En cas d'erreur : retourner les modèles codés en dur comme fallback
      return _hardcodedFallback;
    }
  }

  static const _hardcodedFallback = [
    // ★★★★★ Excellent extraction POI + géolocalisation web
    (id: 'meta-llama/llama-3.3-70b-instruct:free',
     label: 'Llama 3.3 70B (Meta) ★★★★★'),
    (id: 'google/gemma-3-27b-it:free',
     label: 'Gemma 3 27B (Google) ★★★★★'),
    // ★★★★☆ Très bon, bon en français
    (id: 'mistralai/mistral-small-3.2-24b-instruct:free',
     label: 'Mistral Small 3.2 24B ★★★★☆'),
    (id: 'qwen/qwen3-235b-a22b:free',
     label: 'Qwen3 235B ★★★★☆'),
    (id: 'deepseek/deepseek-v3:free',
     label: 'DeepSeek V3 ★★★★☆'),
    // ★★★☆☆ Correct, peut halluciner les coords
    (id: 'deepseek/deepseek-r1:free',
     label: 'DeepSeek R1 ★★★☆☆'),
    (id: 'microsoft/phi-4-reasoning-plus:free',
     label: 'Phi-4 Reasoning ★★★☆☆'),
    // ★★☆☆☆ Rapide mais moins précis
    (id: 'qwen/qwen3-8b:free',
     label: 'Qwen3 8B ★★☆☆☆ (rapide)'),
    (id: 'qwen/qwen3-30b-a3b:free',
     label: 'Qwen3 30B MoE ★★★☆☆'),
    (id: 'google/gemma-3n-e4b-it:free',
     label: 'Gemma 3n 4B ★★☆☆☆ (rapide)'),
  ];

  // ── Dossiers ───────────────────────────────────────────────────────────────
  static Future<String> exportDir() async {
    if (_lastExportDir != null) return _lastExportDir!;
    if (Platform.isAndroid) {
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          final dir = Directory('${ext.path}/PulseGpx');
          if (!await dir.exists()) await dir.create(recursive: true);
          _lastExportDir = dir.path;
          return dir.path;
        }
      } catch (_) {}
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir  = Directory('${docs.path}/PulseGpx');
    if (!await dir.exists()) await dir.create(recursive: true);
    _lastExportDir = dir.path;
    return dir.path;
  }

  static Future<String> importDir() async =>
      _lastImportDir ?? await exportDir();

  static void setLastExportDir(String path) {
    _lastExportDir = path;
    _lastImportDir ??= path;
  }

  static void setLastImportDir(String path) => _lastImportDir = path;
}
