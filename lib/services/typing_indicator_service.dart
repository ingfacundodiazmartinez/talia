import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

/// Estado de actividad del usuario en un chat
enum UserActivityState {
  none,
  typing,
  recording,
}

class TypingIndicatorService {
  static final TypingIndicatorService _instance = TypingIndicatorService._internal();
  factory TypingIndicatorService() => _instance;
  TypingIndicatorService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Timer? _typingTimer;
  Timer? _recordingTimer;
  String? _currentChatId;
  bool _isCurrentGroup = false;

  // ✅ Throttle para evitar escrituras frecuentes a Firestore (evita titileo)
  DateTime? _lastTypingWrite;
  static const _typingThrottleDuration = Duration(seconds: 2);
  bool _isCurrentlyTyping = false;

  // Indicar que el usuario está escribiendo
  Future<void> setTyping(String chatId, bool isTyping, {bool isGroup = false}) async {
    final user = _auth.currentUser;
    if (user == null) return;

    _currentChatId = chatId;
    _isCurrentGroup = isGroup;

    try {
      if (isTyping) {
        // Cancelar el timer de auto-stop anterior
        _typingTimer?.cancel();

        // ✅ Throttle: Solo escribir a Firestore si pasaron más de 2 segundos
        // desde la última escritura, o si no estamos marcados como "typing"
        final now = DateTime.now();
        final shouldWrite = !_isCurrentlyTyping ||
            _lastTypingWrite == null ||
            now.difference(_lastTypingWrite!) > _typingThrottleDuration;

        if (shouldWrite) {
          _lastTypingWrite = now;
          _isCurrentlyTyping = true;

          // Marcar como escribiendo con timestamp
          final collection = isGroup ? 'groups_v2' : 'chats';
          await _firestore
              .collection(collection)
              .doc(chatId)
              .collection('typing')
              .doc(user.uid)
              .set({
            'userId': user.uid,
            'isTyping': true,
            'timestamp': FieldValue.serverTimestamp(),
          });
        }

        // Auto-remover después de 4 segundos si no hay nueva actividad
        // (aumentado de 3 a 4 para dar margen al throttle)
        _typingTimer = Timer(const Duration(seconds: 4), () {
          _setTypingOff(chatId, isGroup: isGroup);
        });
      } else {
        _setTypingOff(chatId, isGroup: isGroup);
      }
    } catch (e) {
      // Silently ignore errors
    }
  }

  // ✅ Método interno para limpiar el estado de typing
  Future<void> _setTypingOff(String chatId, {bool isGroup = false}) async {
    final user = _auth.currentUser;
    if (user == null) return;

    _typingTimer?.cancel();
    _isCurrentlyTyping = false;
    _lastTypingWrite = null;

    try {
      final collection = isGroup ? 'groups_v2' : 'chats';
      await _firestore
          .collection(collection)
          .doc(chatId)
          .collection('typing')
          .doc(user.uid)
          .delete();
    } catch (e) {
      // Silently ignore errors
    }
  }

  // Escuchar si el otro usuario está escribiendo
  // ✅ handleError evita crashes cuando el chat es bloqueado/revocado
  Stream<bool> watchOtherUserTyping(String chatId, String otherUserId) {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('typing')
        .doc(otherUserId)
        .snapshots()
        .handleError((error) {
          // Ignorar errores de permisos cuando el chat es bloqueado
        })
        .map((doc) {
      if (!doc.exists) return false;

      final data = doc.data();
      if (data == null) return false;

      final isTyping = data['isTyping'] as bool? ?? false;
      final timestamp = data['timestamp'] as Timestamp?;

      // Solo considerar como "escribiendo" si fue en los últimos 5 segundos
      if (timestamp != null && isTyping) {
        final now = DateTime.now();
        final diff = now.difference(timestamp.toDate());
        return diff.inSeconds < 5;
      }

      return false;
    });
  }

  // Escuchar usuarios escribiendo en un grupo
  Stream<List<String>> watchGroupTypingUsers(String groupId, String currentUserId) {
    return _firestore
        .collection('groups_v2')
        .doc(groupId)
        .collection('typing')
        .snapshots()
        .map((snapshot) {
      final typingUsers = <String>[];

      for (final doc in snapshot.docs) {
        // No incluir al usuario actual
        if (doc.id == currentUserId) continue;

        final data = doc.data();
        final isTyping = data['isTyping'] as bool? ?? false;
        final timestamp = data['timestamp'] as Timestamp?;

        // Solo considerar como "escribiendo" si fue en los últimos 5 segundos
        if (timestamp != null && isTyping) {
          final now = DateTime.now();
          final diff = now.difference(timestamp.toDate());
          if (diff.inSeconds < 5) {
            typingUsers.add(doc.id);
          }
        }
      }

      return typingUsers;
    });
  }

  // Limpiar al salir del chat
  void stopTyping() {
    _typingTimer?.cancel();
    if (_currentChatId != null) {
      setTyping(_currentChatId!, false, isGroup: _isCurrentGroup);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // INDICADOR DE GRABACIÓN DE AUDIO
  // ═══════════════════════════════════════════════════════════════

  /// Indicar que el usuario está grabando audio
  Future<void> setRecording(String chatId, bool isRecording, {bool isGroup = false}) async {
    final user = _auth.currentUser;
    if (user == null) return;

    _currentChatId = chatId;
    _isCurrentGroup = isGroup;

    try {
      if (isRecording) {
        // Cancelar el timer anterior si existe
        _recordingTimer?.cancel();
        // También cancelar typing si está activo
        _typingTimer?.cancel();

        // Marcar como grabando con timestamp
        final collection = isGroup ? 'groups' : 'chats';
        await _firestore
            .collection(collection)
            .doc(chatId)
            .collection('typing')
            .doc(user.uid)
            .set({
          'userId': user.uid,
          'isTyping': false,
          'isRecording': true,
          'timestamp': FieldValue.serverTimestamp(),
        });

        // Auto-remover después de 60 segundos (máximo tiempo de grabación)
        _recordingTimer = Timer(const Duration(seconds: 60), () {
          setRecording(chatId, false, isGroup: isGroup);
        });
      } else {
        // Eliminar indicador de grabación
        _recordingTimer?.cancel();
        final collection = isGroup ? 'groups' : 'chats';
        await _firestore
            .collection(collection)
            .doc(chatId)
            .collection('typing')
            .doc(user.uid)
            .delete();
      }
    } catch (e) {
      // Silently ignore errors
    }
  }

  /// Escuchar estado de actividad del otro usuario (typing o recording)
  Stream<UserActivityState> watchOtherUserActivity(String chatId, String otherUserId) {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('typing')
        .doc(otherUserId)
        .snapshots()
        .handleError((error) {
          // Ignorar errores de permisos cuando el chat es bloqueado
        })
        .map((doc) {
      if (!doc.exists) return UserActivityState.none;

      final data = doc.data();
      if (data == null) return UserActivityState.none;

      final timestamp = data['timestamp'] as Timestamp?;

      // Solo considerar si fue en los últimos 5 segundos
      if (timestamp != null) {
        final now = DateTime.now();
        final diff = now.difference(timestamp.toDate());
        if (diff.inSeconds < 5) {
          final isRecording = data['isRecording'] as bool? ?? false;
          final isTyping = data['isTyping'] as bool? ?? false;

          if (isRecording) return UserActivityState.recording;
          if (isTyping) return UserActivityState.typing;
        }
      }

      return UserActivityState.none;
    });
  }

  /// Escuchar usuarios activos en un grupo (typing o recording)
  Stream<Map<String, UserActivityState>> watchGroupActivity(String groupId, String currentUserId) {
    return _firestore
        .collection('groups_v2')
        .doc(groupId)
        .collection('typing')
        .snapshots()
        .map((snapshot) {
      final activity = <String, UserActivityState>{};

      for (final doc in snapshot.docs) {
        // No incluir al usuario actual
        if (doc.id == currentUserId) continue;

        final data = doc.data();
        final timestamp = data['timestamp'] as Timestamp?;

        // Solo considerar si fue en los últimos 5 segundos
        if (timestamp != null) {
          final now = DateTime.now();
          final diff = now.difference(timestamp.toDate());
          if (diff.inSeconds < 5) {
            final isRecording = data['isRecording'] as bool? ?? false;
            final isTyping = data['isTyping'] as bool? ?? false;

            if (isRecording) {
              activity[doc.id] = UserActivityState.recording;
            } else if (isTyping) {
              activity[doc.id] = UserActivityState.typing;
            }
          }
        }
      }

      return activity;
    });
  }

  /// Limpiar indicador de grabación al cancelar/enviar
  void stopRecording() {
    _recordingTimer?.cancel();
    if (_currentChatId != null) {
      setRecording(_currentChatId!, false, isGroup: _isCurrentGroup);
    }
  }

  /// Limpiar todo al salir del chat
  void stopAll() {
    stopTyping();
    stopRecording();
  }
}
