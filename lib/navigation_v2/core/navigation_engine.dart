import 'engine_health.dart';
import 'navigation_engine_state.dart';
abstract interface class NavigationEngine{
NavigationEngineState get state;
EngineHealthReport get health;
Future<void> initialize();
Future<void> start();
Future<void> stop();
Future<void> dispose();
}
