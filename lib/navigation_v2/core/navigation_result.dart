class NavigationResult{
final bool ok; final String? message;
const NavigationResult._(this.ok,this.message);
factory NavigationResult.success([String? m])=>NavigationResult._(true,m);
factory NavigationResult.failure(String m)=>NavigationResult._(false,m);
}