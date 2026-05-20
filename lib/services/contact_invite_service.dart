import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/release_logger.dart';

/// Servicio para invitar usuarios a Talia via SMS, WhatsApp o share general
class ContactInviteService {
  static final ContactInviteService _instance = ContactInviteService._internal();
  factory ContactInviteService() => _instance;
  ContactInviteService._internal();

  // URLs de las tiendas de apps
  static const String _appStoreUrl = 'https://apps.apple.com/app/talia/id6738943798';
  static const String _playStoreUrl = 'https://play.google.com/store/apps/details?id=com.talia.chat';

  /// Compartir invitación via el share sheet del sistema
  Future<void> shareInvite(String contactName) async {
    try {
      final message = '''
Hola $contactName!

Te invito a descargar Talia, una app de chat segura para familias.

Descarga gratis:
iOS: $_appStoreUrl
Android: $_playStoreUrl
''';

      await SharePlus.instance.share(ShareParams(text: message, subject: 'Invitación a Tália'));
      ReleaseLogger.log('Invitación compartida para $contactName', tag: 'ContactInvite');
    } catch (e) {
      ReleaseLogger.error('Error compartiendo invitación: $e', tag: 'ContactInvite');
      rethrow;
    }
  }

  /// Enviar invitación via SMS
  Future<bool> sendSmsInvite(String phoneNumber, String contactName) async {
    try {
      final message = Uri.encodeComponent(
        'Hola $contactName! Descarga Tália para chatear conmigo de forma segura: $_playStoreUrl'
      );

      // Normalizar número (quitar espacios, guiones)
      final cleanPhone = phoneNumber.replaceAll(RegExp(r'[\s\-\(\)]'), '');
      final uri = Uri.parse('sms:$cleanPhone?body=$message');

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        ReleaseLogger.log('SMS de invitación iniciado para $contactName', tag: 'ContactInvite');
        return true;
      } else {
        ReleaseLogger.error('No se puede abrir la app de SMS', tag: 'ContactInvite');
        return false;
      }
    } catch (e) {
      ReleaseLogger.error('Error enviando SMS de invitación: $e', tag: 'ContactInvite');
      return false;
    }
  }

  /// Enviar invitación via WhatsApp
  Future<bool> sendWhatsAppInvite(String phoneNumber, String contactName) async {
    try {
      final message = Uri.encodeComponent(
        'Hola $contactName! Descarga Tália para chatear conmigo de forma segura. Es una app ideal para familias: $_playStoreUrl'
      );

      // Normalizar número (quitar +, espacios, guiones)
      String cleanPhone = phoneNumber.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');

      // Si no empieza con código de país, asumir que es de Argentina
      if (!cleanPhone.startsWith('54') && cleanPhone.length <= 10) {
        cleanPhone = '54$cleanPhone';
      }

      final uri = Uri.parse('https://wa.me/$cleanPhone?text=$message');

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        ReleaseLogger.log('WhatsApp de invitación iniciado para $contactName', tag: 'ContactInvite');
        return true;
      } else {
        ReleaseLogger.error('No se puede abrir WhatsApp', tag: 'ContactInvite');
        return false;
      }
    } catch (e) {
      ReleaseLogger.error('Error enviando WhatsApp de invitación: $e', tag: 'ContactInvite');
      return false;
    }
  }

  /// Obtener mensaje de invitación personalizado
  String getInviteMessage(String contactName) {
    return '''
Hola $contactName!

Te invito a descargar Talia, una app de chat segura para familias.

Con Talia puedes:
- Chatear de forma segura
- Hacer videollamadas
- Compartir fotos y videos
- Y mucho más!

Descarga gratis:
iOS: $_appStoreUrl
Android: $_playStoreUrl
''';
  }
}
