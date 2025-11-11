/// Servicio de sincronización automática de contactos
///
/// Implementa el patrón WhatsApp/Telegram para detectar contactos:
/// 1. Sincroniza contactos del dispositivo a Firestore
/// 2. Mantiene cache local con Hive
/// 3. Recibe notificaciones cuando nuevos usuarios se registran
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'phone_normalization_service.dart';
import 'device_contacts_service.dart';

class ContactsSyncService {
  static final ContactsSyncService _instance = ContactsSyncService._internal();
  factory ContactsSyncService() => _instance;
  ContactsSyncService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final PhoneNormalizationService _phoneNormalizer = PhoneNormalizationService();
  final DeviceContactsService _deviceContacts = DeviceContactsService();

  static const String _cacheBoxName = 'contacts_sync_cache';
  static const String _deviceNumbersKey = 'device_phone_numbers';
  static const String _lastSyncKey = 'last_sync_timestamp';
  static const String _registeredContactsKey = 'registered_contacts';

  Box? _cacheBox;

  /// Inicializar cache de Hive
  Future<void> initialize() async {
    _cacheBox ??= await Hive.openBox(_cacheBoxName);
  }

  /// Sincronizar contactos del dispositivo con Firestore
  /// Solo para usuarios parent/adult
  Future<void> syncContacts({bool force = false}) async {
    try {
      await initialize();

      final currentUser = _auth.currentUser;
      if (currentUser == null) return;

      // Verificar rol del usuario
      final userDoc = await _firestore.collection('users').doc(currentUser.uid).get();
      final userData = userDoc.data();
      final role = userData?['role'] as String?;

      // Solo sincronizar para parent/adult
      if (role != 'parent' && role != 'adult') {
        return;
      }

      // Verificar si ya sincronizamos recientemente (evitar syncs innecesarios)
      if (!force) {
        final lastSync = _cacheBox?.get(_lastSyncKey) as int?;
        if (lastSync != null) {
          final timeSinceLastSync = DateTime.now().millisecondsSinceEpoch - lastSync;
          // No sincronizar si fue hace menos de 1 hora
          if (timeSinceLastSync < 3600000) {

            // Pero verificar si hay nuevos contactos en el dispositivo
            final hasNewContacts = await hasNewDeviceContacts();
            if (!hasNewContacts) {
              return;
            }

          }
        }
      }


      // 1. Verificar permiso (con manejo robusto de errores)
      bool hasPermission = false;
      try {
        hasPermission = await _deviceContacts.hasPermission();
      } catch (e) {
        return;
      }

      if (!hasPermission) {
        return;
      }

      // 2. Obtener contactos del dispositivo (con manejo robusto de errores)
      List<dynamic> deviceContacts = [];
      try {
        deviceContacts = await _deviceContacts.getDeviceContacts();
      } catch (e) {
        return;
      }

      // 3. Extraer y normalizar números de teléfono
      final normalizedNumbers = <String>{};
      try {
        for (final contact in deviceContacts) {
          try {
            for (final phone in contact.phones) {
              if (phone.number.isEmpty) continue;

              // Normalizar número
              final normalized = _phoneNormalizer.normalizePhone(phone.number);
              if (normalized.isNotEmpty) {
                normalizedNumbers.add(normalized);
              }
            }
          } catch (e) {
            continue;
          }
        }
      } catch (e) {
        return;
      }

      // 4. Guardar en cache local
      try {
        await _cacheBox?.put(_deviceNumbersKey, normalizedNumbers.toList());
      } catch (e) {
      }

      // 5. Sincronizar con Firestore
      try {

        // Usar set con merge: true para crear el campo si no existe
        await _firestore.collection('users').doc(currentUser.uid).set({
          'devicePhoneNumbers': normalizedNumbers.toList(),
          'lastContactsSync': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

      } catch (e) {
        return;
      }

      // 6. Consultar quiénes están registrados en Talia
      List<RegisteredContact> registeredContacts = [];
      try {
        registeredContacts = await _findRegisteredContacts(normalizedNumbers.toList());
      } catch (e) {
        return;
      }

      // 7. Crear contactos automáticamente para matches bidireccionales
      try {
        await _createBidirectionalContacts(currentUser.uid, registeredContacts);
      } catch (e) {
      }

      // 8. Guardar en cache
      try {
        await _cacheBox?.put(_registeredContactsKey, registeredContacts.map((c) => c.toJson()).toList());
        await _cacheBox?.put(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
      } catch (e) {
      }
    } catch (e) {
    }
  }

  /// Buscar contactos registrados en Talia (por lotes de 10)
  Future<List<RegisteredContact>> _findRegisteredContacts(List<String> phoneNumbers) async {
    final registeredContacts = <RegisteredContact>[];

    if (phoneNumbers.isEmpty) {
      return registeredContacts;
    }

    try {
      // Dividir en batches de 10 (límite de Firestore)
      for (var i = 0; i < phoneNumbers.length; i += 10) {
        try {
          final batch = phoneNumbers.skip(i).take(10).toList();

          final usersQuery = await _firestore
              .collection('users')
              .where('phone', whereIn: batch)
              .get();


          for (final userDoc in usersQuery.docs) {
            try {
              final userData = userDoc.data();
              final userPhone = userData['phone'] as String?;

              if (userPhone == null) continue;

              registeredContacts.add(RegisteredContact(
                userId: userDoc.id,
                name: userData['name'] as String? ?? 'Usuario',
                phone: userPhone,
                photoUrl: userData['photoURL'] as String?,
                isParent: userData['isParent'] as bool? ?? false,
                deviceContact: null,
              ));
            } catch (e) {
              continue;
            }
          }
        } catch (e) {
          continue;
        }
      }
    } catch (e) {
    }

    return registeredContacts;
  }

  /// Obtener contactos registrados desde cache
  Future<List<RegisteredContact>> getRegisteredContactsFromCache() async {
    await initialize();

    final cachedData = _cacheBox?.get(_registeredContactsKey) as List?;
    if (cachedData == null) return [];

    return cachedData
        .map((json) => RegisteredContactJson.fromJson(Map<String, dynamic>.from(json)))
        .toList();
  }

  /// Detectar si hay nuevos contactos en el dispositivo
  Future<bool> hasNewDeviceContacts() async {
    try {
      await initialize();

      final hasPermission = await _deviceContacts.hasPermission();
      if (!hasPermission) return false;

      // Obtener números actuales del cache
      final cachedNumbers = _cacheBox?.get(_deviceNumbersKey) as List?;
      if (cachedNumbers == null) return true; // Primera vez

      // Obtener números actuales del dispositivo
      final deviceContacts = await _deviceContacts.getDeviceContacts();
      final currentNumbers = <String>{};

      for (final contact in deviceContacts) {
        for (final phone in contact.phones) {
          if (phone.number.isEmpty) continue;
          final normalized = _phoneNormalizer.normalizePhone(phone.number);
          if (normalized.isNotEmpty) {
            currentNumbers.add(normalized);
          }
        }
      }

      // Comparar
      final cachedSet = Set<String>.from(cachedNumbers.map((e) => e.toString()));
      return currentNumbers.difference(cachedSet).isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Crear contactos automáticamente para matches bidireccionales
  Future<void> _createBidirectionalContacts(
    String currentUserId,
    List<RegisteredContact> registeredContacts,
  ) async {
    if (registeredContacts.isEmpty) {
      return;
    }


    // Obtener el número de teléfono del usuario actual
    final currentUserDoc = await _firestore.collection('users').doc(currentUserId).get();
    final currentUserData = currentUserDoc.data();
    final currentUserPhone = currentUserData?['phone'] as String?;

    if (currentUserPhone == null) {
      return;
    }

    final currentUserPhoneVariations = _phoneNormalizer.generateVariations(currentUserPhone);

    int bidirectionalCount = 0;
    int createdCount = 0;
    int alreadyExistsCount = 0;

    for (final contact in registeredContacts) {
      try {
        // Obtener devicePhoneNumbers del contacto
        final contactDoc = await _firestore.collection('users').doc(contact.userId).get();
        final contactData = contactDoc.data();
        final contactDeviceNumbers = List<String>.from(contactData?['devicePhoneNumbers'] ?? []);

        // Verificar si el contacto tiene al usuario actual en sus números
        final isBidirectional = currentUserPhoneVariations.any(
          (variation) => contactDeviceNumbers.contains(variation),
        );

        if (isBidirectional) {
          bidirectionalCount++;

          // Verificar si ya existe el contacto
          final existingContact = await _firestore
              .collection('contacts')
              .where('users', arrayContains: currentUserId)
              .get();

          final alreadyExists = existingContact.docs.any((doc) {
            final users = List<String>.from(doc.data()['users'] ?? []);
            return users.contains(contact.userId);
          });

          if (alreadyExists) {
            alreadyExistsCount++;
            continue;
          }

          // Crear el documento de contacto con ID consistente
          final users = [currentUserId, contact.userId]..sort();
          final contactId = '${users[0]}_${users[1]}';
          final contactRef = _firestore.collection('contacts').doc(contactId);

          await contactRef.set({
            'users': users,
            'status': 'approved', // ✅ IMPORTANTE: debe estar 'approved' para que aparezca en la UI
            'createdAt': FieldValue.serverTimestamp(),
            'lastMessage': null,
            'lastMessageTime': null,
            'unreadCount_$currentUserId': 0,
            'unreadCount_${contact.userId}': 0,
            'autoCreated': true, // Flag para indicar que fue creado automáticamente
            'source': 'auto_device_sync', // Para consistencia con backend
          });

          createdCount++;
        } else {
        }
      } catch (e) {
        continue;
      }
    }

  }

  /// Limpiar cache
  Future<void> clearCache() async {
    await initialize();
    await _cacheBox?.clear();
  }
}

/// Extensión para serialización de RegisteredContact
extension RegisteredContactJson on RegisteredContact {
  Map<String, dynamic> toJson() => {
    'userId': userId,
    'name': name,
    'phone': phone,
    'photoUrl': photoUrl,
    'isParent': isParent,
  };

  static RegisteredContact fromJson(Map<String, dynamic> json) => RegisteredContact(
    userId: json['userId'] as String,
    name: json['name'] as String,
    phone: json['phone'] as String,
    photoUrl: json['photoUrl'] as String?,
    isParent: json['isParent'] as bool,
    deviceContact: null,
  );
}
