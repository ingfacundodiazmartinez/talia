import 'package:flutter/material.dart';

/// Estado de un participante en la llamada
enum ParticipantState {
  connected,  // En la llamada
  ringing,    // Invitando...
  declined,   // Rechazó
  missed,     // No contestó
}

/// Información de participante para el grid
class GridParticipant {
  final String odId; // Firebase user ID
  final int? agoraUid;
  final String displayName;
  final String? photoUrl;
  final ParticipantState state;
  final bool isLocal;

  GridParticipant({
    required this.odId,
    this.agoraUid,
    required this.displayName,
    this.photoUrl,
    this.state = ParticipantState.connected,
    this.isLocal = false,
  });
}

/// Widget que muestra un grid adaptivo de videos según el número de participantes
///
/// Layout Strategy:
/// - 1 participante: Full screen con PiP local
/// - 2 participantes (1:1): Full screen remoto con PiP local
/// - 3+ participantes (grupal): Todos en grilla, sin PiP
///
/// Grid layouts para llamadas grupales:
/// - 3 participantes: 2 arriba (50%), 1 abajo (100%)
/// - 4 participantes: 2x2 grid
/// - 5 participantes: 2 arriba (50%), 3 abajo (33%)
/// - 6 participantes: 2x3 grid
/// - 7+ participantes: 3x3 grid scrollable
class VideoGridWidget extends StatelessWidget {
  /// Lista de todos los participantes (local + remotos conectados + pendientes)
  final List<GridParticipant> participants;

  /// Builder para crear el widget de video de cada participante
  final Widget Function(GridParticipant participant) participantViewBuilder;

  /// Callback cuando se toca un participante (para pin/unpin)
  final Function(GridParticipant participant)? onParticipantTap;

  /// Participante pinneado (se muestra en pantalla completa)
  final String? pinnedParticipantId;

  const VideoGridWidget({
    super.key,
    required this.participants,
    required this.participantViewBuilder,
    this.onParticipantTap,
    this.pinnedParticipantId,
  });

  @override
  Widget build(BuildContext context) {
    if (participants.isEmpty) {
      return const SizedBox.shrink();
    }

    // Separar participantes
    final localParticipant = participants.where((p) => p.isLocal).firstOrNull;
    final remoteParticipants = participants.where((p) => !p.isLocal).toList();

    // Determinar si es llamada grupal (3+ participantes totales)
    final isGroupCall = participants.length >= 3;

    // Si hay un participante pinneado, mostrar layout de pin
    if (pinnedParticipantId != null) {
      final pinnedParticipant = participants.where((p) => p.odId == pinnedParticipantId).firstOrNull;
      if (pinnedParticipant != null) {
        return _buildPinnedLayout(context, pinnedParticipant, localParticipant, isGroupCall);
      }
    }

    // Layout según número de participantes
    if (isGroupCall) {
      // Llamada grupal: todos en la grilla (incluyendo local)
      return _buildGroupGrid(context, participants);
    } else {
      // Llamada 1:1: remoto full screen + local en PiP
      return _build1to1Layout(context, remoteParticipants, localParticipant);
    }
  }

  /// Layout para llamadas 1:1: remoto full screen + PiP local
  Widget _build1to1Layout(
    BuildContext context,
    List<GridParticipant> remoteParticipants,
    GridParticipant? localParticipant,
  ) {
    if (remoteParticipants.isEmpty && localParticipant != null) {
      // Solo local (esperando que otros se conecten)
      return participantViewBuilder(localParticipant);
    }

    return Stack(
      children: [
        // Video remoto full screen
        if (remoteParticipants.isNotEmpty)
          GestureDetector(
            onTap: () => onParticipantTap?.call(remoteParticipants.first),
            child: participantViewBuilder(remoteParticipants.first),
          ),
        // PiP local
        if (localParticipant != null && remoteParticipants.isNotEmpty)
          Positioned(
            right: 16,
            bottom: 100,
            child: _buildLocalPip(context, localParticipant),
          ),
      ],
    );
  }

  /// Layout de grilla para llamadas grupales (3+ participantes)
  Widget _buildGroupGrid(BuildContext context, List<GridParticipant> allParticipants) {
    final count = allParticipants.length;

    switch (count) {
      case 3:
        return _build3ParticipantsGrid(context, allParticipants);
      case 4:
        return _build4ParticipantsGrid(context, allParticipants);
      case 5:
        return _build5ParticipantsGrid(context, allParticipants);
      case 6:
        return _build6ParticipantsGrid(context, allParticipants);
      default:
        if (count > 6) {
          return _buildScrollableGrid(context, allParticipants);
        }
        // Fallback para 1-2 (no debería llegar aquí en llamada grupal)
        return _build3ParticipantsGrid(context, allParticipants);
    }
  }

  /// 3 participantes: 2 arriba, 1 abajo
  Widget _build3ParticipantsGrid(BuildContext context, List<GridParticipant> participants) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(participants[0])),
              const SizedBox(width: 2),
              Expanded(child: _buildParticipantTile(participants[1])),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: _buildParticipantTile(participants[2]),
        ),
      ],
    );
  }

  /// 4 participantes: 2x2 grid
  Widget _build4ParticipantsGrid(BuildContext context, List<GridParticipant> participants) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(participants[0])),
              const SizedBox(width: 2),
              Expanded(child: _buildParticipantTile(participants[1])),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(participants[2])),
              const SizedBox(width: 2),
              Expanded(child: _buildParticipantTile(participants[3])),
            ],
          ),
        ),
      ],
    );
  }

  /// 5 participantes: 2 arriba, 3 abajo
  Widget _build5ParticipantsGrid(BuildContext context, List<GridParticipant> participants) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(participants[0])),
              const SizedBox(width: 2),
              Expanded(child: _buildParticipantTile(participants[1])),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(participants[2])),
              const SizedBox(width: 2),
              Expanded(child: _buildParticipantTile(participants[3])),
              const SizedBox(width: 2),
              Expanded(child: _buildParticipantTile(participants[4])),
            ],
          ),
        ),
      ],
    );
  }

  /// 6 participantes: 2x3 grid
  Widget _build6ParticipantsGrid(BuildContext context, List<GridParticipant> participants) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(participants[0])),
              const SizedBox(width: 2),
              Expanded(child: _buildParticipantTile(participants[1])),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(participants[2])),
              const SizedBox(width: 2),
              Expanded(child: _buildParticipantTile(participants[3])),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildParticipantTile(participants[4])),
              const SizedBox(width: 2),
              Expanded(child: _buildParticipantTile(participants[5])),
            ],
          ),
        ),
      ],
    );
  }

  /// 7+ participantes: grid scrollable 3 columnas
  Widget _buildScrollableGrid(BuildContext context, List<GridParticipant> participants) {
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 3 / 4,
      ),
      itemCount: participants.length,
      itemBuilder: (context, index) => _buildParticipantTile(participants[index]),
    );
  }

  /// Layout cuando hay un participante pinneado
  Widget _buildPinnedLayout(
    BuildContext context,
    GridParticipant pinnedParticipant,
    GridParticipant? localParticipant,
    bool isGroupCall,
  ) {
    final otherParticipants = participants.where((p) => p.odId != pinnedParticipantId).toList();

    return Stack(
      children: [
        // Video pinneado en pantalla completa
        GestureDetector(
          onTap: () => onParticipantTap?.call(pinnedParticipant),
          child: participantViewBuilder(pinnedParticipant),
        ),
        // Barra de otros participantes abajo
        if (otherParticipants.isNotEmpty)
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            height: 100,
            child: _buildParticipantStrip(context, otherParticipants),
          ),
      ],
    );
  }

  /// Tira horizontal de participantes (para layout pinneado)
  Widget _buildParticipantStrip(BuildContext context, List<GridParticipant> participants) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: participants.length,
        itemBuilder: (context, index) {
          final participant = participants[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => onParticipantTap?.call(participant),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 120,
                  height: 90,
                  child: participantViewBuilder(participant),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Construye el tile de un participante
  Widget _buildParticipantTile(GridParticipant participant) {
    return GestureDetector(
      onTap: () => onParticipantTap?.call(participant),
      child: Container(
        color: Colors.black,
        child: participantViewBuilder(participant),
      ),
    );
  }

  /// PiP del video local (solo para llamadas 1:1)
  Widget _buildLocalPip(BuildContext context, GridParticipant localParticipant) {
    return Container(
      width: 100,
      height: 140,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: participantViewBuilder(localParticipant),
      ),
    );
  }
}

/// Widget para mostrar un participante pendiente (invitando/rechazó)
class PendingParticipantTile extends StatelessWidget {
  final GridParticipant participant;
  final VoidCallback? onRemove;

  const PendingParticipantTile({
    super.key,
    required this.participant,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isDeclined = participant.state == ParticipantState.declined;
    final isMissed = participant.state == ParticipantState.missed;
    final isRinging = participant.state == ParticipantState.ringing;

    return Container(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Avatar con animación de pulso para "ringing"
            Stack(
              alignment: Alignment.center,
              children: [
                if (isRinging)
                  _PulsingCircle(radius: 35),
                CircleAvatar(
                  radius: 30,
                  backgroundColor: isDeclined || isMissed
                      ? Colors.red.withValues(alpha: 0.3)
                      : Colors.white24,
                  child: participant.photoUrl != null
                      ? ClipOval(
                          child: Image.network(
                            participant.photoUrl!,
                            width: 60,
                            height: 60,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _buildInitials(),
                          ),
                        )
                      : _buildInitials(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Nombre
            Text(
              participant.displayName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            // Estado
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isRinging)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white70,
                    ),
                  ),
                if (isRinging) const SizedBox(width: 6),
                Text(
                  _getStatusText(),
                  style: TextStyle(
                    color: isDeclined || isMissed ? Colors.red : Colors.white70,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInitials() {
    final initials = participant.displayName.isNotEmpty
        ? participant.displayName[0].toUpperCase()
        : '?';
    return Text(
      initials,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 24,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  String _getStatusText() {
    switch (participant.state) {
      case ParticipantState.ringing:
        return 'Llamando...';
      case ParticipantState.declined:
        return 'Rechazó';
      case ParticipantState.missed:
        return 'No contestó';
      case ParticipantState.connected:
        return 'Conectado';
    }
  }
}

/// Círculo pulsante para indicar que está llamando
class _PulsingCircle extends StatefulWidget {
  final double radius;

  const _PulsingCircle({required this.radius});

  @override
  State<_PulsingCircle> createState() => _PulsingCircleState();
}

class _PulsingCircleState extends State<_PulsingCircle> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
    _animation = Tween<double>(begin: 1.0, end: 1.5).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: widget.radius * 2 * _animation.value,
          height: widget.radius * 2 * _animation.value,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.green.withValues(alpha: 0.3 * (1.5 - _animation.value)),
          ),
        );
      },
    );
  }
}
