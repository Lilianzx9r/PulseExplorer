import '../poi_layer.dart';
import 'agent_manager.dart';
import 'agent_result.dart';
import 'discovery_agent.dart';
import 'discovery_request.dart';
import 'poi_consensus.dart';

/// Trace d'exécution d'un agent au sein d'un run d'orchestration.
class AgentExecutionLog {
  final String agentId;
  final String agentName;
  final Duration duration;
  final bool timedOut;
  final bool failed;
  final String? error;
  final int poiCount;

  const AgentExecutionLog({
    required this.agentId,
    required this.agentName,
    required this.duration,
    required this.poiCount,
    this.timedOut = false,
    this.failed = false,
    this.error,
  });

  @override
  String toString() {
    final status = timedOut
        ? 'TIMEOUT'
        : failed
            ? 'ERREUR'
            : 'OK';
    return '[$status] $agentName — ${duration.inMilliseconds}ms — $poiCount POI'
        '${error != null ? ' — $error' : ''}';
  }
}

/// Résultat complet d'un run d'orchestration : POI consensuels, logs
/// d'exécution par agent et statistiques globales.
class OrchestrationResult {
  final DiscoveryRequest request;
  final List<AgentResult> agentResults;
  final List<ConsensusPoi> pois;
  final List<AgentExecutionLog> logs;
  final Duration totalDuration;

  const OrchestrationResult({
    required this.request,
    required this.agentResults,
    required this.pois,
    required this.logs,
    required this.totalDuration,
  });

  List<PoiPoint> get points => pois.map((p) => p.point).toList();

  int get succeededCount => logs.where((l) => !l.failed && !l.timedOut).length;
  int get timedOutCount => logs.where((l) => l.timedOut).length;
  int get failedCount => logs.where((l) => l.failed).length;
}

/// Orchestre plusieurs [DiscoveryAgent] en parallèle avec :
/// - un timeout individuel par agent (un agent bloqué n'empêche pas les
///   autres de répondre) ;
/// - une journalisation systématique (durée, succès/échec/timeout) ;
/// - la fusion des résultats via la même logique de consensus que
///   [AgentManager], réutilisée ici pour ne pas dupliquer le calcul de
///   dédoublonnage.
///
/// Contrairement à [AgentManager] (conservé pour compatibilité), cette
/// classe expose des informations d'observabilité par agent, nécessaires au
/// Laboratoire IA (benchmark, historique, comparaison des runs).
class AgentOrchestrator {
  final List<DiscoveryAgent> agents;
  final Duration agentTimeout;

  const AgentOrchestrator(
    this.agents, {
    this.agentTimeout = const Duration(seconds: 45),
  });

  Future<OrchestrationResult> run(DiscoveryRequest request) async {
    final globalStopwatch = Stopwatch()..start();

    final logs = <AgentExecutionLog>[];
    final results = await Future.wait(agents.map(
      (agent) => _executeWithTimeout(agent, request, logs),
    ));

    globalStopwatch.stop();

    final manager = AgentManager(const []);
    // Réutilise la logique de fusion/consensus de AgentManager sans
    // relancer les agents (déjà exécutés ci-dessus).
    final merged = manager.mergeExternalResults(results);

    return OrchestrationResult(
      request: request,
      agentResults: results,
      pois: merged,
      logs: logs,
      totalDuration: globalStopwatch.elapsed,
    );
  }

  Future<AgentResult> _executeWithTimeout(
    DiscoveryAgent agent,
    DiscoveryRequest request,
    List<AgentExecutionLog> logs,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await agent.execute(request).timeout(agentTimeout);
      stopwatch.stop();
      logs.add(AgentExecutionLog(
        agentId: agent.id,
        agentName: agent.name,
        duration: stopwatch.elapsed,
        poiCount: result.points.length,
        failed: result.points.isEmpty && result.warnings.isNotEmpty,
        error: result.warnings.isNotEmpty ? result.warnings.join('; ') : null,
      ));
      return result;
    } on Exception catch (e) {
      stopwatch.stop();
      final isTimeout = e.toString().contains('TimeoutException');
      logs.add(AgentExecutionLog(
        agentId: agent.id,
        agentName: agent.name,
        duration: stopwatch.elapsed,
        poiCount: 0,
        timedOut: isTimeout,
        failed: !isTimeout,
        error: '$e',
      ));
      return AgentResult(
        agentId: agent.id,
        agentName: agent.name,
        points: const [],
        warnings: [
          isTimeout
              ? '${agent.name} : délai dépassé (${agentTimeout.inSeconds}s), agent ignoré.'
              : '${agent.name} : $e',
        ],
        duration: stopwatch.elapsed,
      );
    }
  }
}
