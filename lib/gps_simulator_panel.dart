import 'package:flutter/material.dart';
import 'gps_simulator.dart';

// ─────────────────────────────────────────────────────────────────────────────
// gps_simulator_panel.dart
//
// Widget de contrôle de la simulation GPS : play/pause, vitesse réglable,
// arrêt. Compact, flottant sur la carte.
// ─────────────────────────────────────────────────────────────────────────────

class GpsSimulatorPanel extends StatelessWidget {
  final GpsSimulator simulator;
  final VoidCallback onStop;

  const GpsSimulatorPanel({super.key, required this.simulator, required this.onStop});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: simulator,
      builder: (context, _) {
        if (!simulator.isRunning) return const SizedBox();
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF0f1e3c).withOpacity(.95),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.purpleAccent.withOpacity(.5)),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.3),
                blurRadius: 8, offset: const Offset(0, 3))],
          ),
          child: Row(children: [
            const Icon(Icons.smart_toy, size: 16, color: Colors.purpleAccent),
            const SizedBox(width: 8),
            const Text('Simulation', style: TextStyle(
                color: Colors.purpleAccent, fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(width: 10),

            // Play/Pause
            GestureDetector(
              onTap: simulator.isPaused ? simulator.resume : simulator.pause,
              child: Icon(simulator.isPaused ? Icons.play_arrow : Icons.pause,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),

            // Vitesse
            Expanded(child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                value: simulator.speedKmh, min: 5, max: 150,
                activeColor: Colors.purpleAccent, inactiveColor: Colors.white24,
                onChanged: simulator.setSpeed,
              ),
            )),
            SizedBox(width: 44, child: Text('${simulator.speedKmh.round()} km/h',
                style: const TextStyle(color: Colors.white70, fontSize: 10))),

            IconButton(
              icon: const Icon(Icons.stop_circle, color: Colors.redAccent, size: 20),
              onPressed: onStop,
              padding: EdgeInsets.zero, constraints: const BoxConstraints()),
          ]),
        );
      },
    );
  }
}

/// Bouton de lancement de simulation — à placer parmi les autres FAB
class SimulationStartButton extends StatelessWidget {
  final bool canSimulate; // ex: un itinéraire est disponible
  final VoidCallback onTap;

  const SimulationStartButton({super.key, required this.canSimulate, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: canSimulate ? 'Simuler ce trajet' : 'Aucun itinéraire à simuler',
      child: GestureDetector(
        onTap: canSimulate ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0f1e3c).withOpacity(.95),
            shape: BoxShape.circle,
            border: Border.all(
                color: canSimulate ? Colors.purpleAccent.withOpacity(.6) : Colors.white24,
                width: 1.5),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(.3),
                blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: Icon(Icons.smart_toy,
              color: canSimulate ? Colors.purpleAccent : Colors.white24, size: 20),
        ),
      ),
    );
  }
}
