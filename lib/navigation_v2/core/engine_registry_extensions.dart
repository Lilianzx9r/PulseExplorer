import 'engine_registry.dart';
extension EngineRegistryExtensions on EngineRegistry{
 int get count=>registrations.length;
 bool get isEmpty=>count==0;
 bool get isNotEmpty=>count>0;
}
