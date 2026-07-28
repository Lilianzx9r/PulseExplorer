import 'dart:async';

import 'engine_event.dart';
import 'engine_event_bus.dart';

/// Keeps a bounded, chronological record of [EngineEvent]s.
///
/// Useful for diagnostics: it lets callers inspect what happened to the
/// navigation engines over time without having to listen to the live
/// event stream from the very start.
class EngineHistory {
  EngineHistory({int maxEntries = 200}) : _maxEntries = maxEntries;

  final int _maxEntries;
  final List<EngineEvent> _entries = [];
  StreamSubscription<EngineEvent>? _subscription;

  /// Chronological list of recorded events (oldest first).
  List<EngineEvent> get entries => List.unmodifiable(_entries);

  /// Number of events currently recorded.
  int get length => _entries.length;

  /// Records a new event, evicting the oldest entry once [maxEntries] is
  /// exceeded.
  void record(EngineEvent event) {
    _entries.add(event);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
  }

  /// Subscribes to [bus] so every published [EngineEvent] is automatically
  /// recorded. Calling this again replaces the previous subscription
  /// (e.g. to attach to a different bus).
  void attach(EngineEventBus bus) {
    _subscription?.cancel();
    _subscription = bus.stream.listen(record);
  }

  /// Cancels the subscription created by [attach], if any. History already
  /// recorded is kept; use [clear] to also wipe it.
  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Returns all recorded events for a given engine, oldest first.
  List<EngineEvent> forEngine(String engineId) =>
      _entries.where((e) => e.engineId == engineId).toList(growable: false);

  /// Clears the recorded history.
  void clear() => _entries.clear();
}
