import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_definition.dart';

class AgentConfigurationStore {
  static const _agentsKey = 'pulse_explorer.agent_definitions.v1';

  Future<List<AgentDefinition>> loadAgents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_agentsKey);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => AgentDefinition.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveAgents(List<AgentDefinition> agents) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _agentsKey,
      jsonEncode(agents.map((a) => a.toJson()).toList()),
    );
  }
}
