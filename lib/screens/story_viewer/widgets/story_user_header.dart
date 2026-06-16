import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../services/contact_photo_cache_service.dart';
import '../../../widgets/synced_user_widgets.dart';
import '../../../utils/official.dart';

/// Header con información del usuario que publicó la historia
/// Usa lazy/on-demand listeners para mantener la foto actualizada en tiempo real
class StoryUserHeader extends StatefulWidget {
  final String userName;
  final String userId; // ✅ Nuevo: userId para listener de foto
  final String? userPhotoURL; // Fallback inicial (denormalizado del story)
  final String timeAgo;
  final bool isCurrentUser;
  final VoidCallback? onDelete;
  final VoidCallback? onDownload;
  final VoidCallback? onShare;
  final VoidCallback onClose;
  final VoidCallback? onPauseTimer; // ✅ Pausar timer al abrir menú
  final VoidCallback? onResumeTimer; // ✅ Reanudar timer al cerrar menú

  const StoryUserHeader({
    super.key,
    required this.userName,
    required this.userId,
    this.userPhotoURL,
    required this.timeAgo,
    required this.isCurrentUser,
    this.onDelete,
    this.onDownload,
    this.onShare,
    required this.onClose,
    this.onPauseTimer,
    this.onResumeTimer,
  });

  @override
  State<StoryUserHeader> createState() => _StoryUserHeaderState();
}

class _StoryUserHeaderState extends State<StoryUserHeader> {
  final ContactPhotoCacheService _photoCacheService = ContactPhotoCacheService();
  StreamSubscription<PhotoUpdateEvent>? _photoSubscription;
  String? _currentPhotoUrl;

  // Cuenta oficial de Talia (bienvenida / comunicados): no tiene doc en `users`.
  bool get _isOfficial => Official.isOfficialUser(widget.userId);

  // ✅ Sombras para texto e iconos (visibilidad en fondos claros)
  static const List<Shadow> _textShadows = [
    Shadow(
      offset: Offset(0, 1),
      blurRadius: 3,
      color: Colors.black54,
    ),
  ];

  @override
  void initState() {
    super.initState();
    // Inicializar con la URL del story (fallback)
    _currentPhotoUrl = widget.userPhotoURL;

    // Iniciar listener lazy para este usuario.
    // La cuenta oficial de Talia no tiene doc en `users`: no observar.
    if (!_isOfficial) {
      _photoCacheService.startWatching(widget.userId);

      // Verificar si ya hay una foto más reciente en cache
      final cachedUrl = _photoCacheService.getPhotoUrl(widget.userId);
      if (cachedUrl != null) {
        _currentPhotoUrl = cachedUrl;
      }
    }

    // Suscribirse a cambios de foto (siempre: el userId puede cambiar a uno
    // no-oficial vía didUpdateWidget)
    _photoSubscription = _photoCacheService.onPhotoUpdated.listen((event) {
      if (event.userId == widget.userId && mounted) {
        setState(() {
          _currentPhotoUrl = event.newPhotoUrl;
        });
      }
    });
  }

  @override
  void didUpdateWidget(StoryUserHeader oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Si cambió el userId, actualizar listeners (start/stop simétricos:
    // los ids oficiales nunca se observan, así no se desbalancea el refcount)
    if (oldWidget.userId != widget.userId) {
      if (!Official.isOfficialUser(oldWidget.userId)) {
        _photoCacheService.stopWatching(oldWidget.userId);
      }
      if (!_isOfficial) {
        _photoCacheService.startWatching(widget.userId);
      }

      // Actualizar foto con la del nuevo usuario
      _currentPhotoUrl = _photoCacheService.getPhotoUrl(widget.userId) ?? widget.userPhotoURL;
    }
  }

  @override
  void dispose() {
    _photoSubscription?.cancel();
    if (!_isOfficial) {
      _photoCacheService.stopWatching(widget.userId);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Avatar con borde para mejor visibilidad
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: CircleAvatar(
              radius: 20,
              backgroundColor: _isOfficial ? Colors.white : Colors.white.withValues(alpha: 0.3),
              backgroundImage: _isOfficial ? const AssetImage(Official.logoAsset) : null,
              child: _isOfficial
                  ? null
                  : _currentPhotoUrl != null
                  ? ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: _currentPhotoUrl!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Icon(Icons.person, color: Colors.white, size: 20),
                        errorWidget: (context, url, error) => Icon(Icons.person, color: Colors.white, size: 20),
                      ),
                    )
                  : Text(
                      widget.userName.isNotEmpty ? widget.userName[0].toUpperCase() : '?',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        shadows: _textShadows,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isOfficial)
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        Official.userName,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          shadows: _textShadows,
                        ),
                      ),
                      SizedBox(width: 4),
                      Icon(Icons.verified, color: Colors.white, size: 16, shadows: _textShadows),
                    ],
                  )
                else
                  SyncedUserName(
                    userId: widget.userId,
                    fallbackName: widget.userName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      shadows: _textShadows,
                    ),
                  ),
                Text(
                  widget.timeAgo,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 12,
                    shadows: _textShadows,
                  ),
                ),
              ],
            ),
          ),
          // Botón de compartir (visible para todas las historias)
          if (widget.onShare != null)
            IconButton(
              onPressed: widget.onShare,
              icon: Icon(
                Icons.share,
                color: Colors.white,
                shadows: _textShadows,
              ),
              tooltip: 'Compartir',
            ),
          // Menú de opciones si es la historia del usuario actual
          if (widget.isCurrentUser && (widget.onDelete != null || widget.onDownload != null))
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert,
                color: Colors.white,
                shadows: _textShadows,
              ),
              color: Colors.black87,
              // ✅ Pausar timer cuando se abre el menú
              onOpened: () {
                widget.onPauseTimer?.call();
              },
              // ✅ Reanudar timer cuando se cancela (cierra sin seleccionar)
              onCanceled: () {
                widget.onResumeTimer?.call();
              },
              onSelected: (value) async {
                // ✅ Reanudar timer al seleccionar una opción
                widget.onResumeTimer?.call();
                if (value == 'delete') {
                  widget.onDelete?.call();
                } else if (value == 'download') {
                  widget.onDownload?.call();
                }
              },
              itemBuilder: (context) => [
                if (widget.onDownload != null)
                  const PopupMenuItem(
                    value: 'download',
                    child: Row(
                      children: [
                        Icon(Icons.download, color: Colors.white),
                        SizedBox(width: 8),
                        Text(
                          'Descargar',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                if (widget.onDelete != null)
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, color: Colors.red),
                        SizedBox(width: 8),
                        Text(
                          'Eliminar historia',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          IconButton(
            onPressed: widget.onClose,
            icon: Icon(
              Icons.close,
              color: Colors.white,
              shadows: _textShadows,
            ),
          ),
        ],
      ),
    );
  }
}
