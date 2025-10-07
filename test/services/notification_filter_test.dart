import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:talia/services/notification_filter.dart';
import 'package:talia/services/notification_preferences_service.dart';
import 'package:talia/constants/notification_types.dart';

// Genera los mocks con: flutter pub run build_runner build
@GenerateMocks([NotificationPreferencesService, FirebaseFirestore])
import 'notification_filter_test.mocks.dart';

void main() {
  late NotificationFilter filter;
  late MockNotificationPreferencesService mockPrefsService;
  late MockFirebaseFirestore mockFirestore;

  setUp(() {
    mockPrefsService = MockNotificationPreferencesService();
    mockFirestore = MockFirebaseFirestore();
    filter = NotificationFilter(
      prefsService: mockPrefsService,
      firestore: mockFirestore,
    );
  });

  group('NotificationFilter - Tipo de Notificación', () {
    test('Debe permitir notificación cuando el tipo está habilitado', () async {
      // Arrange
      when(mockPrefsService.getPreferences()).thenAnswer(
        (_) async => {
          'messagesEnabled': true,
          'doNotDisturbEnabled': false,
        },
      );
      when(mockPrefsService.shouldShowNotification('sender456')).thenAnswer(
        (_) async => true,
      );

      // Act
      final decision = await filter.shouldSendNotification(
        userId: 'user123',
        notificationType: NotificationTypes.chatMessage,
        senderId: 'sender456',
      );

      // Assert
      expect(decision.shouldSend, true);
      expect(decision.reason, contains('permitida'));
    });

    test('Debe bloquear notificación cuando el tipo está deshabilitado', () async {
      // Arrange
      when(mockPrefsService.getPreferences()).thenAnswer(
        (_) async => {
          'messagesEnabled': false,
          'doNotDisturbEnabled': false,
        },
      );
      when(mockPrefsService.shouldShowNotification('sender456')).thenAnswer(
        (_) async => true,
      );

      // Act
      final decision = await filter.shouldSendNotification(
        userId: 'user123',
        notificationType: NotificationTypes.chatMessage,
        senderId: 'sender456',
      );

      // Assert
      expect(decision.shouldSend, false);
      expect(decision.reason, contains('deshabilitado'));
    });

    test('Debe SIEMPRE permitir notificaciones de emergencia', () async {
      // Arrange
      when(mockPrefsService.getPreferences()).thenAnswer(
        (_) async => {
          'messagesEnabled': false,
          'doNotDisturbEnabled': true,
        },
      );

      // Act
      final decision = await filter.shouldSendNotification(
        userId: 'user123',
        notificationType: NotificationTypes.emergency,
      );

      // Assert
      expect(decision.shouldSend, true);
      expect(decision.reason, contains('Emergencia'));
      verifyNever(mockPrefsService.getPreferences()); // No debe consultar prefs
    });
  });

  group('NotificationFilter - Do Not Disturb', () {
    test('Debe bloquear cuando DND está activo', () async {
      // Arrange
      when(mockPrefsService.getPreferences()).thenAnswer(
        (_) async => {
          'messagesEnabled': true,
          'doNotDisturbEnabled': true,
        },
      );
      when(mockPrefsService.shouldShowNotification('sender456')).thenAnswer(
        (_) async => false,
      );

      // Act
      final decision = await filter.shouldSendNotification(
        userId: 'user123',
        notificationType: NotificationTypes.chatMessage,
        senderId: 'sender456',
      );

      // Assert
      expect(decision.shouldSend, false);
      expect(decision.reason, contains('No Molestar'));
    });

    test('Debe permitir cuando el remitente está en excepciones', () async {
      // Arrange
      when(mockPrefsService.getPreferences()).thenAnswer(
        (_) async => {
          'messagesEnabled': true,
          'doNotDisturbEnabled': true,
        },
      );
      when(mockPrefsService.shouldShowNotification('sender456')).thenAnswer(
        (_) async => true, // En excepciones
      );

      // Act
      final decision = await filter.shouldSendNotification(
        userId: 'user123',
        notificationType: NotificationTypes.chatMessage,
        senderId: 'sender456',
      );

      // Assert
      expect(decision.shouldSend, true);
      expect(decision.reason, contains('permitida'));
    });
  });

  group('NotificationFilter - Configuración de Sonido', () {
    test('Debe retornar configuración de sonido del usuario', () async {
      // Arrange
      when(mockPrefsService.getPreferences()).thenAnswer(
        (_) async => {
          'soundEnabled': true,
          'vibrationEnabled': false,
          'inAppSoundEnabled': true,
        },
      );

      // Act
      final config = await filter.getSoundConfig('user123');

      // Assert
      expect(config.soundEnabled, true);
      expect(config.vibrationEnabled, false);
      expect(config.inAppSoundEnabled, true);
    });

    test('Debe usar valores por defecto si hay error', () async {
      // Arrange
      when(mockPrefsService.getPreferences()).thenThrow(Exception('Error'));

      // Act
      final config = await filter.getSoundConfig('user123');

      // Assert (fail-safe)
      expect(config.soundEnabled, true);
      expect(config.vibrationEnabled, true);
      expect(config.inAppSoundEnabled, true);
    });
  });

  group('NotificationFilter - Fail-Safe', () {
    test('Debe permitir notificación si hay error en verificación', () async {
      // Arrange
      when(mockPrefsService.getPreferences()).thenThrow(Exception('Firebase error'));

      // Act
      final decision = await filter.shouldSendNotification(
        userId: 'user123',
        notificationType: NotificationTypes.chatMessage,
      );

      // Assert (fail-safe - permitir en caso de error)
      expect(decision.shouldSend, true);
      expect(decision.reason, contains('Error'));
    });
  });
}
