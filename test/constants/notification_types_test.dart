import 'package:flutter_test/flutter_test.dart';
import 'package:talia/constants/notification_types.dart';

void main() {
  group('NotificationTypes - Mapeo de Preferencias', () {
    test('Chat message debe mapear a messagesEnabled', () {
      final key = NotificationTypes.getPreferenceKey(
        NotificationTypes.chatMessage,
      );
      expect(key, 'messagesEnabled');
    });

    test('Group message debe mapear a messagesEnabled', () {
      final key = NotificationTypes.getPreferenceKey(
        NotificationTypes.groupMessage,
      );
      expect(key, 'messagesEnabled');
    });

    test('Contact request debe mapear a contactRequestsEnabled', () {
      final key = NotificationTypes.getPreferenceKey(
        NotificationTypes.contactRequest,
      );
      expect(key, 'contactRequestsEnabled');
    });

    test('Video/Audio call debe mapear a missedCallsEnabled', () {
      final videoKey = NotificationTypes.getPreferenceKey(
        NotificationTypes.videoCall,
      );
      final audioKey = NotificationTypes.getPreferenceKey(
        NotificationTypes.audioCall,
      );

      expect(videoKey, 'missedCallsEnabled');
      expect(audioKey, 'missedCallsEnabled');
    });

    test('Activity alert debe mapear a activityAlertsEnabled', () {
      final key = NotificationTypes.getPreferenceKey(
        NotificationTypes.activityAlert,
      );
      expect(key, 'activityAlertsEnabled');
    });

    test('Bullying alert debe mapear a activityAlertsEnabled', () {
      final key = NotificationTypes.getPreferenceKey(
        NotificationTypes.bullyingAlert,
      );
      expect(key, 'activityAlertsEnabled');
    });

    test('Story changes debe mapear a whitelistChangesEnabled', () {
      final approvalKey = NotificationTypes.getPreferenceKey(
        NotificationTypes.storyApprovalRequest,
      );
      final approvedKey = NotificationTypes.getPreferenceKey(
        NotificationTypes.storyApproved,
      );

      expect(approvalKey, 'whitelistChangesEnabled');
      expect(approvedKey, 'whitelistChangesEnabled');
    });

    test('Emergency debe retornar null (siempre permitido)', () {
      final key = NotificationTypes.getPreferenceKey(
        NotificationTypes.emergency,
      );
      expect(key, null);
    });

    test('Tipo desconocido debe retornar null', () {
      final key = NotificationTypes.getPreferenceKey('unknown_type');
      expect(key, null);
    });
  });

  group('NotificationTypes - Prioridades', () {
    test('Emergency debe tener prioridad alta', () {
      final priority = NotificationTypes.getPriority(
        NotificationTypes.emergency,
      );
      expect(priority, 'high');
    });

    test('Bullying alert debe tener prioridad alta', () {
      final priority = NotificationTypes.getPriority(
        NotificationTypes.bullyingAlert,
      );
      expect(priority, 'high');
    });

    test('Video call debe tener prioridad alta', () {
      final priority = NotificationTypes.getPriority(
        NotificationTypes.videoCall,
      );
      expect(priority, 'high');
    });

    test('Chat message debe tener prioridad normal', () {
      final priority = NotificationTypes.getPriority(
        NotificationTypes.chatMessage,
      );
      expect(priority, 'normal');
    });

    test('Contact request debe tener prioridad normal', () {
      final priority = NotificationTypes.getPriority(
        NotificationTypes.contactRequest,
      );
      expect(priority, 'normal');
    });

    test('Tipo desconocido debe tener prioridad normal', () {
      final priority = NotificationTypes.getPriority('unknown_type');
      expect(priority, 'normal');
    });
  });

  group('NotificationTypes - Constantes', () {
    test('Todas las constantes deben ser strings únicos', () {
      final types = {
        NotificationTypes.chatMessage,
        NotificationTypes.groupMessage,
        NotificationTypes.contactRequest,
        NotificationTypes.contactApproved,
        NotificationTypes.videoCall,
        NotificationTypes.audioCall,
        NotificationTypes.activityAlert,
        NotificationTypes.bullyingAlert,
        NotificationTypes.emergency,
      };

      // Si hay duplicados, el Set tendrá menos elementos
      expect(types.length, 9);
    });
  });
}
