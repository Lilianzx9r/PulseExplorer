/// Navigation engine lifecycle.
enum NavigationEngineState {created,initializing,initialized,starting,running,paused,stopping,stopped,disposed,failed}
extension NavigationEngineStateX on NavigationEngineState{
bool get isRunning=>this==NavigationEngineState.running;
bool get isTerminal=>this==NavigationEngineState.disposed||this==NavigationEngineState.failed;
}
