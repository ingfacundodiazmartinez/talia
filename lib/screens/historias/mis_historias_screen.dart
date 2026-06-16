import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../models/story.dart';
import '../story_viewer_screen.dart';

/// Pantalla que muestra las historias subidas por el usuario actual.
///
/// Trae TODAS las historias del usuario directamente desde Firestore
/// (incluyendo las expiradas / fuera de 24h) — el cache local solo tiene
/// las vigentes, así que para "Mis historias" necesitamos una query
/// dedicada sin filtros de tiempo.
class MisHistoriasScreen extends StatefulWidget {
  const MisHistoriasScreen({super.key});

  @override
  State<MisHistoriasScreen> createState() => _MisHistoriasScreenState();
}

class _MisHistoriasScreenState extends State<MisHistoriasScreen> {
  Future<List<Story>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _loadAllStories();
  }

  /// Trae todas las historias del user actual, ordenadas por createdAt desc.
  /// SIN filtro de expiresAt — el user ve historias actuales y viejas.
  Future<List<Story>> _loadAllStories() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const [];
    final snap = await FirebaseFirestore.instance
        .collection('stories')
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(500)
        .get();
    return snap.docs.map(Story.fromFirestore).toList();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _loadAllStories();
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mis historias'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Story>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final stories = snapshot.data ?? const <Story>[];
            if (stories.isEmpty) {
              return _buildEmptyState(colorScheme);
            }
            return GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                childAspectRatio: 9 / 16,
              ),
              itemCount: stories.length,
              itemBuilder: (context, index) {
                final story = stories[index];
                return _buildStoryTile(story, colorScheme, onTap: () {
                  _openStory(stories, index);
                });
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.auto_stories,
            size: 64, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
        const SizedBox(height: 16),
        Center(
          child: Text(
            'No subiste historias',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Las historias que publiques aparecerán acá mientras estén activas (24 horas).',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStoryTile(
    Story story,
    ColorScheme colorScheme, {
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (story.mediaType == 'image' && story.mediaUrl.isNotEmpty)
              CachedNetworkImage(
                imageUrl: story.mediaUrl,
                fit: BoxFit.cover,
                placeholder: (c, _) => Container(
                    color: colorScheme.surfaceContainerHighest),
                errorWidget: (c, _, _) => Container(
                    color: colorScheme.surfaceContainerHighest,
                    child: Icon(Icons.broken_image,
                        color: colorScheme.onSurfaceVariant)),
              )
            else
              Container(
                color: colorScheme.surfaceContainerHighest,
                child: Icon(
                  story.mediaType == 'video'
                      ? Icons.play_circle_outline
                      : Icons.image,
                  size: 32,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            if (story.mediaType == 'video')
              const Positioned(
                top: 4,
                right: 4,
                child: Icon(Icons.videocam, color: Colors.white, size: 16),
              ),
            // Status overlay para no-aprobadas
            if (story.status != StoryStatus.approved)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.4),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(4),
                  child: Text(
                    _statusLabel(story.status),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(StoryStatus status) {
    switch (status) {
      case StoryStatus.pending:
        return 'Pendiente';
      case StoryStatus.rejected:
        return 'Rechazada';
      case StoryStatus.expired:
        return 'Expirada';
      case StoryStatus.uploading:
        return 'Subiendo...';
      case StoryStatus.approved:
        return '';
    }
  }

  void _openStory(List<Story> stories, int index) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || stories.isEmpty || index >= stories.length) return;

    // Agrupamos por día (local) basándonos en la historia tapeada. Sin este
    // filtro, el stepper del viewer muestra TODAS las historias del histórico
    // — con 100+ historias se vuelve ilegible. Solo mostramos las del día
    // del tap; para ver otro día, el usuario vuelve a Mis historias.
    final tapped = stories[index];
    final dayKey = _dayKey(tapped.createdAt.toLocal());
    final sameDay = stories
        .where((s) => _dayKey(s.createdAt.toLocal()) == dayKey)
        .toList();
    // El viewer internamente ordena las historias del user actual ASCENDING
    // (más vieja primero). La grilla de Mis Historias usa DESCENDING. Si no
    // ordeno acá, el filteredIndex apunta al slot equivocado en el viewer y
    // se abre la historia anterior a la que se tapeó.
    sameDay.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final filteredIndex = sameDay.indexWhere((s) => s.id == tapped.id);

    final userStories = UserStories(
      userId: uid,
      userName: 'Yo',
      stories: sameDay,
      hasUnviewed: false,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StoryViewerScreen(
          allUserStories: [userStories],
          initialUserIndex: 0,
          initialStoryIndex: filteredIndex >= 0 ? filteredIndex : 0,
        ),
      ),
    );
  }

  /// "YYYY-MM-DD" en zona local — sirve como key estable de día para agrupar.
  String _dayKey(DateTime local) {
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
