import 'engine_event.dart';
import 'engine_event_bus.dart';
import 'engine_exception.dart';
import 'engine_registration.dart';

/// Holds the set of registered [EngineRegistration]s.
///
/// When constructed with an [EngineEventBus], registry mutations
/// (`register`/`unregister`/`clear`) are published as [EngineEvent]s so
/// that observers (see `EngineObserverRegistry`) and history recorders
/// (see `EngineHistory`) can react without polling the registry.
/// Passing no bus keeps the previous, event-free behaviour.
class EngineRegistry {
  EngineRegistry({EngineEventBus? eventBus}) : _eventBus = eventBus;

  final Map<String, EngineRegistration> _engines = {};
  final EngineEventBus? _eventBus;

  Iterable<EngineRegistration> get registrations => _engines.values;

  void register(EngineRegistration registration) {
    if (_engines.containsKey(registration.id)) {
      throw EngineAlreadyRegisteredException('Engine ${registration.id} already registered.');
    }
    _engines[registration.id] = registration;
    _publish(registration.id, EngineEventType.registered);
  }

  EngineRegistration byId(String id) {
    final r = _engines[id];
    if (r == null) {
      throw EngineNotFoundException('Engine $id not found.');
    }
    return r;
  }

  bool unregister(String id) {
    final removed = _engines.remove(id) != null;
    if (removed) {
      _publish(id, EngineEventType.unregistered);
    }
    return removed;
  }

  bool contains(String id) => _engines.containsKey(id);

  void clear() {
    final ids = _engines.keys.toList(growable: false);
    _engines.clear();
    for (final id in ids) {
      _publish(id, EngineEventType.unregistered);
    }
  }

  void _publish(String engineId, EngineEventType type) {
    _eventBus?.publish(EngineEvent(
      engineId: engineId,
      type: type,
      timestamp: DateTime.now(),
    ));
  }
}
