import 'agent_definition.dart';

/// Catalogue des agents thématiques prévus par l'architecture cible.
/// Chaque agent est fourni avec un provider/modèle par défaut (OpenRouter
/// gratuit) afin de rester utilisable sans configuration supplémentaire ;
/// l'utilisateur peut ensuite réassigner un autre provider par agent depuis
/// le Laboratoire IA.
class AgentPresets {
  static const String _defaultProvider = 'openrouter';
  static const String _defaultModel = 'openrouter/free';

  static const List<AgentDefinition> all = [
    AgentDefinition(
      id: 'moto',
      name: 'Agent Moto',
      description: 'Routes panoramiques, cols, lacets et intérêt du parcours à moto.',
      role: 'voyage à moto',
      instructions:
          'Recherche routes panoramiques, cols, lacets et étapes présentant un fort intérêt de conduite à moto. '
          'Signale la qualité de revêtement connue et le trafic probable si l\'information existe. '
          'Évite de recommander des routes réputées dangereuses ou en travaux sans le préciser.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'nature',
      name: 'Agent Nature',
      description: 'Belvédères, gorges, cascades, lacs, points de vue, randonnées courtes.',
      role: 'nature et paysages',
      instructions:
          'Recherche belvédères, gorges, cascades, lacs et points de vue accessibles depuis la route '
          'ou après une courte marche (moins de 30 minutes).',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'patrimoine',
      name: 'Agent Patrimoine',
      description: 'Villages, architecture, monuments, sites historiques.',
      role: 'patrimoine et villages remarquables',
      instructions:
          'Recherche villages remarquables, architecture locale, monuments et sites historiques '
          'représentatifs de la région demandée.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'photographie',
      name: 'Agent Photographie',
      description: 'Spots photo, meilleure lumière, points de vue remarquables.',
      role: 'photographie de paysage et de voyage',
      instructions:
          'Recherche des spots photo remarquables (paysages, panoramas, architecture). '
          'Indique si possible le meilleur moment de la journée pour la lumière.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'gastronomie',
      name: 'Agent Gastronomie',
      description: 'Spécialités locales, marchés, producteurs, tables réputées.',
      role: 'gastronomie locale',
      instructions:
          'Recherche spécialités culinaires locales, marchés, producteurs et adresses réputées, '
          'en lien avec le territoire demandé.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'randonnee',
      name: 'Agent Randonnée',
      description: 'Sentiers courts à moyens, dénivelé, durée, difficulté.',
      role: 'randonnée pédestre',
      instructions:
          'Recherche des sentiers de randonnée courts à moyens accessibles depuis les étapes du '
          'voyage, avec durée et difficulté estimées si connues.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'unesco',
      name: 'Agent UNESCO',
      description: 'Sites classés ou candidats au patrimoine mondial UNESCO.',
      role: 'patrimoine mondial UNESCO',
      instructions:
          'Recherche spécifiquement les sites classés ou candidats au patrimoine mondial UNESCO '
          'situés dans la zone demandée.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'camping',
      name: 'Agent Camping',
      description: 'Campings, aires naturelles, bivouac toléré.',
      role: 'hébergement de plein air',
      instructions:
          'Recherche campings, aires naturelles et zones où le bivouac est généralement toléré, '
          'à proximité de l\'itinéraire demandé.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'road_trip',
      name: 'Agent Road Trip',
      description: 'Boucles, étapes, logique d\'itinéraire multi-jours.',
      role: 'construction d\'itinéraire multi-jours',
      instructions:
          'Propose une logique d\'étapes cohérente pour un road trip de plusieurs jours, en '
          'tenant compte des distances raisonnables entre les points d\'intérêt identifiés.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'famille',
      name: 'Agent Famille',
      description: 'Activités et sites adaptés aux enfants, sécurité, confort.',
      role: 'voyage en famille',
      instructions:
          'Recherche des activités et sites adaptés à un voyage en famille avec enfants '
          '(sécurité, accessibilité, durée raisonnable).',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'histoire',
      name: 'Agent Histoire',
      description: 'Contexte historique des lieux, événements marquants.',
      role: 'histoire locale',
      instructions:
          'Recherche des lieux liés à des événements historiques marquants et apporte un '
          'contexte historique court et fiable.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'architecture',
      name: 'Agent Architecture',
      description: 'Bâtiments remarquables, styles architecturaux.',
      role: 'architecture remarquable',
      instructions:
          'Recherche des bâtiments et ensembles architecturaux remarquables, en précisant le '
          'style ou l\'époque si connu.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'panoramas',
      name: 'Agent Panoramas',
      description: 'Points de vue larges, tables d\'orientation, sommets accessibles.',
      role: 'panoramas et vues dégagées',
      instructions:
          'Recherche des points de vue larges, tables d\'orientation et sommets facilement '
          'accessibles offrant un panorama remarquable.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'insolite',
      name: 'Agent Insolite',
      description: 'Curiosités, lieux atypiques, anecdotes locales.',
      role: 'lieux insolites',
      instructions:
          'Recherche des curiosités et lieux atypiques, moins connus du grand public, avec une '
          'courte anecdote si elle est fiable.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
    AgentDefinition(
      id: 'local',
      name: 'Agent Local',
      description: 'Recommandations type "bons plans" de résidents locaux.',
      role: 'bons plans locaux',
      instructions:
          'Recherche des recommandations qui reflètent les bons plans habituellement partagés '
          'par les habitants plutôt que les lieux uniquement touristiques.',
      providerId: _defaultProvider,
      model: _defaultModel,
    ),
  ];
}
