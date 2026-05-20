import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../services/user_cache_service.dart';

/// Bottom sheet que muestra quién reaccionó a un mensaje
class ReactionsDetailSheet extends StatefulWidget {
  final Map<String, dynamic> reactions;
  final String? initialEmoji;

  const ReactionsDetailSheet({
    super.key,
    required this.reactions,
    this.initialEmoji,
  });

  @override
  State<ReactionsDetailSheet> createState() => _ReactionsDetailSheetState();
}

class _ReactionsDetailSheetState extends State<ReactionsDetailSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late List<String> _emojis;
  int _initialIndex = 0;

  @override
  void initState() {
    super.initState();

    // Ordenar emojis por cantidad de reacciones (descendente)
    _emojis = widget.reactions.keys.toList()
      ..sort((a, b) {
        final aCount = (widget.reactions[a] as List).length;
        final bCount = (widget.reactions[b] as List).length;
        return bCount.compareTo(aCount);
      });

    // Encontrar índice inicial si se especificó un emoji
    if (widget.initialEmoji != null) {
      _initialIndex = _emojis.indexOf(widget.initialEmoji!);
      if (_initialIndex == -1) _initialIndex = 0;
    }

    _tabController = TabController(
      length: _emojis.length,
      vsync: this,
      initialIndex: _initialIndex,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(
              children: [
                Text(
                  'Reacciones',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                  iconSize: 24,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),

          // Tabs (emojis)
          if (_emojis.length > 1)
            Container(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                    width: 1,
                  ),
                ),
              ),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                indicatorColor: colorScheme.primary,
                labelColor: colorScheme.onSurface,
                unselectedLabelColor: colorScheme.onSurfaceVariant,
                dividerColor: Colors.transparent,
                tabs: _emojis.map((emoji) {
                  final count = (widget.reactions[emoji] as List).length;
                  return Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(emoji, style: const TextStyle(fontSize: 20)),
                        const SizedBox(width: 6),
                        Text(
                          count.toString(),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),

          // Lista de usuarios
          Flexible(
            child: _emojis.length > 1
                ? TabBarView(
                    controller: _tabController,
                    children: _emojis.map((emoji) {
                      return _buildUserList(emoji);
                    }).toList(),
                  )
                : _buildUserList(_emojis.first),
          ),

          // Padding bottom para safe area
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }

  Widget _buildUserList(String emoji) {
    final userIds = List<String>.from(widget.reactions[emoji] as List);

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: userIds.length,
      itemBuilder: (context, index) {
        return _buildUserTile(userIds[index]);
      },
    );
  }

  Widget _buildUserTile(String userId) {
    return FutureBuilder<Map<String, dynamic>?>(
      future: UserCacheService().getUserData(userId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return ListTile(
            leading: CircleAvatar(
              radius: 20,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            title: const Text('Cargando...'),
          );
        }

        final userData = snapshot.data;
        final name = userData?['name'] as String? ?? 'Usuario';
        final photoURL = userData?['photoURL'] as String?;

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          leading: CircleAvatar(
            radius: 20,
            backgroundColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
            backgroundImage: photoURL != null && photoURL.isNotEmpty
                ? CachedNetworkImageProvider(photoURL)
                : null,
            child: photoURL == null || photoURL.isEmpty
                ? Text(
                    name.isNotEmpty ? name[0].toUpperCase() : 'U',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  )
                : null,
          ),
          title: Text(
            name,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      },
    );
  }
}

/// Función helper para mostrar el bottom sheet
void showReactionsDetail(
  BuildContext context, {
  required Map<String, dynamic> reactions,
  String? initialEmoji,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) => ReactionsDetailSheet(
        reactions: reactions,
        initialEmoji: initialEmoji,
      ),
    ),
  );
}
