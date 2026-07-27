import 'dart:async';

class SnapshotController<T> {
  final _controller = StreamController<T>.broadcast();
  T? _current;
  T? get current => _current;
  Stream<T> get stream => _controller.stream;
  void publish(T snapshot){_current=snapshot;_controller.add(snapshot);}
  Future<void> dispose()=>_controller.close();
}
