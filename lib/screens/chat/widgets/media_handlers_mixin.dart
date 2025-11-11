import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path_provider/path_provider.dart';
import '../../../controllers/chat_controller_optimistic.dart';

/// Mixin que proporciona handlers para envío de medios
///
/// Responsabilidades:
/// - Manejar envío de imágenes
/// - Manejar envío de videos con optimistic UI
/// - Manejar grabación de audio
/// - Verificaciones de bloqueo
mixin MediaHandlersMixin<T extends StatefulWidget> on State<T> {
  // Debe ser implementado por el widget que usa este mixin
  ChatControllerOptimistic get controller;
  @override
  BuildContext get context;

  /// Manejar envío de imagen
  Future<void> handleSendImage(ImageSource source) async {
    Navigator.pop(context); // Cerrar bottom sheet

    // Verificar bloqueo
    if (controller.isBlocked || controller.isBlockedBy) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              controller.isBlocked
                  ? 'No puedes enviar mensajes a este contacto porque lo has bloqueado'
                  : 'Este contacto te ha bloqueado',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Envío optimista de imagen
    await controller.sendImage(source: source);
  }

  /// Manejar envío de video con UI optimista
  Future<void> handleSendVideo() async {
    // Verificar bloqueo
    if (controller.isBlocked || controller.isBlockedBy) {
      Navigator.pop(context);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              controller.isBlocked
                  ? 'No puedes enviar mensajes a este contacto porque lo has bloqueado'
                  : 'Este contacto te ha bloqueado',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Cerrar bottom sheet
    Navigator.pop(context);

    // Abrir picker de video (sin compresión en iOS para velocidad)
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
      allowCompression: false,
    );

    if (result == null || result.files.isEmpty) return;

    final String videoPath = result.files.single.path!;

    // Generar thumbnail
    String? thumbnailPath;
    try {
      thumbnailPath = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: (await getTemporaryDirectory()).path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 300,
        quality: 75,
      );
    } catch (e) {
      // Error generating thumbnail - continue without it
    }

    // Crear burbuja optimista inmediatamente
    controller.createOptimisticVideoMessage(
      videoPath: videoPath,
      thumbnailPath: thumbnailPath,
    );

    // Procesar y subir en segundo plano
    // ignore: unawaited_futures
    controller.processAndUploadVideo(videoPath: videoPath).catchError((e) {
      // Error sending video - handled by optimistic UI
    });
  }

  /// Verificar permisos de audio y preparar grabación
  Future<bool> checkAudioPermissions() async {
    // Debe ser implementado por el widget que usa este mixin
    return true;
  }
}
