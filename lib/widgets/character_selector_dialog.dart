import 'package:flutter/material.dart';
import '../models/character.dart';
import '../services/character_service.dart';

/// Dialog para seleccionar un personaje para transformación con IA
class CharacterSelectorDialog extends StatefulWidget {
  final int? remainingTransforms;

  const CharacterSelectorDialog({
    super.key,
    this.remainingTransforms,
  });

  @override
  State<CharacterSelectorDialog> createState() => _CharacterSelectorDialogState();
}

class _CharacterSelectorDialogState extends State<CharacterSelectorDialog> {
  final CharacterService _characterService = CharacterService();
  List<Character> _characters = [];
  bool _isLoading = true;
  String? _errorMessage;
  String _selectedCategory = 'all';

  @override
  void initState() {
    super.initState();
    // Cargar personajes inmediatamente en background sin bloquear la UI
    _loadCharactersAsync();
  }

  /// Cargar personajes de forma asíncrona sin bloquear la UI
  /// El diálogo se muestra inmediatamente mientras se cargan los personajes
  void _loadCharactersAsync() {
    _loadCharacters();
  }

  Future<void> _loadCharacters() async {
    try {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      // OPTIMIZACIÓN: Cargar personajes con timeout para mostrar error rápido si falla
      final characters = await _characterService.getEnabledCharacters().timeout(
        Duration(seconds: 10),
        onTimeout: () {
          print('⚠️ Timeout cargando personajes');
          throw Exception('La carga de personajes está tardando demasiado');
        },
      );

      if (mounted) {
        setState(() {
          _characters = characters;
          _isLoading = false;
        });
        print('✅ ${characters.length} personajes cargados');
      }
    } catch (e) {
      print('❌ Error cargando personajes: $e');
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().contains('tardando')
              ? 'La carga está tardando demasiado. Verifica tu conexión.'
              : 'Error al cargar personajes';
          _isLoading = false;
        });
      }
    }
  }

  List<Character> get _filteredCharacters {
    if (_selectedCategory == 'all') {
      return _characters;
    }
    return _characters.where((c) => c.category == _selectedCategory).toList();
  }

  List<String> get _categories {
    final categories = _characters.map((c) => c.category).toSet().toList();
    categories.sort();
    return ['all', ...categories];
  }

  String _getCategoryDisplayName(String category) {
    switch (category) {
      case 'all':
        return 'Todos';
      case 'anime':
        return 'Anime';
      case 'superheroes':
        return 'Superhéroes';
      case 'otros':
        return 'Otros';
      default:
        return category;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
          maxWidth: 400,
        ),
        decoration: BoxDecoration(
          color: isDarkMode ? colorScheme.surface : Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Color(0xFF9D7FE8),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.face, color: Colors.white, size: 28),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Elige tu personaje',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (widget.remainingTransforms != null)
                          Text(
                            '${widget.remainingTransforms} transformaciones restantes este mes',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),

            // Categories
            if (_characters.isNotEmpty && _categories.length > 2)
              Container(
                height: 50,
                padding: EdgeInsets.symmetric(vertical: 8),
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  itemCount: _categories.length,
                  itemBuilder: (context, index) {
                    final category = _categories[index];
                    final isSelected = _selectedCategory == category;

                    return GestureDetector(
                      onTap: () {
                        setState(() {
                          _selectedCategory = category;
                        });
                      },
                      child: Container(
                        margin: EdgeInsets.only(right: 8),
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Color(0xFF9D7FE8)
                              : (isDarkMode
                                  ? colorScheme.surfaceContainerHighest
                                  : Colors.grey[200]),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Center(
                          child: Text(
                            _getCategoryDisplayName(category),
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : (isDarkMode
                                      ? colorScheme.onSurface
                                      : Colors.black87),
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

            // Content
            Expanded(
              child: _buildContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Animación más atractiva
            SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                color: Color(0xFF9D7FE8),
                strokeWidth: 4,
              ),
            ),
            SizedBox(height: 24),
            Text(
              'Cargando personajes...',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDarkMode ? colorScheme.onSurface : Colors.black87,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Esto solo tomará un momento',
              style: TextStyle(
                fontSize: 13,
                color: isDarkMode ? colorScheme.onSurfaceVariant : Colors.grey[600],
              ),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red),
            SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadCharacters,
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF9D7FE8),
              ),
              child: Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    if (_characters.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.face,
              size: 64,
              color: isDarkMode ? colorScheme.onSurfaceVariant : Colors.grey[400],
            ),
            SizedBox(height: 16),
            Text(
              'No hay personajes disponibles',
              style: TextStyle(
                color: isDarkMode ? colorScheme.onSurfaceVariant : Colors.grey[600],
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    final filteredCharacters = _filteredCharacters;

    if (filteredCharacters.isEmpty) {
      return Center(
        child: Text(
          'No hay personajes en esta categoría',
          style: TextStyle(
            color: isDarkMode ? colorScheme.onSurfaceVariant : Colors.grey[600],
          ),
        ),
      );
    }

    return GridView.builder(
      padding: EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.75,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: filteredCharacters.length,
      itemBuilder: (context, index) {
        final character = filteredCharacters[index];
        return _buildCharacterCard(character);
      },
    );
  }

  Widget _buildCharacterCard(Character character) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: () {
        Navigator.pop(context, character);
      },
      child: Container(
        decoration: BoxDecoration(
          color: isDarkMode
              ? colorScheme.surfaceContainerHighest
              : Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDarkMode
                ? colorScheme.outline.withValues(alpha: 0.3)
                : Colors.grey[300]!,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
                child: character.thumbnailUrl.isNotEmpty &&
                        !character.thumbnailUrl.contains('example.com')
                    ? Image.network(
                        character.thumbnailUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (context, error, stackTrace) {
                          return _buildPlaceholderIcon();
                        },
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Center(
                            child: CircularProgressIndicator(
                              value: loadingProgress.expectedTotalBytes != null
                                  ? loadingProgress.cumulativeBytesLoaded /
                                      loadingProgress.expectedTotalBytes!
                                  : null,
                              strokeWidth: 2,
                              color: Color(0xFF9D7FE8),
                            ),
                          );
                        },
                      )
                    : _buildPlaceholderIcon(),
              ),
            ),
            Container(
              padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Text(
                character.name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDarkMode ? colorScheme.onSurface : Colors.black87,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholderIcon() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: isDarkMode
          ? colorScheme.surfaceContainerHigh
          : Colors.grey[200],
      child: Center(
        child: Icon(
          Icons.face,
          size: 48,
          color: isDarkMode
              ? colorScheme.onSurfaceVariant
              : Colors.grey[400],
        ),
      ),
    );
  }
}
