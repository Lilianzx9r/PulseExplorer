import 'engine_registry.dart';
import 'navigation_engine.dart';
import 'navigation_result.dart';

/// Entry point of the navigation runtime.
///
/// Orchestrates the lifecycle of every [NavigationEngine] registered in
/// its [EngineRegistry]: [initialize], [start] and [stop] are propagated
/// to all registered engines. A failure on one engine is reported through
/// the aggregated [NavigationResult] but does not prevent the other
/// engines from being processed ("best effort" semantics) — this mirrors
/// how a GPS engine failing shouldn't stop a compass or a map engine from
/// starting normally.
final class NavigationCore {
  NavigationCore({EngineRegistry? registry}) : registry = registry ?? EngineRegistry();

  /// Registry of engines orchestrated by this runtime. Register engines
  /// on it (`core.registry.register(...)`) before calling [initialize].
  final EngineRegistry registry;

  bool _initialized = false;

  /// Indicates whether [initialize] has been called at least once.
  bool get initialized => _initialized;

  /// Initializes every registered engine.
  ///
  /// The runtime is marked [initialized] regardless of individual engine
  /// failures, matching the "best effort" semantics of [start]/[stop]:
  /// failures are surfaced through the returned [NavigationResult]
  /// instead of throwing.
  Future<NavigationResult> initialize() async {
    final result = await _forEachEngine((engine) => engine.initialize());
    _initialized = true;
    return result;
  }

  /// Starts every registered engine.
  Future<NavigationResult> start() => _forEachEngine((engine) => engine.start());

  /// Stops every registered engine.
  Future<NavigationResult> stop() => _forEachEngine((engine) => engine.stop());

  Future<NavigationResult> _forEachEngine(
    Future<void> Function(NavigationEngine engine) action,
  ) async {
    final failures = <String>[];
    for (final registration in registry.registrations) {
      try {
        await action(registration.engine);
      } catch (e) {
        failures.add('${registration.id}: $e');
      }
    }
    if (failures.isEmpty) return NavigationResult.success();
    return NavigationResult.failure(failures.join('; '));
  }
}
