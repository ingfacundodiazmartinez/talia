import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'services/group_chat_service.dart';

class FirebaseService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Obtener usuario actual
  User? get currentUser => _auth.currentUser;

  // ==================== USUARIOS ====================

  // Crear perfil de usuario
  Future<void> createUserProfile({
    required String uid,
    required String name,
    required String email,
    required bool isParent,
  }) async {
    await _firestore.collection('users').doc(uid).set({
      'name': name,
      'email': email,
      'isParent': isParent,
      'createdAt': FieldValue.serverTimestamp(),
      'isOnline': true,
    });
  }

  // Obtener perfil de usuario
  Future<Map<String, dynamic>?> getUserProfile(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get();
    return doc.data();
  }

  // Actualizar estado en línea (upsert)
  Future<void> updateOnlineStatus(bool isOnline) async {
    if (currentUser != null) {
      await _firestore.collection('users').doc(currentUser!.uid).set({
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }
  }

  // ==================== HIJOS ====================

  // Agregar hijo (para padres)
  // 🔒 SEGURIDAD: Ahora usa Cloud Function para validación server-side
  Future<void> addChild({
    required String parentId,
    required String childId,
  }) async {
    try {
      final functions = FirebaseFunctions.instance;
      final result = await functions.httpsCallable('createParentChildLink').call({
        'parentId': parentId,
        'childId': childId,
      });

      if (result.data['success'] != true) {
        throw Exception(result.data['message'] ?? 'Error creating parent-child link');
      }

      print('✅ Parent-child link created: ${result.data['linkId']}');
    } catch (e) {
      print('❌ Error calling createParentChildLink: $e');
      rethrow;
    }
  }

  // Obtener hijos de un padre
  Stream<QuerySnapshot> getChildren(String parentId) {
    return _firestore
        .collection('parent_children')
        .where('parentId', isEqualTo: parentId)
        .snapshots();
  }

  // ==================== LISTA BLANCA ====================

  // Solicitar aprobación de contacto
  // DEPRECATED: Usar Cloud Function createContactRequest en su lugar
  Future<void> requestContact({
    required String childId,
    required String contactPhone,
    required String contactName,
  }) async {
    // Verificar si ya existe una solicitud pendiente con este teléfono
    final existingRequests = await _firestore
        .collection('contact_requests')
        .where('childId', isEqualTo: childId)
        .where('contactPhone', isEqualTo: contactPhone)
        .where('status', isEqualTo: 'pending')
        .get();

    if (existingRequests.docs.isNotEmpty) {
      throw Exception('Ya existe una solicitud pendiente con este contacto');
    }

    // Verificar si el teléfono corresponde a un usuario registrado
    final userQuery = await _firestore
        .collection('users')
        .where('phone', isEqualTo: contactPhone)
        .limit(1)
        .get();

    if (userQuery.docs.isNotEmpty) {
      final contactUserId = userQuery.docs.first.id;
      final participants = [childId, contactUserId]..sort();

      // Verificar si ya existe un contacto aprobado
      final existingContact = await _firestore
          .collection('contacts')
          .where('users', isEqualTo: participants)
          .get();

      if (existingContact.docs.isNotEmpty) {
        final contactStatus = existingContact.docs.first.data()['status'];
        if (contactStatus == 'approved') {
          throw Exception('Ya existe un contacto aprobado con este usuario');
        }
      }
    }

    // Obtener todos los padres vinculados
    final parentLinks = await _firestore
        .collection('parent_child_links')
        .where('childId', isEqualTo: childId)
        .where('status', isEqualTo: 'approved')
        .get();

    // Crear solicitud para cada padre vinculado
    for (final link in parentLinks.docs) {
      final parentId = link.data()['parentId'];
      await _firestore.collection('contact_requests').add({
        'childId': childId,
        'parentId': parentId,
        'contactPhone': contactPhone,
        'contactName': contactName,
        'status': 'pending', // pending, approved, rejected
        'requestedAt': FieldValue.serverTimestamp(),
      });
    }
  }

  // Obtener solicitudes pendientes para un padre
  Stream<QuerySnapshot> getPendingContactRequests(String parentId) {
    return _firestore
        .collection('contact_requests')
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .snapshots();
  }

  // Aprobar contacto
  Future<void> approveContact(
    String requestId,
    String childId,
    String contactId,
  ) async {
    // Actualizar el estado de la solicitud
    await _firestore.collection('contact_requests').doc(requestId).update({
      'status': 'approved',
      'approvedAt': FieldValue.serverTimestamp(),
    });

    // Agregar a contactos (sistema bidireccional)
    await _firestore.collection('contacts').add({
      'users': [childId, contactId],
      'status': 'approved',
      'createdAt': FieldValue.serverTimestamp(),
      'type': 'contact',
    });

    // Procesar invitaciones de grupo pendientes
    final groupChatService = GroupChatService();
    await groupChatService.processGroupInvitationsAfterContactApproval(
      childId,
      contactId,
    );
  }

  // Rechazar contacto
  Future<void> rejectContact(String requestId) async {
    await _firestore.collection('contact_requests').doc(requestId).update({
      'status': 'rejected',
      'rejectedAt': FieldValue.serverTimestamp(),
    });
  }

  // Obtener contactos aprobados de un niño
  Stream<QuerySnapshot> getApprovedContacts(String childId) {
    return _firestore
        .collection('contacts')
        .where('users', arrayContains: childId)
        .where('status', isEqualTo: 'approved')
        .snapshots();
  }

  // Verificar si un contacto está aprobado
  Future<bool> isContactApproved(String childId, String contactId) async {
    final query = await _firestore
        .collection('contacts')
        .where('users', arrayContains: childId)
        .where('status', isEqualTo: 'approved')
        .get();

    // Verificar que contactId esté en la lista de usuarios
    for (var doc in query.docs) {
      final data = doc.data() as Map<String, dynamic>;
      final users = List<String>.from(data['users'] ?? []);
      if (users.contains(contactId)) {
        return true;
      }
    }

    return false;
  }

  // ==================== MENSAJES ====================

  // Enviar mensaje
  Future<void> sendMessage({
    required String chatId,
    required String senderId,
    required String receiverId,
    required String text,
    String type = 'text', // text, image, video, audio, file
    String? mediaUrl,
    String? fileName,
    int? duration, // Para audio/video en segundos
  }) async {
    // Verificar si es un niño y si el contacto está aprobado
    final senderDoc = await _firestore.collection('users').doc(senderId).get();
    final isParent = senderDoc.data()?['isParent'] ?? true;

    if (!isParent) {
      final isApproved = await isContactApproved(senderId, receiverId);
      if (!isApproved) {
        throw Exception('Contacto no aprobado');
      }
    }

    // Preparar datos del mensaje
    final Map<String, dynamic> messageData = {
      'senderId': senderId,
      'receiverId': receiverId,
      'text': text,
      'type': type,
      'timestamp': FieldValue.serverTimestamp(),
      'isRead': false,
    };

    // Agregar campos opcionales si existen
    if (mediaUrl != null) messageData['mediaUrl'] = mediaUrl;
    if (fileName != null) messageData['fileName'] = fileName;
    if (duration != null) messageData['duration'] = duration;

    // Enviar el mensaje
    await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .add(messageData);

    // Preparar texto del último mensaje según tipo
    String lastMessageText = text;
    switch (type) {
      case 'image':
        lastMessageText = '📷 Imagen';
        break;
      case 'video':
        lastMessageText = '🎥 Video';
        break;
      case 'audio':
        lastMessageText = '🎤 Audio';
        break;
      case 'file':
        lastMessageText = '📄 ${fileName ?? 'Archivo'}';
        break;
    }

    // Actualizar último mensaje del chat
    await _firestore.collection('chats').doc(chatId).set({
      'participants': [senderId, receiverId],
      'lastMessage': lastMessageText,
      'lastMessageTime': FieldValue.serverTimestamp(),
      'lastMessageSender': senderId,
    }, SetOptions(merge: true));
  }

  // Obtener mensajes de un chat
  Stream<QuerySnapshot> getMessages(String chatId) {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots();
  }

  // Obtener lista de chats de un usuario
  Stream<QuerySnapshot> getUserChats(String userId) {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots();
  }

  // Generar ID de chat único entre dos usuarios
  String getChatId(String user1, String user2) {
    final users = [user1, user2]..sort();
    return '${users[0]}_${users[1]}';
  }

  // ==================== REPORTES ====================

  // Crear reporte semanal
  Future<void> createWeeklyReport({
    required String childId,
    required Map<String, dynamic> analysis,
  }) async {
    await _firestore.collection('weekly_reports').add({
      'childId': childId,
      'analysis': analysis,
      'createdAt': FieldValue.serverTimestamp(),
      'weekNumber': DateTime.now().weekday,
      'year': DateTime.now().year,
    });
  }

  // Obtener reportes de un hijo
  Stream<QuerySnapshot> getChildReports(String childId) {
    return _firestore
        .collection('weekly_reports')
        .where('childId', isEqualTo: childId)
        .orderBy('createdAt', descending: true)
        .limit(10)
        .snapshots();
  }

  // ==================== ANÁLISIS DE SENTIMIENTO (para IA) ====================

  // Guardar análisis de mensaje
  Future<void> saveMessageAnalysis({
    required String messageId,
    required String sentiment, // positive, negative, neutral
    required double sentimentScore,
    bool? hasBullying,
  }) async {
    await _firestore.collection('message_analysis').add({
      'messageId': messageId,
      'sentiment': sentiment,
      'sentimentScore': sentimentScore,
      'hasBullying': hasBullying ?? false,
      'analyzedAt': FieldValue.serverTimestamp(),
    });
  }

  // Obtener análisis de mensajes de un niño (última semana)
  Future<List<Map<String, dynamic>>> getWeekAnalysis(String childId) async {
    final weekAgo = DateTime.now().subtract(Duration(days: 7));

    // Obtener todos los chats del niño
    final chatsQuery = await _firestore
        .collection('chats')
        .where('participants', arrayContains: childId)
        .get();

    List<Map<String, dynamic>> analyses = [];

    for (var chatDoc in chatsQuery.docs) {
      final messagesQuery = await _firestore
          .collection('chats')
          .doc(chatDoc.id)
          .collection('messages')
          .where('senderId', isEqualTo: childId)
          .where('timestamp', isGreaterThan: weekAgo)
          .get();

      for (var msgDoc in messagesQuery.docs) {
        final analysisQuery = await _firestore
            .collection('message_analysis')
            .where('messageId', isEqualTo: msgDoc.id)
            .get();

        if (analysisQuery.docs.isNotEmpty) {
          analyses.add(analysisQuery.docs.first.data());
        }
      }
    }

    return analyses;
  }
}
