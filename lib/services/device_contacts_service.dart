/// Servicio para importar contactos del dispositivo
///
/// Lee los contactos del teléfono y busca coincidencias con usuarios registrados
library;

import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:talia/services/remote_logger_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'phone_normalization_service.dart';

class DeviceContactsService {
  static final DeviceContactsService _instance = DeviceContactsService._internal();
  factory DeviceContactsService() => _instance;
  DeviceContactsService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final PhoneNormalizationService _phoneNormalizer = PhoneNormalizationService();

  /// Solicita permiso y devuelve true si fue concedido
  Future<bool> requestPermission() async {
    return await FlutterContacts.requestPermission();
  }

  /// Verifica si ya se tiene permiso
  Future<bool> hasPermission() async {
    final permission = await FlutterContacts.requestPermission(readonly: true);
    return permission;
  }

  /// Obtiene todos los contactos del dispositivo
  Future<List<Contact>> getDeviceContacts() async {
    if (!await hasPermission()) {
      throw Exception('No se tiene permiso para acceder a contactos');
    }

    return await FlutterContacts.getContacts(
      withProperties: true,
      withPhoto: false,
    );
  }

  /// Encuentra contactos del dispositivo que están registrados en la app
  Future<List<RegisteredContact>> findRegisteredContacts() async {
    appLogger.log('📱 [Contacts] Iniciando búsqueda de contactos registrados...', level: 'INFO');

    // 1. Obtener contactos del dispositivo
    final deviceContacts = await getDeviceContacts();
    appLogger.log('📱 [Contacts] Contactos del dispositivo: ${deviceContacts.length}', level: 'INFO');

    // DEBUG: Mostrar los primeros 10 contactos con teléfono
    int debugCount = 0;
    for (final contact in deviceContacts) {
      if (contact.phones.isEmpty) continue;
      appLogger.log('📱 [DEBUG] Contacto: "${contact.displayName}" - Teléfonos: ${contact.phones.map((p) => p.number).join(", ")}', level: 'DEBUG');
      debugCount++;
      if (debugCount >= 10) break;
    }

    // 2. Extraer todos los números de teléfono
    final phoneNumbers = <String>[];
    final contactPhoneMap = <String, Contact>{};
    int processedCount = 0;

    for (final contact in deviceContacts) {
      if (contact.phones.isEmpty) continue;

      for (final phone in contact.phones) {
        final phoneNumber = phone.number;
        if (phoneNumber.isEmpty) continue;

        // DEBUG: Mostrar normalización solo para los primeros 5
        if (processedCount < 5) {
          final normalized = _phoneNormalizer.normalizePhone(phoneNumber);
          final variations = _phoneNormalizer.generateVariations(phoneNumber);
          appLogger.log('📱 [DEBUG #${processedCount + 1}] Original: "$phoneNumber"', level: 'DEBUG');
          appLogger.log('   -> Normalizado: "$normalized"', level: 'INFO');
          appLogger.log('   -> Variaciones: ${variations.join(", ")}', level: 'INFO');
        }

        // Normalizar y guardar variaciones
        final variations = _phoneNormalizer.generateVariations(phoneNumber);
        for (final variation in variations) {
          phoneNumbers.add(variation);
          contactPhoneMap[variation] = contact;
        }

        processedCount++;
      }
    }

    appLogger.log('📱 [Contacts] Números totales procesados: $processedCount', level: 'INFO');
    appLogger.log('📱 [Contacts] Números totales (con variaciones): ${phoneNumbers.length}', level: 'INFO');

    if (phoneNumbers.isEmpty) {
      return [];
    }

    // 3. Buscar en Firestore usuarios con esos números
    // Dividir en batches de 10 (límite de Firestore para 'in' queries)
    final registeredContacts = <RegisteredContact>[];
    final uniquePhones = phoneNumbers.toSet().toList();

    appLogger.log('📱 [Contacts] Números únicos a buscar: ${uniquePhones.length}', level: 'INFO');

    for (var i = 0; i < uniquePhones.length; i += 10) {
      final batch = uniquePhones.skip(i).take(10).toList();

      appLogger.log('📱 [Contacts] Buscando batch ${i ~/ 10 + 1} con ${batch.length} números...', level: 'INFO');

      // DEBUG: Mostrar el primer batch completo
      if (i == 0) {
        appLogger.log('📱 [DEBUG] Primer batch a buscar en Firestore:', level: 'DEBUG');
        for (var j = 0; j < batch.length; j++) {
          appLogger.log('   ${j + 1}. "${batch[j]}"', level: 'INFO');
        }
      }

      final usersQuery = await _firestore
          .collection('users')
          .where('phone', whereIn: batch)
          .get();

      appLogger.log('📱 [Contacts] Encontrados ${usersQuery.docs.length} usuarios en este batch', level: 'INFO');

      // DEBUG: Mostrar qué usuarios se encontraron
      if (usersQuery.docs.isNotEmpty) {
        for (final userDoc in usersQuery.docs) {
          final userData = userDoc.data();
          final userPhone = userData['phone'] as String?;
          final userName = userData['name'] as String?;
          appLogger.log('📱 [DEBUG] ✅ Match encontrado: "$userName" con teléfono "$userPhone"', level: 'INFO');
        }
      }

      for (final userDoc in usersQuery.docs) {
        final userData = userDoc.data();
        final userPhone = userData['phone'] as String?;

        if (userPhone == null) continue;

        // Encontrar el contacto del dispositivo correspondiente
        final deviceContact = contactPhoneMap[userPhone];
        if (deviceContact == null) {
          appLogger.log('📱 [DEBUG] ⚠️ Usuario encontrado en Firestore pero no en contactos del dispositivo: "$userPhone"', level: 'WARNING');
          continue;
        }

        appLogger.log('📱 [DEBUG] ✅ Contacto emparejado: "${deviceContact.displayName}" ($userPhone)', level: 'INFO');

        registeredContacts.add(RegisteredContact(
          userId: userDoc.id,
          name: userData['name'] as String? ?? 'Sin nombre',
          phone: userPhone,
          photoUrl: userData['photoURL'] as String?,
          isParent: userData['isParent'] as bool? ?? false,
          deviceContact: deviceContact,
        ));
      }
    }

    appLogger.log('📱 [Contacts] Total de contactos registrados encontrados: ${registeredContacts.length}', level: 'INFO');

    return registeredContacts;
  }

  /// Obtiene contactos con estadísticas
  Future<ContactsImportResult> getContactsWithStats() async {
    try {
      final deviceContacts = await getDeviceContacts();
      final registeredContacts = await findRegisteredContacts();

      // Contar contactos con números
      final contactsWithPhone = deviceContacts.where((c) => c.phones.isNotEmpty).length;

      return ContactsImportResult(
        totalDeviceContacts: deviceContacts.length,
        contactsWithPhone: contactsWithPhone,
        registeredContacts: registeredContacts,
        success: true,
      );
    } catch (e) {
      appLogger.log('❌ [Contacts] Error obteniendo contactos: $e', level: 'ERROR');
      return ContactsImportResult(
        totalDeviceContacts: 0,
        contactsWithPhone: 0,
        registeredContacts: [],
        success: false,
        error: e.toString(),
      );
    }
  }

  /// Busca un usuario específico por número de teléfono
  Future<RegisteredContact?> findUserByPhone(String phone) async {
    final normalized = _phoneNormalizer.normalizePhone(phone);
    final variations = _phoneNormalizer.generateVariations(phone);

    appLogger.log('📱 [Contacts] Buscando usuario con número: $normalized', level: 'INFO');
    appLogger.log('📱 [Contacts] Variaciones: $variations', level: 'INFO');

    for (final variation in variations) {
      final usersQuery = await _firestore
          .collection('users')
          .where('phone', isEqualTo: variation)
          .limit(1)
          .get();

      if (usersQuery.docs.isNotEmpty) {
        final userDoc = usersQuery.docs.first;
        final userData = userDoc.data();

        appLogger.log('✅ [Contacts] Usuario encontrado con variación: $variation', level: 'INFO');

        return RegisteredContact(
          userId: userDoc.id,
          name: userData['name'] as String? ?? 'Sin nombre',
          phone: userData['phone'] as String,
          photoUrl: userData['photoURL'] as String?,
          isParent: userData['isParent'] as bool? ?? false,
          deviceContact: null,
        );
      }
    }

    appLogger.log('❌ [Contacts] Usuario no encontrado', level: 'ERROR');
    return null;
  }
}

/// Información de un contacto registrado en la app
class RegisteredContact {
  final String userId;
  final String name;
  final String phone;
  final String? photoUrl;
  final bool isParent;
  final Contact? deviceContact;

  RegisteredContact({
    required this.userId,
    required this.name,
    required this.phone,
    required this.photoUrl,
    required this.isParent,
    required this.deviceContact,
  });

  String get displayName {
    if (deviceContact != null) {
      return deviceContact!.displayName;
    }
    return name;
  }
}

/// Resultado de importar contactos
class ContactsImportResult {
  final int totalDeviceContacts;
  final int contactsWithPhone;
  final List<RegisteredContact> registeredContacts;
  final bool success;
  final String? error;

  ContactsImportResult({
    required this.totalDeviceContacts,
    required this.contactsWithPhone,
    required this.registeredContacts,
    required this.success,
    this.error,
  });

  int get registeredCount => registeredContacts.length;

  @override
  String toString() {
    return 'ContactsImportResult(total: $totalDeviceContacts, withPhone: $contactsWithPhone, registered: $registeredCount, success: $success)';
  }
}

/// Global accessor
DeviceContactsService get deviceContacts => DeviceContactsService();
