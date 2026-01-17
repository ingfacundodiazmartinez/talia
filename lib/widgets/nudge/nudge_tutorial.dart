import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/nudge.dart';

/// Tutorial que explica como enviar los diferentes tipos de nudges
class NudgeTutorial extends StatefulWidget {
  final VoidCallback? onComplete;

  const NudgeTutorial({
    super.key,
    this.onComplete,
  });

  /// Verificar si el usuario ya vio el tutorial
  static Future<bool> hasSeenTutorial() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('nudge_tutorial_seen') ?? false;
  }

  /// Marcar tutorial como visto
  static Future<void> markTutorialSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('nudge_tutorial_seen', true);
  }

  @override
  State<NudgeTutorial> createState() => _NudgeTutorialState();
}

class _NudgeTutorialState extends State<NudgeTutorial> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  final List<_TutorialPage> _pages = [
    _TutorialPage(
      type: NudgeType.latido,
      title: 'Latido',
      description: 'Un toque de cariño para decir "estoy pensando en vos"',
      instruction: 'Manten presionado un chat y selecciona 💓',
    ),
    _TutorialPage(
      type: NudgeType.zumbido,
      title: 'Zumbido',
      description: 'Un recordatorio amigable para retomar la conversacion',
      instruction: 'Selecciona 📳 para enviar un zumbido',
    ),
    _TutorialPage(
      type: NudgeType.saludo,
      title: 'Saludo',
      description: 'Una forma casual de iniciar conversacion',
      instruction: 'Selecciona 👋 para enviar un saludo',
    ),
    _TutorialPage(
      type: NudgeType.psst,
      title: 'Psst',
      description: '¡Tengo algo nuevo! Invita a ver tus historias',
      instruction: 'Selecciona 🤫 para avisar que subiste algo',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    if (_currentPage < _pages.length - 1) {
      _pageController.nextPage(
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _completeTutorial();
    }
  }

  void _completeTutorial() async {
    await NudgeTutorial.markTutorialSeen();
    widget.onComplete?.call();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.close, color: colorScheme.onSurface),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: _completeTutorial,
            child: Text(
              'Omitir',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Titulo principal
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '📳 Aprende a usar Nudges',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Formas rapidas de conectar con quienes mas te importan',
              style: TextStyle(
                fontSize: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          SizedBox(height: 32),

          // PageView
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (index) => setState(() => _currentPage = index),
              itemCount: _pages.length,
              itemBuilder: (context, index) {
                final page = _pages[index];
                return _buildPage(page, colorScheme);
              },
            ),
          ),

          // Indicadores de pagina
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_pages.length, (index) {
              final isActive = index == _currentPage;
              return AnimatedContainer(
                duration: Duration(milliseconds: 200),
                margin: EdgeInsets.symmetric(horizontal: 4),
                width: isActive ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: isActive
                      ? _getColor(_pages[_currentPage].type)
                      : colorScheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),
          SizedBox(height: 24),

          // Boton siguiente
          Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _nextPage,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _getColor(_pages[_currentPage].type),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  _currentPage == _pages.length - 1 ? '¡Entendido!' : 'Siguiente',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPage(_TutorialPage page, ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Emoji grande con animacion
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.8, end: 1.0),
            duration: Duration(milliseconds: 600),
            curve: Curves.elasticOut,
            builder: (context, scale, child) {
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    color: _getColor(page.type).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _getColor(page.type).withValues(alpha: 0.3),
                      width: 3,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _getColor(page.type).withValues(alpha: 0.2),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      page.type.emoji,
                      style: TextStyle(fontSize: 56),
                    ),
                  ),
                ),
              );
            },
          ),
          SizedBox(height: 32),

          // Titulo
          Text(
            page.title,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: _getColor(page.type),
            ),
          ),
          SizedBox(height: 12),

          // Descripcion
          Text(
            page.description,
            style: TextStyle(
              fontSize: 16,
              color: colorScheme.onSurface,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 24),

          // Instruccion
          Container(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.touch_app,
                  size: 20,
                  color: colorScheme.onSurfaceVariant,
                ),
                SizedBox(width: 8),
                Flexible(
                  child: Text(
                    page.instruction,
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _getColor(NudgeType type) {
    switch (type) {
      case NudgeType.latido:
        return Colors.pink;
      case NudgeType.zumbido:
        return Colors.orange;
      case NudgeType.saludo:
        return Colors.blue;
      case NudgeType.psst:
        return Colors.purple;
    }
  }
}

class _TutorialPage {
  final NudgeType type;
  final String title;
  final String description;
  final String instruction;

  const _TutorialPage({
    required this.type,
    required this.title,
    required this.description,
    required this.instruction,
  });
}

/// Mostrar tutorial si es la primera vez
Future<void> showNudgeTutorialIfNeeded(BuildContext context) async {
  final hasSeenTutorial = await NudgeTutorial.hasSeenTutorial();
  if (!hasSeenTutorial && context.mounted) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => NudgeTutorial(),
        fullscreenDialog: true,
      ),
    );
  }
}
