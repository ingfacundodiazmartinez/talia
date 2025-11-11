import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_functions/cloud_functions.dart';
import '../services/video_call_service.dart';
import '../utils/release_logger.dart';

/// Controller para manejar la lógica del AppBar de chat grupal
///
/// Responsabilidades:
/// - Gestión de datos del grupo en tiempo real
/// - Iniciar videollamadas y llamadas grupales
/// - Generar tokens de Agora para llamadas
/// - Coordinar con VideoCallService
/// - Manejo de estados de error y loading
class GroupChatAppBarController {
  final String groupId;

  // Servicios privados
  final VideoCallService _videoCallService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;
  final FirebaseFunctions _functions;

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
    VideoCallService? videoCallService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
    FirebaseFunctions? functions,
  }) : _videoCallService = videoCallService ?? VideoCallService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _functions = functions ?? FirebaseFunctions.instance;

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

      // Obtener nombre del usuario actual
      final currentUserDoc = await _firestore.collection('users').doc(currentUserId).get();
      final currentUserName = currentUserDoc.data()?['name'] ?? 'Usuario';

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

      // Crear llamada grupal
      ReleaseLogger.log('Iniciando ${isVideo ? "videollamada" : "llamada"} grupal', tag: 'GroupChatAppBar');

      final channelName = isVideo
          ? await _videoCallService.startGroupCall(
              callerId: currentUserId,
              callerName: currentUserName,
              participantIds: participantIds,
              participantNames: participantNames,
              groupId: groupId,
              isEmergency: false,
            )
          : await _videoCallService.startGroupAudioCall(
              callerId: currentUserId,
              callerName: currentUserName,
              participantIds: participantIds,
              participantNames: participantNames,
              groupId: groupId,
              isEmergency: false,
            );

      // Obtener token de Agora
      ReleaseLogger.log('Generando token de Agora para llamada grupal', tag: 'GroupChatAppBar');

      final callable = _functions.httpsCallable('generateAgoraToken');
      final result = await callable.call({
        'channelName': channelName,
        'uid': 0, // 0 = Agora asigna automáticamente
      });

      final token = result.data['token'] as String;
      final uid = result.data['uid'] as int;

      ReleaseLogger.log('Token de Agora generado exitosamente', tag: 'GroupChatAppBar');

      // Notificar que debe navegar con los datos de la llamada
      _callData = {
        'callId': channelName,
        'channelName': channelName,
        'token': token,
        'uid': uid,
        'isCaller': true,
        'remoteName': groupData['name'] ?? 'Grupo',
        'receiverId': groupId,
        'isVideo': isVideo,
      };

      onNavigateToCall?.call();
      onSuccess?.call('${isVideo ? "Videollamada" : "Llamada"} grupal iniciada');

    } catch (e) {
      ReleaseLogger.error('Error iniciando llamada grupal: $e', tag: 'GroupChatAppBar');
      _setError('Error al iniciar ${isVideo ? "videollamada" : "llamada"}: $e');
    } finally {
      _setLoading(false);
    }
  }

  // Datos de llamada para navegación
  Map<String, dynamic>? _callData;

  /// Obtener datos de llamada para navegación
  Map<String, dynamic>? getCallData() {
    final data = _callData;
    _callData = null; // Limpiar después de obtener
    return data;
  }

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