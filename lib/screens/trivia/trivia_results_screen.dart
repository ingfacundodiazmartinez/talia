import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/trivia_results_controller.dart';
import '../../models/trivia.dart';
import 'widgets/trivia_leaderboard_widget.dart';
import 'widgets/trivia_podium_widget.dart';

/// Pantalla de resultados de trivia (dashboard del creador o ranking público)
class TriviaResultsScreen extends StatefulWidget {
  final String triviaId;
  final bool isCreator;

  const TriviaResultsScreen({
    super.key,
    required this.triviaId,
    required this.isCreator,
  });

  @override
  State<TriviaResultsScreen> createState() => _TriviaResultsScreenState();
}

class _TriviaResultsScreenState extends State<TriviaResultsScreen> {
  late final TriviaResultsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TriviaResultsController();
    _setupCallbacks();
    _controller.initialize(widget.triviaId);
  }

  void _setupCallbacks() {
    _controller.onStateChanged = (state) {
      if (mounted) setState(() {});
    };

    _controller.onTriviaChanged = (trivia) {
      if (mounted) setState(() {});
    };

    _controller.onLeaderboardChanged = (leaderboard) {
      if (mounted) setState(() {});
    };

    _controller.onMyPositionChanged = (position) {
      if (mounted) setState(() {});
    };

    _controller.onProcessingChanged = (processing) {
      if (mounted) setState(() {});
    };

    _controller.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error), backgroundColor: Colors.red),
        );
      }
    };

    _controller.onSuccess = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.green),
        );
      }
    };
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showShareDialog() {
    final url = _controller.generateShareUrl();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            const Icon(
              Icons.share_rounded,
              size: 48,
              color: Color(0xFF667eea),
            ),
            const SizedBox(height: 16),
            const Text(
              'Compartir trivia',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Comparte este link con tus amigos para que respondan tu trivia',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            // URL display
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      url,
                      style: const TextStyle(fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: url));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copiado!')),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context);
                // TODO: Integrar con share_plus
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Link copiado!')),
                );
              },
              icon: const Icon(Icons.share_rounded),
              label: const Text('Compartir'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showCloseDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cerrar trivia'),
        content: const Text(
          'Una vez cerrada, nadie más podrá responder. '
          'Los resultados se guardarán.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _controller.closeTrivia();
            },
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  void _showDeleteDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar trivia'),
        content: const Text(
          'Esta acción no se puede deshacer. '
          'Se eliminarán la trivia y todas las respuestas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              final success = await _controller.deleteTrivia();
              if (success && mounted) {
                Navigator.pop(context);
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resultados'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_rounded),
            onPressed: _showShareDialog,
          ),
          if (_controller.isCreator)
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'close':
                    _showCloseDialog();
                    break;
                  case 'share_results':
                    _controller.shareResults();
                    break;
                  case 'delete':
                    _showDeleteDialog();
                    break;
                }
              },
              itemBuilder: (context) => [
                if (_controller.canClose)
                  const PopupMenuItem(
                    value: 'close',
                    child: Row(
                      children: [
                        Icon(Icons.lock_rounded),
                        SizedBox(width: 8),
                        Text('Cerrar trivia'),
                      ],
                    ),
                  ),
                if (!_controller.hasSharedResults)
                  const PopupMenuItem(
                    value: 'share_results',
                    child: Row(
                      children: [
                        Icon(Icons.campaign_rounded),
                        SizedBox(width: 8),
                        Text('Publicar resultados'),
                      ],
                    ),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_rounded, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Eliminar', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _buildContent(),
    );
  }

  Widget _buildContent() {
    switch (_controller.state) {
      case TriviaResultsState.loading:
        return const Center(child: CircularProgressIndicator());
      case TriviaResultsState.error:
        return _buildErrorState();
      case TriviaResultsState.loaded:
        return _buildLoadedState();
    }
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 64,
            color: Colors.red.shade300,
          ),
          const SizedBox(height: 16),
          Text(
            _controller.errorMessage ?? 'Error cargando resultados',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Volver'),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadedState() {
    final trivia = _controller.trivia;
    if (trivia == null) return const SizedBox.shrink();

    return Column(
      children: [
        // Header con info de la trivia
        _buildTriviaHeader(trivia),

        // Podio
        TriviaPodiumWidget(winners: _controller.podium),

        const Divider(height: 1),

        // Leaderboard
        Expanded(
          child: TriviaLeaderboardWidget(
            entries: _controller.leaderboard,
            showHeader: true,
          ),
        ),

        // Mi posición (si participé y no estoy en el top)
        if (_controller.myPosition != null &&
            !_controller.myPosition!.isOnPodium)
          _buildMyPositionBar(),
      ],
    );
  }

  Widget _buildTriviaHeader(Trivia trivia) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF667eea), Color(0xFF764ba2)],
        ),
      ),
      child: Column(
        children: [
          Text(
            trivia.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StatusChip(trivia: trivia),
              const SizedBox(width: 12),
              Icon(
                Icons.people_rounded,
                color: Colors.white.withValues(alpha: 0.8),
                size: 18,
              ),
              const SizedBox(width: 4),
              Text(
                '${trivia.participantCount} participantes',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
          if (trivia.isActive && trivia.timeRemaining != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.timer_rounded,
                  color: Colors.white.withValues(alpha: 0.8),
                  size: 18,
                ),
                const SizedBox(width: 4),
                Text(
                  'Expira en ${_formatDuration(trivia.timeRemaining!)}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMyPositionBar() {
    final myPosition = _controller.myPosition!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF667eea).withValues(alpha: 0.1),
        border: const Border(
          top: BorderSide(color: Color(0xFF667eea)),
        ),
      ),
      child: Row(
        children: [
          Text(
            '#${myPosition.rank}',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF667eea),
            ),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              'Tu posición',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Row(
            children: [
              const Icon(Icons.stars_rounded, color: Color(0xFF667eea)),
              const SizedBox(width: 4),
              Text(
                '${myPosition.response.totalScore} pts',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF667eea),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes % 60}m';
    }
    return '${duration.inMinutes}m';
  }
}

class _StatusChip extends StatelessWidget {
  final Trivia trivia;

  const _StatusChip({required this.trivia});

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    String text;
    IconData icon;

    if (trivia.isActive) {
      bgColor = Colors.green;
      text = 'Activa';
      icon = Icons.check_circle_rounded;
    } else if (trivia.status == TriviaStatus.closed) {
      bgColor = Colors.orange;
      text = 'Cerrada';
      icon = Icons.lock_rounded;
    } else {
      bgColor = Colors.grey;
      text = 'Expirada';
      icon = Icons.timer_off_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
