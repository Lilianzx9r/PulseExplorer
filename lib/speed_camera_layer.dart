import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'speed_camera_service.dart';
import 'app_dirs.dart';

// ─────────────────────────────────────────────────────────────────────────────
// speed_camera_layer.dart
//
// Gère l'état de la couche radars : affichage statique + alerte de proximité
// active conditionnée à la juridiction détectée par GPS.
//
// Réglages (affichage de la couche, alerte souhaitée) persistés via
// AppDirs.save/loadSpeedCameraPrefs — auparavant remis à zéro à chaque
// création de contrôleur (un par écran : carte principale, navigation...).
// ─────────────────────────────────────────────────────────────────────────────

class SpeedCameraController extends ChangeNotifier {
  bool _layerEnabled = false;   // affichage de la couche (info statique)
  bool _alertWanted = false;    // préférence utilisateur, persistée
  List<SpeedCamera> cameras = [];
  String? _detectedCountry;
  RadarAlertStatus _status = RadarAlertStatus.unknown;
  SpeedCamera? _lastAlerted; // évite de réalerter en boucle sur le même radar

  bool get layerEnabled => _layerEnabled;
  bool get alertEnabled => _alertWanted && _status == RadarAlertStatus.allowed;
  String? get detectedCountry => _detectedCountry;
  RadarAlertStatus get status => _status;

  /// Charge les réglages persistés (affichage couche + préférence d'alerte).
  /// À appeler une fois à la création du contrôleur, avant tout autre appel.
  Future<void> loadPrefs() async {
    final p = await AppDirs.loadSpeedCameraPrefs();
    _layerEnabled = p.layerEnabled;
    _alertWanted = p.alertWanted;
    notifyListeners();
  }

  void setLayerEnabled(bool v) {
    _layerEnabled = v;
    notifyListeners();
    AppDirs.saveSpeedCameraPrefs(layerEnabled: v, alertWanted: _alertWanted);
  }

  /// Tente d'activer l'alerte — nécessite une vérification de juridiction
  /// préalable (voir checkJurisdiction). La préférence est persistée même
  /// si la juridiction actuelle ne l'autorise pas encore (elle s'appliquera
  /// automatiquement dès qu'un pays autorisé sera détecté).
  void setAlertEnabled(bool v) {
    _alertWanted = v;
    notifyListeners();
    AppDirs.saveSpeedCameraPrefs(layerEnabled: _layerEnabled, alertWanted: v);
  }

  /// Vérifie la juridiction actuelle à partir d'une position GPS réelle.
  /// Doit être appelé avant d'autoriser l'alerte active, et périodiquement
  /// pendant un trajet pour détecter un changement de pays.
  Future<void> checkJurisdiction(LatLng position) async {
    final code = await SpeedCameraService.detectCountryCode(position);
    final newStatus = SpeedCameraService.statusForCountry(code);
    if (code != _detectedCountry || newStatus != _status) {
      _detectedCountry = code;
      _status = newStatus;
      // Si on entre dans un pays interdit, l'alerte se coupe automatiquement
      // — et cette coupure est persistée : à la différence d'une simple
      // sortie de zone, on ne réactive pas silencieusement l'alerte au
      // prochain lancement de l'app ni au retour en zone autorisée ; il
      // faut un choix explicite de l'utilisateur (sécurité juridique).
      if (_status != RadarAlertStatus.allowed && _alertWanted) {
        _alertWanted = false;
        AppDirs.saveSpeedCameraPrefs(layerEnabled: _layerEnabled, alertWanted: false);
      }
      notifyListeners();
    }
  }

  Future<void> loadCamerasInBbox(
      double minLat, double maxLat, double minLon, double maxLon) async {
    cameras = await SpeedCameraService.fetchInBbox(minLat, maxLat, minLon, maxLon);
    notifyListeners();
  }

  /// À appeler à chaque update GPS pendant la navigation — retourne le radar
  /// à signaler si une alerte doit être déclenchée (null sinon)
  SpeedCamera? checkProximity(LatLng position, {double radiusM = 300}) {
    if (!alertEnabled) return null;
    final nearest = SpeedCameraService.nearestWithin(position, cameras, radiusM);
    if (nearest == null) {
      _lastAlerted = null;
      return null;
    }
    if (_lastAlerted?.id == nearest.id) return null; // déjà alerté
    _lastAlerted = nearest;
    return nearest;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Couche de marqueurs radar pour FlutterMap
// ─────────────────────────────────────────────────────────────────────────────
class SpeedCameraMarkerLayer extends StatelessWidget {
  final List<SpeedCamera> cameras;
  const SpeedCameraMarkerLayer({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MarkerLayer(markers: cameras.map((cam) => Marker(
      point: LatLng(cam.lat, cam.lon),
      width: 28, height: 28,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.red.shade700,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(.3),
              blurRadius: 3, offset: const Offset(0, 1))]),
        child: const Center(child: Icon(Icons.camera_alt, size: 14, color: Colors.white)),
      ),
    )).toList());
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dialog de paramétrage radars — explique la juridiction et propose l'activation
// ─────────────────────────────────────────────────────────────────────────────
class SpeedCameraSettingsDialog extends StatefulWidget {
  final SpeedCameraController controller;
  final LatLng? currentPosition;

  const SpeedCameraSettingsDialog({
    super.key, required this.controller, this.currentPosition,
  });

  @override
  State<SpeedCameraSettingsDialog> createState() => _SpeedCameraSettingsDialogState();
}

class _SpeedCameraSettingsDialogState extends State<SpeedCameraSettingsDialog> {
  bool _checking = false;

  Future<void> _checkNow() async {
    if (widget.currentPosition == null) return;
    setState(() => _checking = true);
    await widget.controller.checkJurisdiction(widget.currentPosition!);
    if (mounted) setState(() => _checking = false);
  }

  @override
  void initState() {
    super.initState();
    if (widget.currentPosition != null) _checkNow();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) {
        final status = ctrl.status;
        return AlertDialog(
          title: const Row(children: [
            Icon(Icons.camera_alt, color: Colors.red),
            SizedBox(width: 8),
            Text('Radars', style: TextStyle(fontSize: 16)),
          ]),
          content: SizedBox(width: 380, child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Affichage couche (toujours disponible)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Afficher les radars sur la carte',
                    style: TextStyle(fontSize: 13)),
                subtitle: const Text('Information statique (données OpenStreetMap)',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
                value: ctrl.layerEnabled,
                onChanged: (v) => ctrl.setLayerEnabled(v),
              ),
              const Divider(),

              // Statut juridiction
              Row(children: [
                const Icon(Icons.gavel, size: 16, color: Colors.grey),
                const SizedBox(width: 6),
                const Text('Statut légal détecté :',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const Spacer(),
                if (_checking)
                  const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                else
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: 'Revérifier',
                    onPressed: widget.currentPosition == null ? null : _checkNow,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints()),
              ]),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: switch(status) {
                    RadarAlertStatus.allowed   => Colors.green.shade50,
                    RadarAlertStatus.forbidden => Colors.red.shade50,
                    RadarAlertStatus.unknown   => Colors.orange.shade50,
                  },
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: switch(status) {
                    RadarAlertStatus.allowed   => Colors.green.shade300,
                    RadarAlertStatus.forbidden => Colors.red.shade300,
                    RadarAlertStatus.unknown   => Colors.orange.shade300,
                  }),
                ),
                child: Row(children: [
                  Icon(switch(status) {
                    RadarAlertStatus.allowed   => Icons.check_circle,
                    RadarAlertStatus.forbidden => Icons.block,
                    RadarAlertStatus.unknown   => Icons.help_outline,
                  }, size: 18, color: switch(status) {
                    RadarAlertStatus.allowed   => Colors.green,
                    RadarAlertStatus.forbidden => Colors.red,
                    RadarAlertStatus.unknown   => Colors.orange,
                  }),
                  const SizedBox(width: 8),
                  Expanded(child: Text(switch(status) {
                    RadarAlertStatus.allowed =>
                      'Pays détecté : ${ctrl.detectedCountry ?? "?"} — alerte autorisée',
                    RadarAlertStatus.forbidden =>
                      'Pays détecté : ${ctrl.detectedCountry ?? "?"} — alerte INTERDITE dans ce pays',
                    RadarAlertStatus.unknown =>
                      widget.currentPosition == null
                          ? 'Position inconnue — activez le GPS pour vérifier'
                          : 'Pays non reconnu — alerte désactivée par prudence',
                  }, style: const TextStyle(fontSize: 12))),
                ]),
              ),
              const SizedBox(height: 10),

              // Toggle alerte active
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Alerte de proximité active',
                    style: TextStyle(fontSize: 13)),
                subtitle: Text(
                    status == RadarAlertStatus.allowed
                        ? 'Notification sonore/visuelle à l\'approche d\'un radar'
                        : 'Indisponible — non autorisé dans ce pays',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                value: ctrl.alertEnabled,
                onChanged: status == RadarAlertStatus.allowed
                    ? (v) => ctrl.setAlertEnabled(v)
                    : null,
              ),

              const SizedBox(height: 8),
              Text(
                '⚠️ La réglementation varie selon les pays et peut évoluer. '
                'En cas de déplacement transfrontalier, l\'alerte se réévalue '
                'automatiquement selon la position GPS. Vérifiez la loi locale '
                'avant tout trajet — vous restez responsable du respect de la '
                'réglementation en vigueur.',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            ],
          )),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(context),
                child: const Text('Fermer')),
          ],
        );
      },
    );
  }
}

/// Bandeau d'alerte radar plein écran (à afficher temporairement sur la carte)
class SpeedCameraAlertBanner extends StatelessWidget {
  final SpeedCamera camera;
  final double distanceM;
  final VoidCallback onDismiss;

  const SpeedCameraAlertBanner({
    super.key, required this.camera, required this.distanceM, required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.shade700,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4),
            blurRadius: 10, offset: const Offset(0, 4))]),
      child: Row(children: [
        const Icon(Icons.camera_alt, color: Colors.white, size: 28),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Radar à proximité',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
          Text('${distanceM.round()} m'
              '${camera.maxSpeed != null ? " · Limite ${camera.maxSpeed} km/h" : ""}',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ])),
        GestureDetector(onTap: onDismiss,
          child: const Icon(Icons.close, color: Colors.white70, size: 20)),
      ]),
    );
  }
}
