import 'engine_event.dart';

/// Observes lifecycle events of navigation engines.
///
/// Implementations can react to registration, start/stop, state changes
/// and errors without being coupled to [EngineRegistry] or
/// [EngineEventBus] internals.
abstract interface class EngineObserver {
  /// Called whenever an [EngineEvent] is published on the event bus.
  void onEngineEvent(EngineEvent event);
}
