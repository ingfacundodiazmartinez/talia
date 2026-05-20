import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Servicio para enviar reportes de soporte
class SupportService {
  static final SupportService _instance = SupportService._internal();
  factory SupportService() => _instance;
  SupportService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Envía un reporte de soporte
  Future<void> submitReport({
    required String category,
    required String title,
    required String description,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Usuario no autenticado');
    }

    await _firestore.collection('support_reports').add({
      'userId': user.uid,
      'userEmail': user.email,
      'category': category,
      'title': title,
      'description': description,
      'status': 'pending',
      'priority': _getPriorityFromCategory(category),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'deviceInfo': {'platform': 'mobile', 'appVersion': '1.0.0'},
    });
  }

  String _getPriorityFromCategory(String category) {
    switch (category) {
      case 'Problema de seguridad':
        return 'high';
      case 'Error técnico':
      case 'Problema de conexión':
        return 'medium';
      case 'Error en la interfaz':
      case 'Sugerencia de mejora':
      case 'Otro':
      default:
        return 'low';
    }
  }
}
