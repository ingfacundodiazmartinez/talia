import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class UserSettingsService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static final UserSettingsService _instance = UserSettingsService._internal();
  factory UserSettingsService() => _instance;
  UserSettingsService._internal();

  Future<Map<String, dynamic>> loadSettings() async {
    try {
      final doc = await _firestore
          .collection('users')
          .doc(_auth.currentUser?.uid)
          .get();
      return doc.data() ?? {};
    } catch (e) {
      print('Error loading settings: $e');
      return {};
    }
  }

  Future<void> updateSetting(String key, bool value) async {
    try {
      await _firestore.collection('users').doc(_auth.currentUser?.uid).update({
        key: value,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating setting: $e');
      rethrow;
    }
  }

  /// Verifica si el usuario tiene activadas las confirmaciones de lectura
  /// Por defecto es true si no está configurado
  Future<bool> showReadReceipts({String? userId}) async {
    try {
      final uid = userId ?? _auth.currentUser?.uid;
      if (uid == null) return true;

      final doc = await _firestore.collection('users').doc(uid).get();
      final data = doc.data();
      return data?['showReadReceipts'] ?? true;
    } catch (e) {
      print('Error checking showReadReceipts: $e');
      return true; // Default to true en caso de error
    }
  }
}
