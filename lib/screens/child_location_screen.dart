import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/location_service.dart';

class ChildLocationScreen extends StatefulWidget {
  final String childId;
  final String childName;

  const ChildLocationScreen({
    super.key,
    required this.childId,
    required this.childName,
  });

  @override
  State<ChildLocationScreen> createState() => _ChildLocationScreenState();
}

class _ChildLocationScreenState extends State<ChildLocationScreen> {
  GoogleMapController? _mapController;
  final LocationService _locationService = LocationService();

  // Variables para el mapa
  LatLng? _childLocation;
  DateTime? _lastUpdate;
  double? _accuracy;
  bool _isLoading = true;
  String? _errorMessage;

  // Configuración inicial del mapa
  static const LatLng _defaultLocation = LatLng(
    -34.6037,
    -58.3816,
  ); // Buenos Aires por defecto

  @override
  void initState() {
    super.initState();
    _loadChildLocation();
  }

  // Cargar ubicación del niño
  void _loadChildLocation() {
    _locationService
        .getUserLocationStream(widget.childId)
        .listen(
          (DocumentSnapshot snapshot) {
            if (mounted && snapshot.exists) {
              final data = snapshot.data() as Map<String, dynamic>;

              setState(() {
                _childLocation = LatLng(
                  data['latitude']?.toDouble() ?? _defaultLocation.latitude,
                  data['longitude']?.toDouble() ?? _defaultLocation.longitude,
                );
                _accuracy = data['accuracy']?.toDouble();
                _lastUpdate = data['timestamp'] != null
                    ? (data['timestamp'] as Timestamp).toDate()
                    : DateTime.now();
                _isLoading = false;
                _errorMessage = null;
              });

              // Mover la cámara a la nueva ubicación
              _moveToLocation(_childLocation!);
            } else if (mounted) {
              setState(() {
                _isLoading = false;
                _errorMessage = 'No se encontró la ubicación del niño';
              });
            }
          },
          onError: (error) {
            if (mounted) {
              setState(() {
                _isLoading = false;
                _errorMessage = 'Error cargando ubicación: $error';
              });
            }
          },
        );
  }

  // Mover cámara a ubicación específica
  void _moveToLocation(LatLng location) {
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: location, zoom: 16.0),
      ),
    );
  }

  // Formatear tiempo desde última actualización
  String _formatLastUpdate(DateTime? lastUpdate) {
    if (lastUpdate == null) return 'Desconocida';

    final now = DateTime.now();
    final difference = now.difference(lastUpdate);

    if (difference.inMinutes < 1) {
      return 'Hace ${difference.inSeconds} segundos';
    } else if (difference.inHours < 1) {
      return 'Hace ${difference.inMinutes} minutos';
    } else if (difference.inDays < 1) {
      return 'Hace ${difference.inHours} horas';
    } else {
      return 'Hace ${difference.inDays} días';
    }
  }

  // Formatear precisión
  String _formatAccuracy(double? accuracy) {
    if (accuracy == null) return 'Desconocida';
    return '±${accuracy.round()}m';
  }

  // Crear marcador del niño
  Set<Marker> _createMarkers() {
    if (_childLocation == null) return {};

    return {
      Marker(
        markerId: MarkerId('child_location'),
        position: _childLocation!,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
        infoWindow: InfoWindow(
          title: widget.childName,
          snippet: 'Última actualización: ${_formatLastUpdate(_lastUpdate)}',
        ),
      ),
    };
  }

  // Crear círculo de precisión
  Set<Circle> _createCircles() {
    if (_childLocation == null || _accuracy == null) return {};

    return {
      Circle(
        circleId: CircleId('accuracy_circle'),
        center: _childLocation!,
        radius: _accuracy!,
        strokeColor: Colors.blue.withValues(alpha: 0.5),
        fillColor: Colors.blue.withValues(alpha: 0.1),
        strokeWidth: 2,
      ),
    };
  }

  // Construir widget del mapa con manejo de errores
  Widget _buildMapWidget() {
    try {
      return GoogleMap(
        onMapCreated: (GoogleMapController controller) {
          _mapController = controller;
          if (_childLocation != null) {
            _moveToLocation(_childLocation!);
          }
        },
        initialCameraPosition: CameraPosition(
          target: _childLocation ?? _defaultLocation,
          zoom: 16.0,
        ),
        markers: _createMarkers(),
        circles: _createCircles(),
        myLocationEnabled: false,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: true,
        mapToolbarEnabled: false,
      );
    } catch (e) {
      // Si hay error con Google Maps (probablemente API key)
      return Container(
        color: Colors.grey[100],
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.map_outlined, size: 64, color: Colors.grey[400]),
                SizedBox(height: 16),
                Text(
                  'Configuración de Google Maps requerida',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2D3142),
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 8),
                Text(
                  'Para ver el mapa, configura tu Google Maps API key según las instrucciones en GOOGLE_MAPS_SETUP.md',
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 16),
                if (_childLocation != null)
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Color(0xFF9D7FE8).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Ubicación actual:',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                        Text(
                          '${_childLocation!.latitude.toStringAsFixed(6)}, ${_childLocation!.longitude.toStringAsFixed(6)}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF2D3142),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text('Ubicación de ${widget.childName}'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _isLoading = true;
              });
              _loadChildLocation();
            },
          ),
        ],
      ),
      body: _isLoading
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF9D7FE8)),
                  SizedBox(height: 16),
                  Text(
                    'Cargando ubicación...',
                    style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                  ),
                ],
              ),
            )
          : _errorMessage != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.location_off, size: 64, color: Colors.grey[400]),
                  SizedBox(height: 16),
                  Text(
                    _errorMessage!,
                    style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _isLoading = true;
                        _errorMessage = null;
                      });
                      _loadChildLocation();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Color(0xFF9D7FE8),
                      foregroundColor: Colors.white,
                    ),
                    child: Text('Reintentar'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                // Panel de información
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.location_on,
                            color: Color(0xFF9D7FE8),
                            size: 20,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Ubicación Actual',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF2D3142),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Última actualización:',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                                Text(
                                  _formatLastUpdate(_lastUpdate),
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF2D3142),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'Precisión:',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[600],
                                ),
                              ),
                              Text(
                                _formatAccuracy(_accuracy),
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF2D3142),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Mapa
                Expanded(child: _buildMapWidget()),
              ],
            ),
      floatingActionButton: _childLocation != null
          ? FloatingActionButton(
              onPressed: () => _moveToLocation(_childLocation!),
              backgroundColor: Color(0xFF9D7FE8),
              child: Icon(Icons.my_location, color: Colors.white),
            )
          : null,
    );
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }
}
