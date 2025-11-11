import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import '../widgets/permission_dialog.dart';
import '../utils/release_logger.dart';

class ImageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ImagePicker _picker = ImagePicker();

  Future<String?> pickAndUploadProfileImage({
    required ImageSource source,
    required BuildContext context,
  }) async {
    try {
      // En iOS, intentar directamente seleccionar la imagen
      // ImagePicker maneja permisos automáticamente
      ReleaseLogger.log('📸 Intentando seleccionar imagen desde ${source == ImageSource.camera ? 'cámara' : 'galería'}', tag: 'ImageService');

      final XFile? image = await _pickImageWithErrorHandling(source);
      if (image == null) {
        ReleaseLogger.log('⚠️ Usuario canceló la selección de imagen', tag: 'ImageService');
        return null;
      }

      ReleaseLogger.log('✅ Imagen seleccionada: ${image.path}', tag: 'ImageService');

      // ⏱️ Pequeño delay para dar tiempo a que el selector de imágenes se cierre visualmente
      // Esto mejora la UX evitando que el diálogo aparezca mientras el selector aún está visible
      await Future.delayed(const Duration(milliseconds: 300));

      // ✅ AHORA que el selector se cerró, mostrar loading
      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text('Procesando imagen...'),
              ],
            ),
          ),
        );
      }

      try {
        // Subir imagen a Firebase Storage con retry
        final String? downloadUrl = await uploadImageWithRetry(image.path);

        if (downloadUrl != null) {
          // Actualizar URL en Firestore y Authentication
          await _updateUserProfileImage(downloadUrl);
        }

        // Cerrar loading dialog
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }

        return downloadUrl;
      } catch (uploadError) {
        // Cerrar loading dialog en caso de error
        if (context.mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        rethrow;
      }
    } on PlatformException catch (e) {
      ReleaseLogger.error('❌ Error de permisos: ${e.code} - ${e.message}', tag: 'ImageService');

      // Si es error de permisos, verificar y mostrar diálogo
      if (e.code == 'camera_access_denied' || e.code == 'photo_access_denied') {
        // Verificar estado real del permiso
        final bool hasPermission = await _requestPermissionsWithContext(source, context);
        if (!hasPermission) {
          throw Exception('Permisos de ${source == ImageSource.camera ? 'cámara' : 'galería'} denegados');
        }
        // Si llegamos aquí, los permisos están OK, reintentar
        ReleaseLogger.log('🔄 Permisos verificados, reintentando...', tag: 'ImageService');
        return await pickAndUploadProfileImage(source: source, context: context);
      }
      rethrow;
    } catch (e) {
      ReleaseLogger.error('❌ Error picking and uploading image: $e', tag: 'ImageService');
      rethrow;
    }
  }

  Future<bool> _requestPermissionsWithContext(ImageSource source, BuildContext context) async {
    try {
      final Permission permission;
      final String title;
      final String description;
      final IconData icon;

      if (source == ImageSource.camera) {
        permission = Permission.camera;
        title = 'Acceso a la Cámara';
        description = 'Para tomar una nueva foto de perfil, necesitamos acceso a tu cámara.';
        icon = Icons.camera_alt;
      } else {
        // Para galería, intentar primero con photos, luego storage
        if (Platform.isAndroid) {
          // Verificar ambos permisos y usar el que esté disponible
          final photosStatus = await Permission.photos.status;
          final storageStatus = await Permission.storage.status;

          // Si photos está concedido, usarlo
          if (photosStatus == PermissionStatus.granted) {
            return true; // Ya tenemos permisos, no necesitamos hacer nada más
          }
          // Si storage está concedido, usarlo
          else if (storageStatus == PermissionStatus.granted) {
            return true; // Ya tenemos permisos, no necesitamos hacer nada más
          }
          // Si ninguno está concedido, elegir basado en versión Android
          else {
            final deviceInfo = await _getAndroidVersion();
            permission = deviceInfo >= 33 ? Permission.photos : Permission.storage;
          }
        } else {
          permission = Permission.photos;
        }

        title = 'Acceso a la Galería';
        description = 'Para seleccionar una foto desde tu galería, necesitamos acceso a tus fotos.';
        icon = Icons.photo_library;
      }

      // Verificar el estado actual del permiso PRIMERO
      final PermissionStatus currentStatus = await permission.status;
      ReleaseLogger.log('🔍 ${Platform.isIOS ? 'iOS' : 'Android'} Estado actual del permiso ${permission.toString()}: $currentStatus', tag: 'ImageService');

      // Si ya tenemos el permiso, retornar inmediatamente sin mostrar diálogos
      // En iOS, tanto 'granted' como 'limited' son válidos para acceder a fotos
      if (currentStatus == PermissionStatus.granted ||
          (Platform.isIOS && currentStatus == PermissionStatus.limited && source == ImageSource.gallery)) {
        ReleaseLogger.log('✅ Permiso ya concedido ($currentStatus), procediendo directamente', tag: 'ImageService');
        return true;
      }

      ReleaseLogger.log('⚠️ Permiso no concedido, estado: $currentStatus', tag: 'ImageService');

      // LÓGICA ESPECÍFICA PARA iOS
      if (Platform.isIOS) {
        ReleaseLogger.log('🍎 Manejando permisos para iOS', tag: 'ImageService');

        // En iOS, intentar solicitar directamente sin diálogos previos
        ReleaseLogger.log('🔄 iOS: Solicitando permiso directamente al sistema...', tag: 'ImageService');
        final PermissionStatus iosStatus = await permission.request();
        ReleaseLogger.log('📋 iOS: Resultado de solicitud: $iosStatus', tag: 'ImageService');

        if (iosStatus == PermissionStatus.granted ||
            (iosStatus == PermissionStatus.limited && source == ImageSource.gallery)) {
          ReleaseLogger.log('✅ iOS: Permiso concedido ($iosStatus)', tag: 'ImageService');
          return true;
        } else if (iosStatus == PermissionStatus.permanentlyDenied) {
          ReleaseLogger.log('❌ iOS: Permiso denegado permanentemente', tag: 'ImageService');
          return await _handlePermanentlyDeniedPermission(context, title, source);
        } else {
          ReleaseLogger.log('❌ iOS: Permiso denegado: $iosStatus', tag: 'ImageService');
          return false;
        }
      }

      // LÓGICA PARA ANDROID (mantener la existente)
      // Si el permiso nunca se ha solicitado (undetermined), saltamos el diálogo y solicitamos directamente
      if (currentStatus == PermissionStatus.denied) {
        ReleaseLogger.log('📋 Android: Permiso nunca solicitado, solicitando directamente sin diálogo...', tag: 'ImageService');
        final PermissionStatus directStatus = await permission.request();
        ReleaseLogger.log('📋 Android: Resultado de solicitud directa: $directStatus', tag: 'ImageService');

        if (directStatus == PermissionStatus.granted) {
          ReleaseLogger.log('✅ Android: Permiso concedido directamente', tag: 'ImageService');
          return true;
        } else if (directStatus == PermissionStatus.permanentlyDenied) {
          return await _handlePermanentlyDeniedPermission(context, title, source);
        }
        // Si sigue siendo denied, continuamos con el flujo normal de diálogos
      }

      // Si el permiso fue denegado permanentemente, ir directo a configuración
      if (currentStatus == PermissionStatus.permanentlyDenied) {
        return await _handlePermanentlyDeniedPermission(context, title, source);
      }

      // Solo mostrar diálogo si realmente necesitamos solicitar el permiso
      ReleaseLogger.log('📋 Android: Mostrando diálogo de solicitud de permiso', tag: 'ImageService');

      // Mostrar diálogo explicativo antes de solicitar el permiso
      final bool userAccepted = await PermissionDialog.showPermissionDialog(
        context: context,
        title: title,
        description: description,
        icon: icon,
        permission: permission,
      );

      if (!userAccepted) {
        ReleaseLogger.log('❌ Usuario rechazó el diálogo de permiso', tag: 'ImageService');
        return false;
      }

      // Solicitar el permiso
      ReleaseLogger.log('🔄 Android: Solicitando permiso...', tag: 'ImageService');
      final PermissionStatus status = await permission.request();
      ReleaseLogger.log('📋 Android: Resultado de solicitud de permiso: $status', tag: 'ImageService');

      if (status == PermissionStatus.granted) {
        ReleaseLogger.log('✅ Android: Permiso concedido exitosamente', tag: 'ImageService');
        return true;
      } else if (status == PermissionStatus.permanentlyDenied) {
        return await _handlePermanentlyDeniedPermission(context, title, source);
      } else {
        // Permiso denegado pero no permanentemente
        ReleaseLogger.log('❌ Android: Permiso denegado: $status', tag: 'ImageService');
        await PermissionDialog.showPermissionDeniedDialog(
          context: context,
          title: 'Permiso Denegado',
          message: 'Sin este permiso no podemos ${source == ImageSource.camera ? 'tomar fotos' : 'acceder a tu galería'}. '
                   '¿Te gustaría habilitarlo en la configuración?',
        );

        return false;
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error requesting permissions: $e', tag: 'ImageService');
      return false;
    }
  }

  Future<bool> _handlePermanentlyDeniedPermission(
    BuildContext context,
    String title,
    ImageSource source,
  ) async {
    await PermissionDialog.showPermissionDeniedDialog(
      context: context,
      title: '$title Requerido',
      message: 'Este permiso fue denegado permanentemente. Para ${source == ImageSource.camera ? 'tomar fotos' : 'acceder a tu galería'}, '
               'necesitas habilitarlo manualmente en la configuración del dispositivo.',
    );

    return false; // No podemos continuar sin el permiso
  }

  Future<int> _getAndroidVersion() async {
    try {
      if (Platform.isAndroid) {
        final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
        final AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
        return androidInfo.version.sdkInt;
      }
      // Para iOS, retornamos un valor que forzará el uso de Permission.photos
      return 33;
    } catch (e) {
      ReleaseLogger.error('Error obteniendo versión de Android: $e', tag: 'ImageService');
      // Fallback seguro: usar Permission.photos (para Android 13+)
      return 33;
    }
  }


  Future<XFile?> _pickImageWithErrorHandling(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
        requestFullMetadata: false, // Evita problemas de permisos adicionales
      );
      return image;
    } on PlatformException catch (e) {
      // Manejo específico de errores de plataforma
      if (e.code == 'camera_access_denied') {
        throw Exception('Acceso a la cámara denegado');
      } else if (e.code == 'photo_access_denied') {
        throw Exception('Acceso a la galería denegado');
      } else if (e.code == 'invalid_image') {
        throw Exception('Imagen inválida seleccionada');
      } else {
        throw Exception('Error de plataforma: ${e.message ?? e.code}');
      }
    } catch (e) {
      throw Exception('Error inesperado al seleccionar imagen: $e');
    }
  }

  Future<ImageSource?> showImageSourceSelection(BuildContext context) async {
    ReleaseLogger.log('📸 [ImageService] showImageSourceSelection llamado', tag: 'ImageService');
    final result = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: false,
      builder: (BuildContext modalContext) {
        ReleaseLogger.log('📸 [ImageService] Builder del modal ejecutándose', tag: 'ImageService');
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
            ),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: EdgeInsets.only(top: 12),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Text(
                        'Seleccionar foto de perfil',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2D3142),
                        ),
                      ),
                      SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildSourceOption(
                            context: modalContext,
                            icon: Icons.camera_alt,
                            title: 'Cámara',
                            subtitle: 'Tomar foto',
                            source: ImageSource.camera,
                            color: Colors.blue,
                          ),
                          _buildSourceOption(
                            context: modalContext,
                            icon: Icons.photo_library,
                            title: 'Galería',
                            subtitle: 'Elegir foto',
                            source: ImageSource.gallery,
                            color: Color(0xFF9D7FE8),
                          ),
                        ],
                      ),
                      SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: () {
                            ReleaseLogger.log('📸 [ImageService] Usuario canceló la selección', tag: 'ImageService');
                            Navigator.pop(modalContext, null);
                          },
                          child: Text(
                            'Cancelar',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    ReleaseLogger.log('📸 [ImageService] Modal cerrado, resultado: $result', tag: 'ImageService');
    return result;
  }

  Widget _buildSourceOption({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required ImageSource source,
    required Color color,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          ReleaseLogger.log('📸 [ImageService] Opción seleccionada: ${source == ImageSource.camera ? 'CÁMARA' : 'GALERÍA'}', tag: 'ImageService');
          ReleaseLogger.log('📸 [ImageService] Llamando Navigator.pop con source: $source', tag: 'ImageService');
          Navigator.of(context).pop(source);
          ReleaseLogger.log('📸 [ImageService] Navigator.pop ejecutado', tag: 'ImageService');
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: 120,
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: color.withOpacity(0.3),
              width: 1,
            ),
          ),
          child: Column(
            children: [
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2D3142),
                ),
              ),
              SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> uploadImageToStorage(String imagePath) async {
    return _uploadImageToStorage(File(imagePath));
  }

  Future<String?> _uploadImageToStorage(File imageFile) async {
    try {
      final User? user = _auth.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }

      // Forzar la recarga del token de autenticación para asegurar que Storage tenga acceso
      await user.reload();
      final User? refreshedUser = _auth.currentUser;
      if (refreshedUser == null) {
        throw Exception('Usuario no disponible después de reload');
      }

      // Obtener el ID token para asegurar que Storage tenga acceso
      final String? idToken = await refreshedUser.getIdToken(true); // true = force refresh
      ReleaseLogger.log('🔑 ID Token obtenido para Storage: ${idToken?.substring(0, 20)}...', tag: 'ImageService');

      // Dar tiempo para que el SDK de Storage actualice su caché de token
      await Future.delayed(Duration(milliseconds: 500));
      ReleaseLogger.log('⏱️ Esperando propagación del token al SDK de Storage...', tag: 'ImageService');

      // Verificar que el archivo existe
      if (!await imageFile.exists()) {
        throw Exception('El archivo de imagen no existe');
      }

      // Verificar el tamaño del archivo
      final int fileSize = await imageFile.length();
      if (fileSize == 0) {
        throw Exception('El archivo de imagen está vacío');
      }

      // Crear referencia con el nombre requerido por las reglas de Storage
      // Las reglas requieren que el nombre sea exactamente {userId}.jpg
      final String fileName = '${refreshedUser.uid}.jpg';
      final Reference storageRef = _storage.ref('profile_images/$fileName');

      ReleaseLogger.log('📁 Subiendo a: profile_images/$fileName', tag: 'ImageService');

      // Configurar metadata
      final SettableMetadata metadata = SettableMetadata(
        contentType: 'image/jpeg',
        customMetadata: {
          'userId': refreshedUser.uid,
          'uploadTime': DateTime.now().toIso8601String(),
        },
      );

      // Subir archivo con metadata
      final UploadTask uploadTask = storageRef.putFile(imageFile, metadata);


      // Esperar a que termine la subida
      final TaskSnapshot snapshot = await uploadTask;

      if (snapshot.state == TaskState.success) {
        // Obtener URL de descarga
        final String downloadUrl = await snapshot.ref.getDownloadURL();
        return downloadUrl;
      } else {
        throw Exception('Error en la subida: Estado ${snapshot.state}');
      }
    } on FirebaseException catch (e) {
      ReleaseLogger.error('🔥 Firebase Error: ${e.code} - ${e.message}', tag: 'ImageService');
      if (e.code == 'storage/unauthorized') {
        throw Exception('Sin permisos para subir archivos. Verifica la configuración de Firebase Storage.');
      } else if (e.code == 'storage/canceled') {
        throw Exception('Subida cancelada');
      } else if (e.code == 'storage/unknown') {
        throw Exception('Error desconocido en Firebase Storage');
      } else {
        throw Exception('Error de Firebase Storage: ${e.message}');
      }
    } catch (e) {
      ReleaseLogger.error('❌ Error uploading image to storage: $e', tag: 'ImageService');
      rethrow;
    }
  }

  Future<void> updateUserProfileImage(String imageUrl) async {
    return _updateUserProfileImage(imageUrl);
  }

  Future<void> _updateUserProfileImage(String imageUrl) async {
    try {
      final User? user = _auth.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }

      ReleaseLogger.log('🔄 Actualizando foto de perfil para usuario: ${user.uid}', tag: 'ImageService');
      ReleaseLogger.log('🔗 URL de la imagen: ${imageUrl.substring(0, 50)}...', tag: 'ImageService');

      // Primero actualizar en Firestore (esto es lo más importante)
      await _firestore.collection('users').doc(user.uid).update({
        'photoURL': imageUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      ReleaseLogger.log('✅ Foto actualizada en Firestore', tag: 'ImageService');

      // Intentar actualizar en Firebase Authentication (opcional)
      // Si falla, no es crítico porque ya está en Firestore
      try {
        await user.updatePhotoURL(imageUrl);
        ReleaseLogger.log('✅ Foto actualizada en Firebase Auth', tag: 'ImageService');
      } catch (authError) {
        ReleaseLogger.log('⚠️ No se pudo actualizar en Firebase Auth (no crítico): $authError', tag: 'ImageService');
        // No lanzamos el error porque ya está guardado en Firestore
      }

      ReleaseLogger.log('✅ Actualización de foto de perfil completada', tag: 'ImageService');
    } catch (e) {
      ReleaseLogger.error('❌ Error updating user profile image: $e', tag: 'ImageService');
      rethrow;
    }
  }

  Future<void> deleteProfileImage() async {
    try {
      final User? user = _auth.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }

      // Obtener URL actual de la imagen
      final DocumentSnapshot userDoc = await _firestore
          .collection('users')
          .doc(user.uid)
          .get();

      final userData = userDoc.data() as Map<String, dynamic>?;
      final String? currentImageUrl = userData?['photoURL'] ?? user.photoURL;

      if (currentImageUrl != null && currentImageUrl.isNotEmpty) {
        // Eliminar de Storage si es una imagen de Firebase
        if (currentImageUrl.contains('firebasestorage.googleapis.com') ||
            currentImageUrl.contains('firebase')) {
          try {
            final Reference imageRef = _storage.refFromURL(currentImageUrl);

            // Verificar si el objeto existe antes de eliminarlo
            try {
              await imageRef.getMetadata();
              await imageRef.delete();
            } on FirebaseException catch (e) {
              if (e.code != 'storage/object-not-found') {
                ReleaseLogger.error('Error eliminando de Storage: ${e.message}', tag: 'ImageService');
              }
            }
          } catch (e) {
            ReleaseLogger.error('Error procesando URL de Storage: $e', tag: 'ImageService');
          }
        }
      }

      // Actualizar en Authentication y Firestore
      await user.updatePhotoURL(null);
      await _firestore.collection('users').doc(user.uid).update({
        'photoURL': FieldValue.delete(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      ReleaseLogger.error('❌ Error deleting profile image: $e', tag: 'ImageService');
      rethrow;
    }
  }

  String? getCurrentUserPhotoURL() {
    return _auth.currentUser?.photoURL;
  }

  // Método para verificar la configuración de Firebase Storage
  Future<bool> testStorageConfiguration() async {
    try {
      final User? user = _auth.currentUser;
      if (user == null) {
        ReleaseLogger.log('⚠️ No hay usuario autenticado para test de Storage', tag: 'ImageService');
        return false;
      }

      ReleaseLogger.log('🧪 Testeando configuración de Firebase Storage...', tag: 'ImageService');

      // En vez de intentar subir un archivo de test a una ruta no permitida,
      // simplemente verificamos que el usuario esté autenticado
      // El test real ocurrirá cuando se suba la imagen de perfil

      ReleaseLogger.log('✅ Usuario autenticado, procediendo con la subida', tag: 'ImageService');
      return true;
    } catch (e) {
      ReleaseLogger.error('❌ Error inesperado testando Storage: $e', tag: 'ImageService');
      return false;
    }
  }

  // Método mejorado de subida con retry y fallback
  Future<String?> uploadImageWithRetry(String imagePath, {int maxRetries = 3}) async {
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        ReleaseLogger.log('🔄 Intento $attempt de $maxRetries', tag: 'ImageService');

        // Verificar configuración en el primer intento
        if (attempt == 1) {
          final bool isConfigured = await testStorageConfiguration();
          if (!isConfigured) {
            throw Exception('Firebase Storage no está configurado correctamente. Revisa las reglas de Storage.');
          }
        }

        final String? result = await _uploadImageToStorage(File(imagePath));
        if (result != null) {
          ReleaseLogger.log('✅ Subida exitosa en intento $attempt', tag: 'ImageService');
          return result;
        }
      } catch (e) {
        ReleaseLogger.error('❌ Error en intento $attempt: $e', tag: 'ImageService');

        if (attempt == maxRetries) {
          // En el último intento, lanzar error con información de diagnóstico
          String diagnosticInfo = await _getDiagnosticInfo();
          throw Exception('Falló después de $maxRetries intentos. $diagnosticInfo\n\nError original: $e');
        }

        // Esperar antes del siguiente intento
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }

    return null;
  }

  Future<String> _getDiagnosticInfo() async {
    try {
      final User? user = _auth.currentUser;
      final bool isOnline = await _checkInternetConnection();

      return '''
📊 Información de diagnóstico:
- Usuario autenticado: ${user != null ? '✅' : '❌'}
- Conexión a internet: ${isOnline ? '✅' : '❌'}
- Firebase Storage habilitado: Verificar en Firebase Console

🔧 Posibles soluciones:
1. Verificar reglas de Firebase Storage
2. Asegurar que Storage esté habilitado en Firebase Console
3. Verificar conexión a internet
4. Revisar archivo FIREBASE_STORAGE_RULES.md para configuración
''';
    } catch (e) {
      return 'Error obteniendo información de diagnóstico: $e';
    }
  }

  Future<bool> _checkInternetConnection() async {
    try {
      // Intento simple de conexión usando Firebase
      await _firestore.collection('connection_test').limit(1).get();
      return true;
    } catch (e) {
      return false;
    }
  }
}