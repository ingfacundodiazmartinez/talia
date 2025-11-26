import 'package:flutter/material.dart';

/// Widget que muestra un grid adaptivo de videos según el número de participantes
///
/// Layout Strategy:
/// - 1 participante: Full screen
/// - 2 participantes: 2x1 vertical split (50% cada uno)
/// - 3 participantes: 2 arriba (50%), 1 abajo (100%)
/// - 4 participantes: 2x2 grid
/// - 5 participantes: 2 arriba (50%), 3 abajo (33%)
/// - 6 participantes: 2x3 grid (2 columnas, 3 filas)
/// - 7-9 participantes: 3x3 grid con celdas vacías
class VideoGridWidget extends StatelessWidget {
  final List<int> remoteUids;
  final Widget Function(int uid) remoteViewBuilder;
  final Widget? localView;
  final bool showLocalPip;
  final Function(int uid)? onParticipantTap;
  final int? pinnedUid;

  const VideoGridWidget({
    super.key,
    required this.remoteUids,
    required this.remoteViewBuilder,
    this.localView,
    this.showLocalPip = true,
    this.onParticipantTap,
    this.pinnedUid,
  });

  @override
  Widget build(BuildContext context) {
    final totalParticipants = remoteUids.length + (localView != null ? 1 : 0);

    // Si hay un video pinneado, mostrarlo en pantalla completa
    if (pinnedUid != null && remoteUids.contains(pinnedUid)) {
      return _buildPinnedLayout(context);
    }

    // Construir grid según número de participantes
    return Stack(
      children: [
        _buildGrid(context, totalParticipants),
        // PiP de video local
        if (showLocalPip && localView != null && remoteUids.isNotEmpty)
          Positioned(
            right: 16,
            bottom: 100,
            child: _buildLocalPip(context),
          ),
      ],
    );
  }

  Widget _buildPinnedLayout(BuildContext context) {
    return Stack(
      children: [
        // Video pinneado en pantalla completa
        GestureDetector(
          onTap: () => onParticipantTap?.call(pinnedUid!),
          child: remoteViewBuilder(pinnedUid!),
        ),
        // Barra de otros participantes abajo
        if (remoteUids.length > 1)
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            height: 100,
            child: _buildParticipantStrip(context),
          ),
        // PiP local
        if (showLocalPip && localView != null)
          Positioned(
            right: 16,
            top: 16,
            child: _buildLocalPip(context),
          ),
      ],
    );
  }

  Widget _buildParticipantStrip(BuildContext context) {
    final otherUids = remoteUids.where((uid) => uid != pinnedUid).toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: otherUids.length,
        itemBuilder: (context, index) {
          final uid = otherUids[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => onParticipantTap?.call(uid),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 120,
                  height: 90,
                  child: remoteViewBuilder(uid),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGrid(BuildContext context, int totalParticipants) {
    switch (remoteUids.length) {
      case 0:
        // Solo video local (pre-conexión)
        return localView ?? const SizedBox.shrink();
      case 1:
        return _buildSingleParticipant(context);
      case 2:
        return _build2Participants(context);
      case 3:
        return _build3Participants(context);
      case 4:
        return _build4Participants(context);
      case 5:
        return _build5Participants(context);
      default:
        return _build6PlusParticipants(context);
    }
  }

  /// 1 participante remoto: pantalla completa
  Widget _buildSingleParticipant(BuildContext context) {
    return GestureDetector(
      onTap: () => onParticipantTap?.call(remoteUids.first),
      child: remoteViewBuilder(remoteUids.first),
    );
  }

  /// 2 participantes remotos: división vertical 50/50
  Widget _build2Participants(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _buildVideoTile(remoteUids[0]),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: _buildVideoTile(remoteUids[1]),
        ),
      ],
    );
  }

  /// 3 participantes: 2 arriba, 1 abajo centrado
  Widget _build3Participants(BuildContext context) {
    return Column(
      children: [
        // Fila superior: 2 participantes
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildVideoTile(remoteUids[0])),
              const SizedBox(width: 2),
              Expanded(child: _buildVideoTile(remoteUids[1])),
            ],
          ),
        ),
        const SizedBox(height: 2),
        // Fila inferior: 1 participante centrado
        Expanded(
          child: _buildVideoTile(remoteUids[2]),
        ),
      ],
    );
  }

  /// 4 participantes: grid 2x2
  Widget _build4Participants(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildVideoTile(remoteUids[0])),
              const SizedBox(width: 2),
              Expanded(child: _buildVideoTile(remoteUids[1])),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildVideoTile(remoteUids[2])),
              const SizedBox(width: 2),
              Expanded(child: _buildVideoTile(remoteUids[3])),
            ],
          ),
        ),
      ],
    );
  }

  /// 5 participantes: 2 arriba, 3 abajo
  Widget _build5Participants(BuildContext context) {
    return Column(
      children: [
        // Fila superior: 2 participantes
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildVideoTile(remoteUids[0])),
              const SizedBox(width: 2),
              Expanded(child: _buildVideoTile(remoteUids[1])),
            ],
          ),
        ),
        const SizedBox(height: 2),
        // Fila inferior: 3 participantes
        Expanded(
          child: Row(
            children: [
              Expanded(child: _buildVideoTile(remoteUids[2])),
              const SizedBox(width: 2),
              Expanded(child: _buildVideoTile(remoteUids[3])),
              const SizedBox(width: 2),
              Expanded(child: _buildVideoTile(remoteUids[4])),
            ],
          ),
        ),
      ],
    );
  }

  /// 6+ participantes: grid 2x3 o scroll
  Widget _build6PlusParticipants(BuildContext context) {
    // Para 6 participantes: 2 columnas, 3 filas
    // Para 7-8: grid con celdas vacías
    // Para 9+: scroll

    if (remoteUids.length <= 6) {
      return Column(
        children: [
          // Fila 1
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildVideoTile(remoteUids[0])),
                const SizedBox(width: 2),
                Expanded(child: _buildVideoTile(remoteUids[1])),
              ],
            ),
          ),
          const SizedBox(height: 2),
          // Fila 2
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildVideoTile(remoteUids[2])),
                const SizedBox(width: 2),
                Expanded(child: _buildVideoTile(remoteUids[3])),
              ],
            ),
          ),
          const SizedBox(height: 2),
          // Fila 3
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: remoteUids.length > 4
                      ? _buildVideoTile(remoteUids[4])
                      : const SizedBox.shrink(),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: remoteUids.length > 5
                      ? _buildVideoTile(remoteUids[5])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // 7+ participantes: grid scrollable
    return GridView.builder(
      padding: const EdgeInsets.all(2),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: 3 / 4,
      ),
      itemCount: remoteUids.length,
      itemBuilder: (context, index) => _buildVideoTile(remoteUids[index]),
    );
  }

  Widget _buildVideoTile(int uid) {
    return GestureDetector(
      onTap: () => onParticipantTap?.call(uid),
      child: Container(
        color: Colors.black,
        child: remoteViewBuilder(uid),
      ),
    );
  }

  Widget _buildLocalPip(BuildContext context) {
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
        child: localView,
      ),
    );
  }
}
