import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/contact_photo_cache_service.dart';
import '../utils/release_logger.dart';

/// Widget de avatar que se sincroniza automáticamente con cambios de foto de perfil
/// Usa lazy/on-demand listeners para eficiencia
class SyncedUserAvatar extends StatefulWidget {
  final String userId;
  final String? fallbackPhotoUrl; // URL inicial/fallback (puede estar desactualizada)
  final String userName; // Nombre fallback
  final double radius;
  final Color? backgroundColor;

  const SyncedUserAvatar({
    super.key,
    required this.userId,
    this.fallbackPhotoUrl,
    required this.userName,
    this.radius = 20,
    this.backgroundColor,
  });

  @override
  State<SyncedUserAvatar> createState() => _SyncedUserAvatarState();
}

class _SyncedUserAvatarState extends State<SyncedUserAvatar> {
  final ContactPhotoCacheService _profileCacheService = ContactPhotoCacheService();
  StreamSubscription<UserProfileUpdateEvent>? _profileSubscription;
  String? _currentPhotoUrl;
  String? _currentName;

  @override
  void initState() {
    super.initState();
    _initializeProfile();
  }

  void _initializeProfile() {
    // Inicializar con fallbacks
    _currentPhotoUrl = widget.fallbackPhotoUrl;
    _currentName = widget.userName;

    // Iniciar listener lazy para este usuario
    _profileCacheService.startWatching(widget.userId);

    // Verificar si ya hay datos más recientes en cache
    final cachedProfile = _profileCacheService.getProfile(widget.userId);
    if (cachedProfile != null) {
      if (cachedProfile.photoUrl != null) {
        _currentPhotoUrl = cachedProfile.photoUrl;
      }
      if (cachedProfile.name != null) {
        _currentName = cachedProfile.name;
      }
    }

    // Suscribirse a cambios de perfil
    _profileSubscription = _profileCacheService.onProfileUpdated.listen((event) {
      if (event.userId == widget.userId && mounted) {
        setState(() {
          if (event.photoChanged) {
            _currentPhotoUrl = event.newPhotoUrl;
          }
          if (event.nameChanged && event.newName != null) {
            _currentName = event.newName;
          }
        });
      }
    });
  }

  @override
  void didUpdateWidget(SyncedUserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Si cambió el userId, actualizar listeners
    if (oldWidget.userId != widget.userId) {
      _profileSubscription?.cancel();
      _profileCacheService.stopWatching(oldWidget.userId);
      _initializeProfile();
    }
  }

  @override
  void dispose() {
    _profileSubscription?.cancel();
    _profileCacheService.stopWatching(widget.userId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.backgroundColor ??
        Theme.of(context).colorScheme.primaryContainer;

    return CircleAvatar(
      radius: widget.radius,
      backgroundColor: bgColor,
      child: _currentPhotoUrl != null && _currentPhotoUrl!.isNotEmpty
          ? ClipOval(
              child: CachedNetworkImage(
                imageUrl: _currentPhotoUrl!,
                width: widget.radius * 2,
                height: widget.radius * 2,
                fit: BoxFit.cover,
                placeholder: (context, url) => _buildInitial(),
                errorWidget: (context, url, error) => _buildInitial(),
              ),
            )
          : _buildInitial(),
    );
  }

  Widget _buildInitial() {
    final name = _currentName ?? widget.userName;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Text(
      initial,
      style: TextStyle(
        fontSize: widget.radius * 0.8,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// Widget que muestra nombre de usuario sincronizado
/// Usa lazy/on-demand listeners para eficiencia
/// Prioridad: alias > name cacheado > fallbackName
class SyncedUserName extends StatefulWidget {
  final String userId;
  final String fallbackName;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  /// Si es true, ignora el alias y solo muestra el nombre real
  final bool ignoreAlias;

  const SyncedUserName({
    super.key,
    required this.userId,
    required this.fallbackName,
    this.style,
    this.maxLines,
    this.overflow,
    this.ignoreAlias = false,
  });

  @override
  State<SyncedUserName> createState() => _SyncedUserNameState();
}

class _SyncedUserNameState extends State<SyncedUserName> {
  final ContactPhotoCacheService _profileCacheService = ContactPhotoCacheService();
  StreamSubscription<UserProfileUpdateEvent>? _profileSubscription;
  StreamSubscription<AliasUpdateEvent>? _aliasSubscription;
  String _currentDisplayName = '';

  @override
  void initState() {
    super.initState();
    _initializeProfile();
  }

  void _initializeProfile() {
    // Verificar si ya hay alias en cache
    final cachedAlias = _profileCacheService.getAlias(widget.userId);
    ReleaseLogger.log('🏷️ [SyncedUserName] Init for userId: ${widget.userId}, cached alias: $cachedAlias, fallback: ${widget.fallbackName}');

    // Iniciar listener lazy para este usuario
    _profileCacheService.startWatching(widget.userId);

    // Obtener nombre a mostrar usando la lógica del servicio
    _updateDisplayName();

    // Suscribirse a cambios de nombre
    _profileSubscription = _profileCacheService.onProfileUpdated.listen((event) {
      if (event.userId == widget.userId && event.nameChanged && mounted) {
        ReleaseLogger.log('🏷️ [SyncedUserName] Name changed for ${widget.userId}');
        _updateDisplayName();
      }
    });

    // Suscribirse a cambios de alias (si no está deshabilitado)
    if (!widget.ignoreAlias) {
      _aliasSubscription = _profileCacheService.onAliasUpdated.listen((event) {
        ReleaseLogger.log('🏷️ [SyncedUserName] Alias event received: ${event.contactId} (my userId: ${widget.userId})');
        if (event.contactId == widget.userId && mounted) {
          ReleaseLogger.log('🏷️ [SyncedUserName] Alias matched! Updating display name');
          _updateDisplayName();
        }
      });
    }
  }

  void _updateDisplayName() {
    final alias = _profileCacheService.getAlias(widget.userId);
    final cachedName = _profileCacheService.getName(widget.userId);

    ReleaseLogger.log('🏷️ [SyncedUserName] _updateDisplayName for ${widget.userId}: alias="$alias", cachedName="$cachedName", fallback="${widget.fallbackName}"');

    setState(() {
      if (widget.ignoreAlias) {
        // Solo nombre, sin alias
        _currentDisplayName = cachedName ?? widget.fallbackName;
      } else {
        // Usar lógica del servicio: alias > name > fallback
        _currentDisplayName = _profileCacheService.getDisplayName(widget.userId, widget.fallbackName);
      }
      ReleaseLogger.log('🏷️ [SyncedUserName] Display name updated for ${widget.userId}: "$_currentDisplayName"');
    });
  }

  @override
  void didUpdateWidget(SyncedUserName oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.userId != widget.userId) {
      _profileSubscription?.cancel();
      _aliasSubscription?.cancel();
      _profileCacheService.stopWatching(oldWidget.userId);
      _initializeProfile();
    }
  }

  @override
  void dispose() {
    _profileSubscription?.cancel();
    _aliasSubscription?.cancel();
    _profileCacheService.stopWatching(widget.userId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _currentDisplayName,
      style: widget.style,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
