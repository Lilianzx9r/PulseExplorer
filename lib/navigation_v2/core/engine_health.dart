enum EngineHealthStatus{healthy,warning,error}
class EngineHealthReport{
final EngineHealthStatus status;
final String message;
const EngineHealthReport(this.status,{this.message=""});
}
