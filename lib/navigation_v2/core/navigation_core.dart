class NavigationCore {
bool initialized=false;
Future<void> initialize() async=>initialized=true;
Future<NavigationResult> start() async=>NavigationResult.success();
Future<NavigationResult> stop() async=>NavigationResult.success();
}
import 'navigation_result.dart';
