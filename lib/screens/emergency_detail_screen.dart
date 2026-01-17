import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../controllers/emergency_detail_controller.dart';
import '../utils/release_logger.dart';

/// Pantalla de detalle de emergencia
///
/// Responsabilidades (SOLO UI):
/// - Mostrar información de la emergencia activa
/// - Visualizar tracking de ubicación en mapa
/// - Manejar resolución de emergencia
/// - Delegar toda lógica al EmergencyDetailController
/// - Cumplir con CODING_RULES.md: ZERO Firebase calls
class EmergencyDetailScreen extends StatefulWidget {
  final String emergencyId;
  final Map<String, dynamic> emergencyData;

  const EmergencyDetailScreen({
    super.key,
    required this.emergencyId,
    required this.emergencyData,
  });

  @override
  State<EmergencyDetailScreen> createState() => _EmergencyDetailScreenState();
}

class _EmergencyDetailScreenState extends State<EmergencyDetailScreen> {
  late EmergencyDetailController _controller;
  GoogleMapController? _mapController;

  // UI State (managed by controller)
  List<LatLng> _locationPoints = [];
  bool _isResolving = false;

  @override
  void initState() {
    super.initState();

    // Inicializar controller con todos los parámetros
    _controller = EmergencyDetailController(
      emergencyId: widget.emergencyId,
      emergencyData: widget.emergencyData,
    );

    // Configurar callbacks para actualizar UI
    _controller.onLocationPointsChanged = _handleLocationPointsChanged;
    _controller.onResolvingStateChanged = _handleResolvingStateChanged;
    _controller.onError = _handleError;

    // Inicializar controller
    _controller.initialize().catchError((error) {
      ReleaseLogger.error('Error en initialize: $error', tag: 'EmergencyDetailScreen');
      if (mounted) {
        _showErrorSnackBar('Error iniciando tracking de emergencia');
      }
    });
  }

  @override
  void dispose() {
    _mapController?.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Manejar cambios de puntos de ubicación del controller
  void _handleLocationPointsChanged(List<LatLng> points) {
    if (mounted) {
      setState(() {
        _locationPoints = points;
      });
    }
  }

  /// Manejar cambios de estado de resolución del controller
  void _handleResolvingStateChanged(bool isResolving) {
    if (mounted) {
      setState(() {
        _isResolving = isResolving;
      });
    }
  }

  /// Manejar errores del controller
  void _handleError(String error) {
    if (mounted) {
      _showErrorSnackBar(error);
    }
  }

  /// Mostrar error
  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  /// Resolver emergencia
  Future<void> _resolveEmergency() async {
    await _controller.resolveEmergency();
    if (!_controller.isResolving && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        title: Text('🆘 EMERGENCIA ACTIVA'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Información de la emergencia
          _buildEmergencyHeader(),

          // Mapa con tracking
          _buildMapSection(),

          // Botón de resolver
          _buildResolveButton(),
        ],
      ),
    );
  }

  /// Construir header con información de emergencia
  Widget _buildEmergencyHeader() {
    return Container(
      color: Colors.red.withValues(alpha: 0.1),
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: Colors.red,
                radius: 24,
                child: Icon(Icons.warning, color: Colors.white, size: 28),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _controller.childName,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.red[900],
                      ),
                    ),
                    Text(
                      _controller.message,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.red[700],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Divider(height: 24),
          Row(
            children: [
              Expanded(
                child: _buildInfoItem(
                  Icons.access_time,
                  'Hora de activación',
                  _controller.formatTime(widget.emergencyData['dateTime']),
                ),
              ),
              Expanded(
                child: StreamBuilder<int>(
                  stream: Stream.periodic(Duration(seconds: 1), (tick) => tick),
                  builder: (context, snapshot) {
                    return _buildInfoItem(
                      Icons.timer,
                      'Tiempo transcurrido',
                      _controller.getElapsedTime(),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Construir sección del mapa
  Widget _buildMapSection() {
    return Expanded(
      child: Stack(
        children: [
          if (_controller.initialLocation != null)
            GoogleMap(
              initialCameraPosition: CameraPosition(
                target: LatLng(
                  _controller.initialLocation!['latitude'] as double,
                  _controller.initialLocation!['longitude'] as double,
                ),
                zoom: 15,
              ),
              markers: _controller.buildMarkers(_locationPoints),
              polylines: _controller.buildPolylines(_locationPoints),
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: true,
              mapType: MapType.normal,
              onMapCreated: (controller) {
                _mapController = controller;
              },
            )
          else
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.location_off, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Sin ubicación disponible',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
            ),

          // Información de puntos de tracking
          if (_locationPoints.length > 1)
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.route, color: Colors.red, size: 20),
                    SizedBox(width: 8),
                    Text(
                      '${_locationPoints.length} puntos recientes',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.red[900],
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Construir botón de resolver emergencia
  Widget _buildResolveButton() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _isResolving ? null : _resolveEmergency,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isResolving
                ? SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    'TODO ESTÁ BIEN - RESOLVER EMERGENCIA',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// Construir elemento de información
  Widget _buildInfoItem(IconData icon, String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: Colors.red[700]),
            SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
        SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.red[900],
          ),
        ),
      ],
    );
  }
}
