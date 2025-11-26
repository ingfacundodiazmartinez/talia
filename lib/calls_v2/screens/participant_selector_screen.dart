import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../controllers/participant_selector_controller.dart';
import 'agora_call_screen.dart';

/// Pantalla para seleccionar participantes de una llamada grupal
///
/// Responsabilidades (UI only):
/// - Mostrar lista de contactos con búsqueda
/// - Permitir selección múltiple
/// - Mostrar chips de seleccionados
/// - Navegar a llamada grupal
class ParticipantSelectorScreen extends StatefulWidget {
  final bool isVideo;
  final List<String>? preselectedIds; // Para llamadas desde grupo

  const ParticipantSelectorScreen({
    super.key,
    this.isVideo = true,
    this.preselectedIds,
  });

  @override
  State<ParticipantSelectorScreen> createState() => _ParticipantSelectorScreenState();
}

class _ParticipantSelectorScreenState extends State<ParticipantSelectorScreen> {
  late ParticipantSelectorController _controller;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = ParticipantSelectorController();
    _controller.addListener(_onControllerChange);
    _initializeController();
  }

  Future<void> _initializeController() async {
    await _controller.initialize();

    // Preseleccionar si viene de un grupo
    if (widget.preselectedIds != null && widget.preselectedIds!.isNotEmpty) {
      _controller.preselectContacts(widget.preselectedIds!);
    }
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChange);
    _controller.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _controller.updateSearch(query);
  }

  void _startCall() {
    if (!_controller.canStartCall) return;

    final participantIds = _controller.selectedIds.toList();

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => AgoraCallScreen.create(
          participantIds: participantIds,
          isVideo: widget.isVideo,
          isGroup: participantIds.length > 1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isVideo ? 'Videollamada grupal' : 'Llamada grupal',
        ),
        actions: [
          if (_controller.selectedCount > 0)
            TextButton(
              onPressed: _controller.clearSelection,
              child: const Text('Limpiar'),
            ),
        ],
      ),
      body: Column(
        children: [
          // Barra de búsqueda
          _buildSearchBar(colorScheme),

          // Chips de seleccionados
          if (_controller.selectedCount > 0) _buildSelectedChips(colorScheme),

          // Contador y límite
          _buildSelectionInfo(colorScheme),

          // Lista de contactos
          Expanded(
            child: _buildContactsList(colorScheme),
          ),
        ],
      ),
      floatingActionButton: _controller.canStartCall
          ? FloatingActionButton.extended(
              onPressed: _startCall,
              icon: Icon(widget.isVideo ? Icons.videocam : Icons.call),
              label: Text(
                'Llamar (${_controller.selectedCount})',
              ),
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
            )
          : null,
    );
  }

  Widget _buildSearchBar(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        onChanged: _onSearchChanged,
        decoration: InputDecoration(
          hintText: 'Buscar contactos...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                )
              : null,
          filled: true,
          fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildSelectedChips(ColorScheme colorScheme) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _controller.selectedContacts.length,
        itemBuilder: (context, index) {
          final contact = _controller.selectedContacts[index];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Chip(
              avatar: _buildAvatar(contact, size: 24),
              label: Text(
                contact.name.split(' ').first, // Solo primer nombre
                style: const TextStyle(fontSize: 12),
              ),
              deleteIcon: const Icon(Icons.close, size: 16),
              onDeleted: () => _controller.deselectContact(contact.id),
              backgroundColor: colorScheme.primaryContainer,
              labelStyle: TextStyle(color: colorScheme.onPrimaryContainer),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSelectionInfo(ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '${_controller.selectedCount}/${ParticipantSelectorController.maxParticipants} participantes',
            style: TextStyle(
              color: _controller.hasReachedLimit
                  ? colorScheme.error
                  : colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (_controller.hasReachedLimit) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.info_outline,
              size: 16,
              color: colorScheme.error,
            ),
            const SizedBox(width: 4),
            Text(
              'Límite alcanzado',
              style: TextStyle(
                color: colorScheme.error,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContactsList(ColorScheme colorScheme) {
    if (_controller.isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_controller.error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              _controller.error!,
              style: TextStyle(color: colorScheme.error),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _controller.refresh,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (_controller.contacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _searchController.text.isNotEmpty
                  ? Icons.search_off
                  : Icons.people_outline,
              size: 48,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isNotEmpty
                  ? 'No se encontraron contactos'
                  : 'No tienes contactos',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _controller.refresh,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80), // Espacio para FAB
        itemCount: _controller.contacts.length,
        itemBuilder: (context, index) {
          final contact = _controller.contacts[index];
          final isSelected = _controller.isSelected(contact.id);
          final isDisabled = !isSelected && _controller.hasReachedLimit;

          return _buildContactTile(
            contact: contact,
            isSelected: isSelected,
            isDisabled: isDisabled,
            colorScheme: colorScheme,
          );
        },
      ),
    );
  }

  Widget _buildContactTile({
    required SelectableContact contact,
    required bool isSelected,
    required bool isDisabled,
    required ColorScheme colorScheme,
  }) {
    return ListTile(
      onTap: isDisabled ? null : () => _controller.toggleSelection(contact.id),
      leading: _buildAvatar(contact),
      title: Text(
        contact.name,
        style: TextStyle(
          color: isDisabled ? colorScheme.onSurface.withValues(alpha: 0.5) : null,
        ),
      ),
      subtitle: contact.phoneNumber != null
          ? Text(
              contact.phoneNumber!,
              style: TextStyle(
                color: isDisabled
                    ? colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                    : colorScheme.onSurfaceVariant,
              ),
            )
          : null,
      trailing: Checkbox(
        value: isSelected,
        onChanged: isDisabled
            ? null
            : (value) => _controller.toggleSelection(contact.id),
        activeColor: colorScheme.primary,
      ),
      tileColor: isSelected
          ? colorScheme.primaryContainer.withValues(alpha: 0.3)
          : null,
    );
  }

  Widget _buildAvatar(SelectableContact contact, {double size = 40}) {
    if (contact.photoUrl != null && contact.photoUrl!.isNotEmpty) {
      return CircleAvatar(
        radius: size / 2,
        backgroundImage: CachedNetworkImageProvider(contact.photoUrl!),
      );
    }

    return CircleAvatar(
      radius: size / 2,
      backgroundColor: _getAvatarColor(contact.name),
      child: Text(
        _getInitials(contact.name),
        style: TextStyle(
          color: Colors.white,
          fontSize: size / 2.5,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  String _getInitials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  Color _getAvatarColor(String name) {
    final colors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.cyan,
    ];
    return colors[name.hashCode % colors.length];
  }
}
