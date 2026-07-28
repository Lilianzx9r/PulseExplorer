import 'dart:async';

import 'engine_event.dart';
import 'engine_event_bus.dart';
import 'engine_observer.dart';

/// Manages a set of [EngineObserver]s and forwards events published on an
/// [EngineEventBus] to all of them.
///
/// The subscription to the bus is created lazily, on the first observer
/// added, and cancelled on [dispose].
class EngineObserverRegistry {
  EngineObserverRegistry(this._bus);

  final EngineEventBus _bus;
  final List<EngineObserver> _observers = [];
  StreamSubscription<EngineEvent>? _subscription;

  /// Number of currently registered observers.
  int get count => _observers.length;

  /// Adds an observer. Does nothing if it is already registered.
  void add(EngineObserver observer) {
    if (_observers.contains(observer)) return;
    _observers.add(observer);
    _subscription ??= _bus.stream.listen(_notifyAll);
  }

  /// Removes a previously added observer.
  bool remove(EngineObserver observer) => _observers.remove(observer);

  void _notifyAll(EngineEvent event) {
    for (final observer in List<EngineObserver>.from(_observers)) {
      observer.onEngineEvent(event);
    }
  }

  /// Stops listening to the event bus and clears all observers.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _observers.clear();
  }
}
