import 'engine_registration.dart';
import 'engine_exception.dart';

class EngineRegistry {
  final Map<String, EngineRegistration> _engines = {};

  Iterable<EngineRegistration> get registrations => _engines.values;

  void register(EngineRegistration registration) {
    if (_engines.containsKey(registration.id)) {
      throw EngineAlreadyRegisteredException('Engine ${registration.id} already registered.');
    }
    _engines[registration.id] = registration;
  }

  EngineRegistration byId(String id) {
    final r = _engines[id];
    if (r == null) {
      throw EngineNotFoundException('Engine $id not found.');
    }
    return r;
  }

  bool unregister(String id) => _engines.remove(id) != null;

  bool contains(String id) => _engines.containsKey(id);

  void clear() => _engines.clear();
}
