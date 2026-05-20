import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../calls_v2/controllers/call_controller.dart' as calls_v2;
import '../utils/release_logger.dart';

/// Controller para manejar la lógica del AppBar de chat grupal
///
/// Responsabilidades:
/// - Gestión de datos del grupo en tiempo real
/// - Iniciar videollamadas y llamadas grupales
/// - Coordinar con CallsOrchestrator (nuevo sistema)
/// - Manejo de estados de error y loading
class GroupChatAppBarController {
  final String groupId;

  // Servicios privados
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;

  // Estado del controller
  Map<String, dynamic>? _groupData;
  bool _isLoading = false;
  bool _hasError = false;
  String? _errorMessage;

  // Subscripciones
  StreamSubscription? _groupDataSubscription;

  // Callbacks para comunicación con el widget
  Function(Map<String, dynamic>?)? onGroupDataChanged;
  Function(bool)? onLoadingChanged;
  Function(String)? onError;
  Function(String)? onSuccess;
  Function()? onNavigateToCall;

  // Constructor
  GroupChatAppBarController({
    required this.groupId,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance;

  // Getters para el estado
  Map<String, dynamic>? get groupData => _groupData;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  String? get errorMessage => _errorMessage;
  String get currentUserId => _auth.currentUser?.uid ?? '';

  /// Inicializar el controller
  void initialize() {
    try {
      _clearError();
      _setupGroupDataListener();
    } catch (e) {
      _setError('Error inicializando controller: $e');
    }
  }

  /// Configurar listener para datos del grupo
  void _setupGroupDataListener() {
    _groupDataSubscription = _firestore
        .collection('groups')
        .doc(groupId)
        .snapshots()
        .listen(
          (snapshot) {
            if (snapshot.exists) {
              _groupData = {
                'id': snapshot.id,
                ...snapshot.data()!,
              };
              onGroupDataChanged?.call(_groupData);
            } else {
              _setError('Grupo no encontrado');
            }
          },
          onError: (error) {
            ReleaseLogger.error('Error en stream de grupo: $error', tag: 'GroupChatAppBar');
            _setError('Error cargando datos del grupo');
          },
        );
  }

  /// Obtener información actual del grupo
  Stream<DocumentSnapshot> getGroupStream() {
    return _firestore.collection('groups').doc(groupId).snapshots();
  }

  /// Iniciar videollamada grupal
  Future<void> startGroupVideoCall() async {
    await _startGroupCall(isVideo: true);
  }

  /// Iniciar llamada de audio grupal
  Future<void> startGroupAudioCall() async {
    await _startGroupCall(isVideo: false);
  }

  /// Iniciar llamada grupal (video o audio)
  Future<void> _startGroupCall({required bool isVideo}) async {
    try {
      _setLoading(true);
      _clearError();

      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        throw 'Usuario no autenticado';
      }

      // Obtener datos del grupo
      final groupDoc = await _firestore.collection('groups').doc(groupId).get();
      final groupData = groupDoc.data();

      if (groupData == null) {
        throw 'No se encontró el grupo';
      }

      final members = List<String>.from(groupData['members'] ?? []);
      final allParticipants = members.where((id) => id != currentUserId).toList();

      if (allParticipants.isEmpty) {
        throw 'No hay otros miembros en el grupo';
      }

      // ✅ LÍMITE MÁXIMO: 6 participantes por llamada (excluyendo al caller)
      final participantIds = allParticipants.take(6).toList();
      final excludedCount = allParticipants.length - participantIds.length;

      if (excludedCount > 0) {
        ReleaseLogger.log(
          'Límite de llamada grupal: Invitando a ${participantIds.length} de ${allParticipants.length} miembros',
          tag: 'GroupChatAppBar'
        );
      }

      // Construir mapa de nombres de participantes
      final participantNames = <String, String>{};
      for (String participantId in participantIds) {
        try {
          final userDoc = await _firestore.collection('users').doc(participantId).get();
          participantNames[participantId] = userDoc.data()?['name'] ?? 'Usuario';
        } catch (e) {
          ReleaseLogger.error('Error obteniendo nombre de usuario $participantId: $e', tag: 'GroupChatAppBar');
          participantNames[participantId] = 'Usuario';
        }
      }

      // Crear llamada grupal usando CallController de calls_v2
      ReleaseLogger.log('Iniciando ${isVideo ? "videollamada" : "llamada"} grupal', tag: 'GroupChatAppBar');

      final callController = calls_v2.CallController();
      final result = await callController.createCall(
        participantIds: participantIds,
        isVideo: isVideo,
        isGroup: true,
      );

      // Check if call was successful
      if (!result.success) {
        throw result.error ?? 'Error al iniciar llamada grupal';
      }

      // ✅ CallController maneja la navegación automáticamente a través del orchestrator
      // No necesitamos generar tokens manualmente ni navegar
      ReleaseLogger.log('Llamada grupal creada exitosamente', tag: 'GroupChatAppBar');
      onSuccess?.call('${isVideo ? "Videollamada" : "Llamada"} grupal iniciada');

    } catch (e) {
      ReleaseLogger.error('Error iniciando llamada grupal: $e', tag: 'GroupChatAppBar');
      _setError('Error al iniciar ${isVideo ? "videollamada" : "llamada"}: $e');
    } finally {
      _setLoading(false);
    }
  }

  // ✅ LEGACY CODE REMOVED: CallsOrchestrator maneja navegación automáticamente

  /// Verificar si se puede iniciar llamadas (más de 1 miembro)
  bool canStartCall() {
    final members = List<String>.from(_groupData?['members'] ?? []);
    return members.length > 1;
  }

  /// Obtener conteo de miembros
  int getMemberCount() {
    final members = List<String>.from(_groupData?['members'] ?? []);
    return members.length;
  }

  /// Obtener URL del avatar del grupo
  String getGroupPhotoURL() {
    return _groupData?['avatar'] as String? ?? '';
  }

  /// Métodos de utilidad privados
  void _setLoading(bool loading) {
    _isLoading = loading;
    onLoadingChanged?.call(loading);
  }

  void _setError(String error) {
    _hasError = true;
    _errorMessage = error;
    onError?.call(error);
  }

  void _clearError() {
    _hasError = false;
    _errorMessage = null;
  }

  /// Limpiar recursos
  void dispose() {
    _groupDataSubscription?.cancel();
  }
}