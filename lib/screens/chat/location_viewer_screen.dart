import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/live_location_service.dart';

/// Pantalla full con mapa interactivo de una ubicación compartida.
/// Si es en vivo, sigue la sesión y reposiciona la cámara/marcador.
class LocationViewerScreen extends StatefulWidget {
  final double initialLat;
  final double initialLng;
  final bool isLive;
  final String chatId;
  final String senderId;
  final bool isGroup;

  const LocationViewerScreen({
    super.key,
    required this.initialLat,
    required this.initialLng,
    required this.isLive,
    required this.chatId,
    required this.senderId,
    required this.isGroup,
  });

  @override
  State<LocationViewerScreen> createState() => _LocationViewerScreenState();
}

class _LocationViewerScreenState extends State<LocationViewerScreen> {
  GoogleMapController? _controller;
  late double _lat = widget.initialLat;
  late double _lng = widget.initialLng;

  Future<void> _openInMaps() async {
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$_lat,$_lng',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Widget _map() {
    final pos = LatLng(_lat, _lng);
    return GoogleMap(
      initialCameraPosition: CameraPosition(target: pos, zoom: 16),
      onMapCreated: (c) => _controller = c,
      markers: {Marker(markerId: const MarkerId('loc'), position: pos)},
      myLocationButtonEnabled: false,
    );
  }

  void _moveTo(double lat, double lng) {
    _lat = lat;
    _lng = lng;
    _controller?.animateCamera(CameraUpdate.newLatLng(LatLng(lat, lng)));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isLive ? 'Ubicación en tiempo real' : 'Ubicación'),
        actions: [
          IconButton(
            icon: const Icon(Icons.directions),
            tooltip: 'Abrir en Google Maps',
            onPressed: _openInMaps,
          ),
        ],
      ),
      body: widget.isLive
          ? StreamBuilder<LiveLocationSnapshot?>(
              stream: LiveLocationService().watchSession(
                chatId: widget.chatId,
                senderId: widget.senderId,
                isGroup: widget.isGroup,
              ),
              builder: (context, snapshot) {
                final live = snapshot.data;
                if (live != null &&
                    (live.latitude != _lat || live.longitude != _lng)) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _moveTo(live.latitude, live.longitude);
                  });
                }
                return Stack(
                  children: [
                    _map(),
                    if (live == null)
                      const Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: _Banner(text: 'La ubicación en tiempo real finalizó'),
                      ),
                  ],
                );
              },
            )
          : _map(),
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  const _Banner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text, textAlign: TextAlign.center),
      ),
    );
  }
}
