import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/contact.dart';
import '../utils/release_logger.dart';

/// Servicio para gestionar relaciones de amistad entre usuarios
///
/// Los "amigos" son contactos aprobados que pueden ver historias mutuamente.
/// Este servicio maneja:
/// - Enviar solicitudes de amistad
/// - Aceptar/rechazar solicitudes
/// - Eliminar amigos
/// - Consultar estado de amistad
class FriendService {
  static final FriendService _instance = FriendService._internal();
  factory FriendService() => _instance;
  FriendService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static const String _tag = 'FriendService';

  // ═══════════════════════════════════════════════════════════════
  // FRIEND REQUEST OPERATIONS
  // ═══════════════════════════════════════════════════════════════

  /// Enviar solicitud de amistad a un contacto
  ///
  /// Solo se puede enviar si:
  /// - Es un contacto aprobado
  /// - No son ya amigos
  /// - No hay solicitud pendiente
  /// - No fue rechazado previamente
  Future<void> sendFriendRequest(String otherUserId) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    final contactId = Contact.generateId(currentUserId, otherUserId);

    await _firestore.runTransaction((transaction) async {
      final contactRef = _firestore.collection('contacts').doc(contactId);
      final contactDoc = await transaction.get(contactRef);

      if (!contactDoc.exists) {
        throw Exception('No existe el contacto');
      }

      final contact = Contact.fromFirestore(contactDoc);

      // Validar que es un contacto aprobado
      if (!contact.isApproved) {
        throw Exception('El contacto no está aprobado');
      }

      // Validar que no son ya amigos
      if (contact.isFriend) {
        throw Exception('Ya son amigos');
      }

      // Validar que no hay solicitud pendiente o rechazada
      if (contact.friendRequest != null) {
        if (contact.friendRequest!.isPending) {
          throw Exception('Ya existe una solicitud pendiente');
        }
        if (contact.friendRequest!.isRejected) {
          throw Exception('La solicitud fue rechazada previamente');
        }
      }

      // Crear la solicitud
      transaction.update(contactRef, {
        'friendRequest': {
          'status': 'pending',
          'requestedBy': currentUserId,
          'requestedAt': FieldValue.serverTimestamp(),
        },
      });
    });

    ReleaseLogger.log(
      'Solicitud de amistad enviada: $currentUserId -> $otherUserId',
      tag: _tag,
    );

    // Crear notificación para el destinatario
    await _createFriendRequestNotification(currentUserId, otherUserId);
  }

  /// Aceptar solicitud de amistad
  ///
  /// Solo puede aceptar quien recibió la solicitud (no quien la envió)
  Future<void> acceptFriendRequest(String otherUserId) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    final contactId = Contact.generateId(currentUserId, otherUserId);

    await _firestore.runTransaction((transaction) async {
      final contactRef = _firestore.collection('contacts').doc(contactId);
      final contactDoc = await transaction.get(contactRef);

      if (!contactDoc.exists) {
        throw Exception('No existe el contacto');
      }

      final contact = Contact.fromFirestore(contactDoc);

      // Validar que hay solicitud pendiente
      if (contact.friendRequest == null || !contact.friendRequest!.isPending) {
        throw Exception('No hay solicitud pendiente');
      }

      // Validar que el usuario actual es el receptor (no el que envió)
      if (contact.friendRequest!.requestedBy == currentUserId) {
        throw Exception('No puedes aceptar tu propia solicitud');
      }

      // Aceptar la solicitud
      transaction.update(contactRef, {
        'isFriend': true,
        'friendRequest': {
          'status': 'accepted',
          'requestedBy': contact.friendRequest!.requestedBy,
          'requestedAt': Timestamp.fromDate(contact.friendRequest!.requestedAt),
          'respondedAt': FieldValue.serverTimestamp(),
        },
      });
    });

    ReleaseLogger.log(
      'Solicitud de amistad aceptada: $currentUserId acepta a $otherUserId',
      tag: _tag,
    );
  }

  /// Rechazar solicitud de amistad
  ///
  /// El solicitante no recibe notificación, solo ve "No disponible"
  Future<void> rejectFriendRequest(String otherUserId) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    final contactId = Contact.generateId(currentUserId, otherUserId);

    await _firestore.runTransaction((transaction) async {
      final contactRef = _firestore.collection('contacts').doc(contactId);
      final contactDoc = await transaction.get(contactRef);

      if (!contactDoc.exists) {
        throw Exception('No existe el contacto');
      }

      final contact = Contact.fromFirestore(contactDoc);

      // Validar que hay solicitud pendiente
      if (contact.friendRequest == null || !contact.friendRequest!.isPending) {
        throw Exception('No hay solicitud pendiente');
      }

      // Validar que el usuario actual es el receptor
      if (contact.friendRequest!.requestedBy == currentUserId) {
        throw Exception('No puedes rechazar tu propia solicitud');
      }

      // Rechazar la solicitud
      transaction.update(contactRef, {
        'isFriend': false,
        'friendRequest': {
          'status': 'rejected',
          'requestedBy': contact.friendRequest!.requestedBy,
          'requestedAt': Timestamp.fromDate(contact.friendRequest!.requestedAt),
          'respondedAt': FieldValue.serverTimestamp(),
        },
      });
    });

    ReleaseLogger.log(
      'Solicitud de amistad rechazada: $currentUserId rechaza a $otherUserId',
      tag: _tag,
    );
  }

  /// Eliminar amigo
  ///
  /// Silencioso - el otro usuario no recibe notificación
  /// El otro usuario vuelve a punto 0 pero no recibirá FOMO de este usuario
  Future<void> removeFriend(String otherUserId) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      throw Exception('Usuario no autenticado');
    }

    final contactId = Contact.generateId(currentUserId, otherUserId);

    await _firestore.runTransaction((transaction) async {
      final contactRef = _firestore.collection('contacts').doc(contactId);
      final contactDoc = await transaction.get(contactRef);

      if (!contactDoc.exists) {
        throw Exception('No existe el contacto');
      }

      final contact = Contact.fromFirestore(contactDoc);

      if (!contact.isFriend) {
        throw Exception('No son amigos');
      }

      // Eliminar amistad - usar status 'rejected' para que no reciba FOMO
      transaction.update(contactRef, {
        'isFriend': false,
        'friendRequest': {
          'status': 'rejected', // Mismo status que rechazo para bloquear FOMO
          'requestedBy': currentUserId, // Quien eliminó
          'requestedAt': FieldValue.serverTimestamp(),
          'respondedAt': FieldValue.serverTimestamp(),
        },
      });
    });

    ReleaseLogger.log(
      'Amigo eliminado: $currentUserId elimina a $otherUserId',
      tag: _tag,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // QUERY METHODS
  // ═══════════════════════════════════════════════════════════════

  /// Obtener stream de amigos del usuario actual
  Stream<List<Contact>> watchMyFriends() {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return Stream.value([]);
    }
    return Contact.watchFriends(currentUserId);
  }

  /// Obtener stream de solicitudes de amistad pendientes recibidas
  Stream<List<Contact>> watchMyPendingFriendRequests() {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return Stream.value([]);
    }
    return Contact.watchPendingFriendRequests(currentUserId);
  }

  /// Obtener lista de IDs de amigos del usuario actual
  Future<List<String>> getMyFriendIds() async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return [];
    }
    return Contact.getFriendIds(currentUserId);
  }

  /// Verificar si dos usuarios son amigos
  Future<bool> areFriends(String userId1, String userId2) async {
    final contact = await Contact.findBetween(userId1, userId2);
    return contact?.isFriend ?? false;
  }

  /// Obtener el estado de amistad con otro usuario
  /// Retorna: none, pending_sent, pending_received, accepted, rejected
  Future<String> getFriendStatus(String otherUserId) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return 'none';
    }

    final contact = await Contact.findBetween(currentUserId, otherUserId);
    if (contact == null) {
      return 'none';
    }

    return contact.getFriendStatusForUser(currentUserId);
  }

  /// Contar solicitudes de amistad pendientes del usuario actual
  Future<int> countMyPendingFriendRequests() async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return 0;
    }
    return Contact.countPendingFriendRequests(currentUserId);
  }

  // ═══════════════════════════════════════════════════════════════
  // PRIVATE HELPERS
  // ═══════════════════════════════════════════════════════════════

  /// Crear notificación de solicitud de amistad
  Future<void> _createFriendRequestNotification(
    String senderId,
    String recipientId,
  ) async {
    try {
      // Obtener datos del sender para la notificación
      final senderDoc =
          await _firestore.collection('users').doc(senderId).get();
      final senderData = senderDoc.data();

      await _firestore.collection('notifications').add({
        'userId': recipientId,
        'type': 'friend_request',
        'title': 'Invitación a tu círculo',
        'body': '${senderData?['name'] ?? 'Alguien'} quiere ver tus historias',
        'senderId': senderId,
        'senderName': senderData?['name'],
        'senderPhotoUrl': senderData?['photoURL'],
        'data': {
          'senderId': senderId,
        },
        'pushSent': false,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      ReleaseLogger.error('Error creando notificación de amistad: $e', tag: _tag);
    }
  }
}

/// Global accessor
FriendService get friendService => FriendService();
