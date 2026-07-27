import 'dart:async';
import 'engine_event.dart';
class EngineEventBus{
 final _c=StreamController<EngineEvent>.broadcast();
 Stream<EngineEvent> get stream=>_c.stream;
 void publish(EngineEvent e)=>_c.add(e);
 Future<void> dispose()=>_c.close();
}
