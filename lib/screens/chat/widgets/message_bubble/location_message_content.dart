import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../../../services/live_location_service.dart';
import '../../location_viewer_screen.dart';

/// Render de un mensaje de ubicación (estático o en vivo) dentro de la burbuja.
///
/// - Estático: mini-mapa con un marcador fijo.
/// - En vivo (no expirado): escucha la sesión en `live_locations` y mueve el
///   marcador en tiempo real; muestra badge "En vivo" + cuenta regresiva.
///   Si es mi propia sesión activa, ofrece "Dejar de compartir".
/// - En vivo expirado: muestra el último punto con etiqueta "Finalizada".
class LocationMessageContent extends StatelessWidget {
  final double latitude;
  final double longitude;
  final bool isLiveLocation;
  final DateTime? liveLocationExpiresAt;
  final String chatId;
  final String senderId;
  final bool isGroup;
  final bool isMe;

  const LocationMessageContent({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.isLiveLocation,
    required this.liveLocationExpiresAt,
    required this.chatId,
    required this.senderId,
    required this.isGroup,
    required this.isMe,
  });

  static const double _width = 230;
  static const double _height = 150;

  bool get _liveExpired =>
      liveLocationExpiresAt != null &&
      liveLocationExpiresAt!.isBefore(DateTime.now());

  @override
  Widget build(BuildContext context) {
    if (isLiveLocation && !_liveExpired) {
      return StreamBuilder<LiveLocationSnapshot?>(
        stream: LiveLocationService().watchSession(
          chatId: chatId,
          senderId: senderId,
          isGroup: isGroup,
        ),
        builder: (context, snapshot) {
          final live = snapshot.data;
          // Si la sesión terminó/expiró, mostramos el último punto como estático.
          if (live == null) {
            return _buildCard(
              context,
              lat: latitude,
              lng: longitude,
              live: false,
              expiresAt: null,
            );
          }
          return _buildCard(
            context,
            lat: live.latitude,
            lng: live.longitude,
            live: true,
            expiresAt: live.expiresAt,
          );
        },
      );
    }
    return _buildCard(
      context,
      lat: latitude,
      lng: longitude,
      live: false,
      expiresAt: null,
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required double lat,
    required double lng,
    required bool live,
    required DateTime? expiresAt,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final pos = LatLng(lat, lng);

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => LocationViewerScreen(
              initialLat: lat,
              initialLng: lng,
              isLive: live,
              chatId: chatId,
              senderId: senderId,
              isGroup: isGroup,
            ),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: _width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: _width,
                height: _height,
                child: AbsorbPointer(
                  // El mapa es solo preview; el tap abre la pantalla full.
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(target: pos, zoom: 15),
                    liteModeEnabled: Platform.isAndroid,
                    zoomControlsEnabled: false,
                    myLocationButtonEnabled: false,
                    markers: {
                      Marker(markerId: const MarkerId('loc'), position: pos),
                    },
                  ),
                ),
              ),
              Container(
                color: colorScheme.surfaceContainerHighest,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      live ? Icons.location_on : Icons.place,
                      size: 16,
                      color: live ? Colors.green : colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        live
                            ? 'Ubicación en tiempo real'
                            : (isLiveLocation
                                ? 'Ubicación en tiempo real finalizada'
                                : 'Ubicación'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (live && expiresAt != null)
                      Text(
                        _remaining(expiresAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (live && isMe)
                InkWell(
                  onTap: () => LiveLocationService()
                      .stopLiveShare(chatId: chatId, isGroup: isGroup),
                  child: Container(
                    width: _width,
                    color: colorScheme.surfaceContainerHighest,
                    padding: const EdgeInsets.only(bottom: 10, top: 2),
                    child: Text(
                      'Dejar de compartir',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.error,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _remaining(DateTime expiresAt) {
    final diff = expiresAt.difference(DateTime.now());
    if (diff.isNegative) return '';
    if (diff.inHours >= 1) return '${diff.inHours}h';
    if (diff.inMinutes >= 1) return '${diff.inMinutes}m';
    return '<1m';
  }
}
