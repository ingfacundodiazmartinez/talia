import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Servicio para manejar límites de uso de funcionalidades premium
class UsageLimitsService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static const int CHARACTER_TRANSFORM_MONTHLY_LIMIT = 10;
  static const int FACE_SWAP_MONTHLY_LIMIT = 10;

  /// Obtener el mes actual en formato YYYY-MM
  String _getCurrentMonth() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  /// Verificar si el usuario puede hacer una transformación de personaje
  Future<bool> canUseCharacterTransform() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return false;

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return true; // Primera vez, puede usar
      }

      final data = doc.data()!;
      final month = data['characterTransformMonth'] as String?;
      final count = data['characterTransformCount'] as int? ?? 0;

      // Si es un mes nuevo, puede usar
      if (month != currentMonth) {
        return true;
      }

      // Verificar si no ha superado el límite
      return count < CHARACTER_TRANSFORM_MONTHLY_LIMIT;
    } catch (e) {
      return false;
    }
  }

  /// Obtener el uso actual de transformaciones del mes
  Future<Map<String, dynamic>> getCharacterTransformUsage() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        return {
          'count': 0,
          'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
          'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
        };
      }

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return {
          'count': 0,
          'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
          'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
        };
      }

      final data = doc.data()!;
      final month = data['characterTransformMonth'] as String?;
      final count = data['characterTransformCount'] as int? ?? 0;

      // Si es un mes nuevo, resetear
      if (month != currentMonth) {
        return {
          'count': 0,
          'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
          'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
        };
      }

      return {
        'count': count,
        'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
        'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT - count,
      };
    } catch (e) {
      return {
        'count': 0,
        'limit': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
        'remaining': CHARACTER_TRANSFORM_MONTHLY_LIMIT,
      };
    }
  }

  /// Incrementar el contador de transformaciones después de un uso exitoso
  Future<void> incrementCharacterTransformUsage() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      final currentMonth = _getCurrentMonth();
      final docRef = _firestore.collection('user_limits').doc(user.uid);
      final doc = await docRef.get();

      if (!doc.exists) {
        // Crear documento nuevo
        await docRef.set({
          'characterTransformMonth': currentMonth,
          'characterTransformCount': 1,
          'lastCharacterTransform': FieldValue.serverTimestamp(),
        });
      } else {
        final data = doc.data()!;
        final month = data['characterTransformMonth'] as String?;

        if (month != currentMonth) {
          // Nuevo mes, resetear contador
          await docRef.update({
            'characterTransformMonth': currentMonth,
            'characterTransformCount': 1,
            'lastCharacterTransform': FieldValue.serverTimestamp(),
          });
        } else {
          // Incrementar contador
          await docRef.update({
            'characterTransformCount': FieldValue.increment(1),
            'lastCharacterTransform': FieldValue.serverTimestamp(),
          });
        }
      }

    } catch (e) {
    }
  }

  /// ===== FACE SWAP USAGE LIMITS =====

  /// Verificar si el usuario puede usar face swap
  Future<bool> canUseFaceSwap() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return false;

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return true; // Primera vez, puede usar
      }

      final data = doc.data()!;
      final month = data['faceSwapMonth'] as String?;
      final count = data['faceSwapCount'] as int? ?? 0;

      // Si es un mes nuevo, puede usar
      if (month != currentMonth) {
        return true;
      }

      // Verificar si no ha superado el límite
      return count < FACE_SWAP_MONTHLY_LIMIT;
    } catch (e) {
      return false;
    }
  }

  /// Obtener el uso actual de face swap del mes
  Future<Map<String, dynamic>> getFaceSwapUsage() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        return {
          'count': 0,
          'limit': FACE_SWAP_MONTHLY_LIMIT,
          'remaining': FACE_SWAP_MONTHLY_LIMIT,
        };
      }

      final currentMonth = _getCurrentMonth();
      final doc = await _firestore
          .collection('user_limits')
          .doc(user.uid)
          .get();

      if (!doc.exists) {
        return {
          'count': 0,
          'limit': FACE_SWAP_MONTHLY_LIMIT,
          'remaining': FACE_SWAP_MONTHLY_LIMIT,
        };
      }

      final data = doc.data()!;
      final month = data['faceSwapMonth'] as String?;
      final count = data['faceSwapCount'] as int? ?? 0;

      // Si es un mes nuevo, resetear
      if (month != currentMonth) {
        return {
          'count': 0,
          'limit': FACE_SWAP_MONTHLY_LIMIT,
          'remaining': FACE_SWAP_MONTHLY_LIMIT,
        };
      }

      return {
        'count': count,
        'limit': FACE_SWAP_MONTHLY_LIMIT,
        'remaining': FACE_SWAP_MONTHLY_LIMIT - count,
      };
    } catch (e) {
      return {
        'count': 0,
        'limit': FACE_SWAP_MONTHLY_LIMIT,
        'remaining': FACE_SWAP_MONTHLY_LIMIT,
      };
    }
  }

  /// Incrementar el contador de face swap después de un uso exitoso
  Future<void> incrementFaceSwapUsage() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return;

      final currentMonth = _getCurrentMonth();
      final docRef = _firestore.collection('user_limits').doc(user.uid);
      final doc = await docRef.get();

      if (!doc.exists) {
        // Crear documento nuevo
        await docRef.set({
          'faceSwapMonth': currentMonth,
          'faceSwapCount': 1,
          'lastFaceSwap': FieldValue.serverTimestamp(),
        });
      } else {
        final data = doc.data()!;
        final month = data['faceSwapMonth'] as String?;

        if (month != currentMonth) {
          // Nuevo mes, resetear contador
          await docRef.update({
            'faceSwapMonth': currentMonth,
            'faceSwapCount': 1,
            'lastFaceSwap': FieldValue.serverTimestamp(),
          });
        } else {
          // Incrementar contador
          await docRef.update({
            'faceSwapCount': FieldValue.increment(1),
            'lastFaceSwap': FieldValue.serverTimestamp(),
          });
        }
      }

    } catch (e) {
    }
  }
}
