import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../utils/release_logger.dart';

/// Controller para manejar la lógica de negocio del ChatAppBar
///
/// Responsabilidades:
/// - Verificar si el usuario es padre/adulto (para mostrar moderación con IA)
/// - Obtener datos del contacto en tiempo real
/// - Calcular edad basada en fecha de nacimiento
/// - Gestionar estado de carga
/// - Abstraer operaciones Firebase del widget
class ChatAppBarController {
  // Firebase services
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado interno
  bool _isParentOrAdult = false;
  bool _isLoading = true;

  // Streams controllers para notificar cambios
  final StreamController<bool> _isParentOrAdultController = StreamController<bool>.broadcast();
  final StreamController<bool> _isLoadingController = StreamController<bool>.broadcast();

  /// Constructor
  ChatAppBarController({
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters para estado actual
  bool get isParentOrAdult => _isParentOrAdult;
  bool get isLoading => _isLoading;

  // Streams para escuchar cambios
  Stream<bool> get isParentOrAdultStream => _isParentOrAdultController.stream;
  Stream<bool> get isLoadingStream => _isLoadingController.stream;

  /// Inicializar controller - verificar si es padre/adulto
  Future<void> initialize() async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        _updateLoadingState(false);
        return;
      }

      ReleaseLogger.log('Verificando si usuario $currentUserId es padre/adulto', tag: 'ChatAppBar');

      final userDoc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .get();

      if (!userDoc.exists) {
        _updateLoadingState(false);
        return;
      }

      final userData = userDoc.data();

      // Verificar si es padre
      bool isParentOrAdult = userData?['isParent'] == true;

      // Verificar si es adulto (mayor de 18 años)
      if (!isParentOrAdult) {
        isParentOrAdult = _calculateIsAdult(userData);
      }

      _updateParentOrAdultStatus(isParentOrAdult);
      _updateLoadingState(false);

      ReleaseLogger.log('Usuario es padre/adulto: $isParentOrAdult', tag: 'ChatAppBar');
    } catch (e) {
      ReleaseLogger.error('Error verificando si es padre/adulto: $e', tag: 'ChatAppBar');
      _updateLoadingState(false);
    }
  }

  /// Calcular si el usuario es adulto basado en su fecha de nacimiento
  bool _calculateIsAdult(Map<String, dynamic>? userData) {
    final birthDate = userData?['birthDate'];
    if (birthDate == null) return false;

    try {
      final birthDateTime = (birthDate as Timestamp).toDate();
      final age = DateTime.now().difference(birthDateTime).inDays ~/ 365;
      return age >= 18;
    } catch (e) {
      ReleaseLogger.error('Error calculando edad del usuario: $e', tag: 'ChatAppBar');
      return false;
    }
  }

  /// Obtener stream de datos del contacto
  Stream<DocumentSnapshot> getContactDataStream(String contactId) {
    try {
      ReleaseLogger.log('Obteniendo stream de datos del contacto $contactId', tag: 'ChatAppBar');

      return _firestore
          .collection('users')
          .doc(contactId)
          .snapshots();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo stream del contacto $contactId: $e', tag: 'ChatAppBar');
      rethrow;
    }
  }

  /// Extraer datos del contacto del snapshot
  Map<String, dynamic> extractContactData(DocumentSnapshot? snapshot) {
    if (snapshot?.data() == null) {
      return {
        'photoURL': '',
        'isOnline': false,
        'name': '',
      };
    }

    final userData = snapshot!.data() as Map<String, dynamic>;
    return {
      'photoURL': userData['photoURL'] as String? ?? '',
      'isOnline': userData['isOnline'] ?? false,
      'name': userData['name'] as String? ?? '',
    };
  }

  /// Actualizar estado de padre/adulto
  void _updateParentOrAdultStatus(bool isParentOrAdult) {
    _isParentOrAdult = isParentOrAdult;
    _isParentOrAdultController.add(_isParentOrAdult);
  }

  /// Actualizar estado de carga
  void _updateLoadingState(bool isLoading) {
    _isLoading = isLoading;
    _isLoadingController.add(_isLoading);
  }

  /// Obtener ID del usuario actual
  String? get currentUserId => _auth.currentUser?.uid;

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ChatAppBarController', tag: 'ChatAppBar');
    _isParentOrAdultController.close();
    _isLoadingController.close();
  }
}