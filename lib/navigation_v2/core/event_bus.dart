import 'dart:async';
class EventBus{
final _c=StreamController<Object>.broadcast();
Stream<T> on<T>()=>_c.stream.where((e)=>e is T).cast<T>();
void fire(Object e)=>_c.add(e);
void dispose()=>_c.close();
}