// Script de prueba para verificar notificaciones con fotos
// Ejecutar con: flutter run test_notification_photo.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(TestApp());
}

class TestApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: TestScreen(),
    );
  }
}

class TestScreen extends StatefulWidget {
  @override
  _TestScreenState createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  static const _channel = MethodChannel('com.talia.chat/notifications');

  Future<void> _testNotification({bool withPhoto = true}) async {
    try {
      final result = await _channel.invokeMethod('showCommunicationNotification', {
        'senderId': 'test_user_123',
        'senderName': 'Test User',
        'messageText': withPhoto ? 'Mensaje de prueba CON foto' : 'Mensaje de prueba SIN foto',
        'senderPhotoUrl': withPhoto
          ? 'https://randomuser.me/api/portraits/men/32.jpg'  // URL de prueba
          : null,
        'chatId': 'test_chat_456',
        'isGroup': false,
      });

      print(result == true
        ? '✅ Notificación mostrada exitosamente'
        : '❌ Error mostrando notificación');
    } catch (e) {
      print('Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Test Notificaciones con Foto')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () => _testNotification(withPhoto: true),
              child: Text('Probar Notificación CON Foto'),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => _testNotification(withPhoto: false),
              child: Text('Probar Notificación SIN Foto'),
            ),
            SizedBox(height: 40),
            Text(
              'Notas:\n'
              '1. Primera notificación descargará foto en background\n'
              '2. Segunda vez será instantánea desde cache\n'
              '3. Revisa los logs de Xcode para detalles',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}