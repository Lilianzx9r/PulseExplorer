// Smoke test minimal : vérifie que l'application démarre sans exception.
//
// L'ancien contenu de ce fichier était le test par défaut généré par
// `flutter create` (un compteur "+1" qui n'a jamais existé dans PulseGPX/
// PulseExplorer) — il ne testait donc rien de réel et ne compilait plus
// (référence à une classe `MyApp` inexistante). Remplacé par un test
// simple et honnête plutôt que corrigé cosmétiquement.
import 'package:flutter_test/flutter_test.dart';

import 'package:pulse_explorer/main.dart';

void main() {
  testWidgets('PulseExplorerApp démarre sans exception', (WidgetTester tester) async {
    await tester.pumpWidget(const PulseExplorerApp());
    // Un seul pump (pas pumpAndSettle) : l'écran d'accueil déclenche des
    // opérations async (permissions, géolocalisation, chargement de
    // session) qui ne se termineront jamais dans un test — on vérifie
    // seulement que le premier frame se construit sans lever d'exception.
    await tester.pump();
  });
}
