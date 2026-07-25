import 'package:flutter/material.dart';
import 'gpx_track.dart';

/// Panneau latéral listant les tracés chargés avec toggle visibilité
class TrackListPanel extends StatefulWidget {
  final List<GpxTrack> tracks;
  final VoidCallback onChanged;
  final VoidCallback onClear;

  const TrackListPanel({
    super.key,
    required this.tracks,
    required this.onChanged,
    required this.onClear,
  });

  @override
  State<TrackListPanel> createState() => _TrackListPanelState();
}

class _TrackListPanelState extends State<TrackListPanel> {
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF003580),
              borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(children: [
              const Icon(Icons.layers, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Text(
                '${widget.tracks.length} tracé${widget.tracks.length > 1 ? 's' : ''}',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              // Tout afficher / masquer
              IconButton(
                icon: const Icon(Icons.visibility, color: Colors.white70, size: 18),
                tooltip: 'Tout afficher',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  for (final t in widget.tracks) t.visible = true;
                  widget.onChanged();
                  setState(() {});
                },
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.visibility_off, color: Colors.white70, size: 18),
                tooltip: 'Tout masquer',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  for (final t in widget.tracks) t.visible = false;
                  widget.onChanged();
                  setState(() {});
                },
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.delete_sweep, color: Colors.red, size: 18),
                tooltip: 'Tout supprimer',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: widget.onClear,
              ),
            ]),
          ),

          // Liste
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.tracks.length,
              itemBuilder: (context, i) {
                final t = widget.tracks[i];
                return _TrackRow(
                  track: t,
                  onToggle: () {
                    t.visible = !t.visible;
                    widget.onChanged();
                    setState(() {});
                  },
                  onRemove: () {
                    widget.tracks.removeAt(i);
                    widget.onChanged();
                    setState(() {});
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackRow extends StatelessWidget {
  final GpxTrack track;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  const _TrackRow({
    required this.track,
    required this.onToggle,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: track.visible ? 1.0 : 0.45,
      child: ListTile(
        dense: true,
        leading: Container(
          width: 14, height: 14,
          decoration: BoxDecoration(
            color: track.color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: [BoxShadow(color: track.color.withOpacity(0.4), blurRadius: 3)],
          ),
        ),
        title: Text(
          track.displayName,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${track.data.trackPoints.length} pts'
          '${track.data.waypoints.isNotEmpty ? "  •  ${track.data.waypoints.length} wpts" : ""}',
          style: const TextStyle(fontSize: 10),
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            icon: Icon(
              track.visible ? Icons.visibility : Icons.visibility_off,
              size: 16,
              color: track.visible ? Colors.blue : Colors.grey,
            ),
            onPressed: onToggle,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, size: 14, color: Colors.red),
            onPressed: onRemove,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ]),
      ),
    );
  }
}
