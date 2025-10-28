import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

/// Servicio para monitorear el estado de la conexión de red
///
/// Permite:
/// - Detectar cambios en la conectividad
/// - Mostrar banner de "Sin conexión"
/// - Notificar a widgets sobre el estado de red
class NetworkStatusService {
  static final NetworkStatusService _instance = NetworkStatusService._internal();
  factory NetworkStatusService() => _instance;
  NetworkStatusService._internal();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  // Stream controller para notificar cambios
  final StreamController<bool> _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStatus => _connectionStatusController.stream;

  bool _isConnected = true;
  bool get isConnected => _isConnected;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  // Callbacks para notificaciones
  final List<VoidCallback> _onConnectedCallbacks = [];
  final List<VoidCallback> _onDisconnectedCallbacks = [];

  /// Inicializa el servicio y empieza a monitorear la red
  Future<void> initialize() async {
    if (_isInitialized) {
      print('📡 [Network] Servicio ya estaba inicializado');
      return;
    }

    // Verificar estado inicial INMEDIATAMENTE
    try {
      final result = await _connectivity.checkConnectivity();
      _updateConnectionStatus(result);
      print('📡 [Network] Estado inicial verificado: $_isConnected');
    } catch (e) {
      print('⚠️ [Network] Error verificando estado inicial: $e');
      // En caso de error, asumir que no hay conexión por seguridad
      _isConnected = false;
      _connectionStatusController.add(false);
    }

    // Escuchar cambios
    _subscription = _connectivity.onConnectivityChanged.listen((result) {
      _updateConnectionStatus(result);
    });

    _isInitialized = true;
    print('📡 [Network] Servicio de red inicializado con estado: $_isConnected');
  }

  /// Registra callback para cuando se conecta
  void onConnected(VoidCallback callback) {
    _onConnectedCallbacks.add(callback);
  }

  /// Registra callback para cuando se desconecta
  void onDisconnected(VoidCallback callback) {
    _onDisconnectedCallbacks.add(callback);
  }

  /// Actualiza el estado de conexión
  void _updateConnectionStatus(List<ConnectivityResult> results) {
    final wasConnected = _isConnected;
    _isConnected = results.any((result) => result != ConnectivityResult.none);

    // Notificar stream
    _connectionStatusController.add(_isConnected);

    // Ejecutar callbacks si cambió el estado
    if (wasConnected != _isConnected) {
      if (_isConnected) {
        print('✅ [Network] Conexión restaurada');
        for (final callback in _onConnectedCallbacks) {
          callback();
        }
      } else {
        print('❌ [Network] Conexión perdida');
        for (final callback in _onDisconnectedCallbacks) {
          callback();
        }
      }
    }
  }

  /// Limpia recursos
  void dispose() {
    _subscription?.cancel();
    _connectionStatusController.close();
  }
}

/// Widget que muestra un banner cuando no hay conexión
class NetworkStatusBanner extends StatelessWidget {
  final Widget child;

  const NetworkStatusBanner({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: NetworkStatusService().connectionStatus,
      initialData: NetworkStatusService().isConnected,
      builder: (context, snapshot) {
        final isConnected = snapshot.data ?? true;

        return Column(
          children: [
            if (!isConnected)
              Directionality(
                textDirection: TextDirection.ltr,
                child: Material(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: Colors.red.shade600,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.wifi_off, color: Colors.white, size: 16),
                        SizedBox(width: 8),
                        Text(
                          'Sin conexión a internet',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(child: child),
          ],
        );
      },
    );
  }
}

/// Mixin para widgets que necesitan reaccionar a cambios de red
mixin NetworkAware<T extends StatefulWidget> on State<T> {
  StreamSubscription<bool>? _networkSubscription;

  @override
  void initState() {
    super.initState();
    _networkSubscription = NetworkStatusService().connectionStatus.listen(
      (isConnected) {
        if (mounted) {
          onNetworkStatusChanged(isConnected);
        }
      },
    );
  }

  @override
  void dispose() {
    _networkSubscription?.cancel();
    super.dispose();
  }

  /// Override este método para reaccionar a cambios de red
  void onNetworkStatusChanged(bool isConnected);
}
