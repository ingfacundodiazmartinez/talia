import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../controllers/participant_selector_controller.dart';

/// Widget para seleccionar un participante a agregar a una llamada en curso
///
/// Responsabilidades (UI ONLY):
/// - Mostrar lista de contactos desde controller
/// - Manejar interacciones de usuario (búsqueda, selección)
/// - Retornar contacto seleccionado al padre (para UI optimista)
/// - Delegar TODA la lógica al controller
class AddParticipantSheet extends StatefulWidget {
  final ScrollController scrollController;
  final Set<String> excludeIds; // IDs ya en la llamada
  final ValueChanged<SelectableContact> onSelect; // Devuelve contacto completo

  const AddParticipantSheet({
    super.key,
    required this.scrollController,
    required this.excludeIds,
    required this.onSelect,
  });

  @override
  State<AddParticipantSheet> createState() => _AddParticipantSheetState();
}

class _AddParticipantSheetState extends State<AddParticipantSheet> {
  late ParticipantSelectorController _controller;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = ParticipantSelectorController();
    _controller.addListener(_onControllerChange);
    _initializeController();
  }

  Future<void> _initializeController() async {
    await _controller.initialize();
    _controller.setExcludedIds(widget.excludeIds);
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChange);
    _controller.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _controller.updateSearch(query);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      children: [
        // Handle
        Container(
          margin: const EdgeInsets.only(top: 12, bottom: 8),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        // Título
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Agregar participante',
            style: theme.textTheme.titleLarge,
          ),
        ),
        // Búsqueda
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _searchController,
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
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Lista de contactos
        Expanded(
          child: _buildContent(colorScheme),
        ),
      ],
    );
  }

  Widget _buildContent(ColorScheme colorScheme) {
    if (_controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_controller.error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: colorScheme.error),
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
                  : 'No hay contactos disponibles',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: widget.scrollController,
      itemCount: _controller.contacts.length,
      itemBuilder: (context, index) {
        final contact = _controller.contacts[index];
        return _buildContactTile(contact, colorScheme);
      },
    );
  }

  Widget _buildContactTile(SelectableContact contact, ColorScheme colorScheme) {
    return ListTile(
      onTap: () => widget.onSelect(contact), // Devuelve contacto completo
      leading: _buildAvatar(contact),
      title: Text(
        contact.name,
        style: TextStyle(color: colorScheme.onSurface), // Adaptable a tema claro/oscuro
      ),
      subtitle: contact.phoneNumber != null
          ? Text(
              contact.phoneNumber!,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            )
          : null,
      trailing: Icon(
        Icons.add_circle_outline,
        color: colorScheme.primary,
      ),
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
