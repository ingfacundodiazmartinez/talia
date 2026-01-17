import 'package:cloud_firestore/cloud_firestore.dart';
import 'notification_service.dart';
import 'services/user_role_service.dart';
import 'utils/release_logger.dart';

// ⚠️ ADVERTENCIA DE SEGURIDAD ⚠️
// Este servicio está DESHABILITADO por razones de seguridad.
// NO usar directamente desde el cliente - la API key estaría expuesta.
//
// USAR EN SU LUGAR: Cloud Function 'generateChildReport' (functions/index.js)
// La Cloud Function maneja el análisis de IA de forma segura server-side.
//
// Si necesitas análisis de IA, llama a la Cloud Function desde el cliente,
// NO uses este servicio directamente.

class GeminiAIService {
  final FirebaseFirestore _firestore;

  GeminiAIService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  // Analizar mensajes por lotes
  Future<Map<String, dynamic>> analyzeMessagesBatch(String childId) async {
    try {
      // 1. Obtener todos los mensajes del hijo (últimos 7 días EXACTOS)
      final DateTime now = DateTime.now();
      final DateTime sevenDaysAgo = now.subtract(Duration(days: 7));

      ReleaseLogger.log('Analizando mensajes desde: ${sevenDaysAgo.toString()} hasta: ${now.toString()}', tag: 'GeminiAIService');

      final chatsQuery = await _firestore
          .collection('chats')
          .where('participants', arrayContains: childId)
          .get();

      List<Map<String, dynamic>> allMessages = [];

      for (var chatDoc in chatsQuery.docs) {
        final messagesQuery = await _firestore
            .collection('chats')
            .doc(chatDoc.id)
            .collection('messages')
            .where('senderId', isEqualTo: childId)
            .where(
              'timestamp',
              isGreaterThanOrEqualTo: Timestamp.fromDate(sevenDaysAgo),
            )
            .where('timestamp', isLessThanOrEqualTo: Timestamp.fromDate(now))
            .orderBy('timestamp', descending: false)
            .get();

        for (var msgDoc in messagesQuery.docs) {
          final data = msgDoc.data();
          final timestamp = data['timestamp'] as Timestamp?;

          // Verificación adicional: asegurar que está en los últimos 7 días
          if (timestamp != null) {
            final messageDate = timestamp.toDate();
            if (messageDate.isAfter(sevenDaysAgo) &&
                messageDate.isBefore(now.add(Duration(seconds: 1)))) {
              allMessages.add({
                'id': msgDoc.id,
                'text': data['text'] ?? '',
                'timestamp': timestamp,
                'date': messageDate,
              });
            }
          }
        }
      }

      if (allMessages.isEmpty) {
        return {
          'status': 'no_data',
          'message': 'No hay mensajes de los últimos 7 días para analizar',
        };
      }

      // Ordenar mensajes por fecha
      allMessages.sort(
        (a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime),
      );

      ReleaseLogger.log('Total de mensajes encontrados (últimos 7 días): ${allMessages.length}', tag: 'GeminiAIService');
      ReleaseLogger.log('Primer mensaje: ${allMessages.first['date']}, Último mensaje: ${allMessages.last['date']}', tag: 'GeminiAIService');

      ReleaseLogger.log('Analizando ${allMessages.length} mensajes con IA...', tag: 'GeminiAIService');

      // 2. Este método está deshabilitado por seguridad
      // Usar Cloud Function 'generateChildReport' en su lugar

      // 3. Llamar a Gemini API (DESHABILITADO - usar Cloud Function en su lugar)
      throw Exception(
        '🚫 SEGURIDAD: No usar Gemini desde cliente. Usar Cloud Function "generateChildReport"',
      );

      /* CÓDIGO DESHABILITADO POR SEGURIDAD
      final response = await http.post(
        Uri.parse('$_baseUrl?key=$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': {
            'temperature': 0.4,
            'topK': 32,
            'topP': 1,
            'maxOutputTokens': 2048,
          },
        }),
      );

      if (response.statusCode != 200) {
        print('❌ Error API: ${response.statusCode} - ${response.body}');
        return {
          'status': 'error',
          'message': 'Error en API: ${response.statusCode}',
        };
      }

      final responseData = jsonDecode(response.body);
      final aiResponse =
          responseData['candidates'][0]['content']['parts'][0]['text'];

      print('🤖 Respuesta de IA: $aiResponse');

      // 4. Parsear respuesta JSON de la IA
      // Limpiar la respuesta (remover markdown si existe)
      String cleanedResponse = aiResponse.trim();
      if (cleanedResponse.startsWith('```json')) {
        cleanedResponse = cleanedResponse.substring(7);
      }
      if (cleanedResponse.startsWith('```')) {
        cleanedResponse = cleanedResponse.substring(3);
      }
      if (cleanedResponse.endsWith('```')) {
        cleanedResponse = cleanedResponse.substring(
          0,
          cleanedResponse.length - 3,
        );
      }
      cleanedResponse = cleanedResponse.trim();

      final aiAnalysis = jsonDecode(cleanedResponse);

      // 5. Guardar análisis en Firestore
      await _firestore.collection('ai_batch_analysis').add({
        'childId': childId,
        'messagesAnalyzed': allMessages.length,
        'analysis': aiAnalysis,
        'analyzedAt': FieldValue.serverTimestamp(),
      });

      // 6. Crear alertas basadas en análisis ponderado
      await _evaluateAndCreateAlerts(childId, aiAnalysis);

      return {
        'status': 'success',
        'analysis': aiAnalysis,
        'messagesAnalyzed': allMessages.length,
        'periodStart': sevenDaysAgo,
        'periodEnd': now,
      };
      */ // FIN CÓDIGO DESHABILITADO
    } catch (e) {
      ReleaseLogger.error('Error en análisis por lotes: $e', tag: 'GeminiAIService');
      return {'status': 'error', 'message': 'Error: $e'};
    }
  }

  // Generar reporte semanal con IA
  Future<Map<String, dynamic>> generateWeeklyReportWithAI(
    String childId,
  ) async {
    try {
      // 1. Analizar mensajes con IA
      final aiResult = await analyzeMessagesBatch(childId);

      if (aiResult['status'] != 'success') {
        return aiResult;
      }

      final analysis = aiResult['analysis'] as Map<String, dynamic>;
      final messagesCount = aiResult['messagesAnalyzed'] as int;
      final periodStart = aiResult['periodStart'] as DateTime;
      final periodEnd = aiResult['periodEnd'] as DateTime;

      // 2. Comparar con la semana anterior (días 8-14)
      final DateTime twoWeeksAgo = DateTime.now().subtract(Duration(days: 14));
      final DateTime eightDaysAgo = DateTime.now().subtract(Duration(days: 8));

      ReleaseLogger.log('Buscando reporte anterior entre: $twoWeeksAgo y $eightDaysAgo', tag: 'GeminiAIService');

      final previousAnalysis = await _firestore
          .collection('ai_batch_analysis')
          .where('childId', isEqualTo: childId)
          .where(
            'analyzedAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(twoWeeksAgo),
          )
          .where('analyzedAt', isLessThan: Timestamp.fromDate(eightDaysAgo))
          .orderBy('analyzedAt', descending: true)
          .limit(1)
          .get();

      double sentimentChange = 0.0;
      int percentageChange = 0;

      if (previousAnalysis.docs.isNotEmpty) {
        final prevData = previousAnalysis.docs.first.data();
        final prevAnalysis = prevData['analysis'] as Map<String, dynamic>;
        final prevScore = (prevAnalysis['weighted_sentiment_score'] ??
                          prevAnalysis['sentiment_score'] ?? 0.5) as num;
        final currentScore = (analysis['weighted_sentiment_score'] ??
                             analysis['sentiment_score'] ?? 0.5) as num;

        sentimentChange = currentScore.toDouble() - prevScore.toDouble();
        if (prevScore != 0) {
          percentageChange = ((sentimentChange / prevScore.abs()) * 100)
              .round();
        }

        ReleaseLogger.log('Comparación: Anterior=$prevScore, Actual=$currentScore, Cambio=$percentageChange%', tag: 'GeminiAIService');
      } else {
        ReleaseLogger.log('No hay reporte anterior para comparar', tag: 'GeminiAIService');
      }

      // 3. Construir reporte completo
      final report = {
        'childId': childId,
        'period': 'Últimos 7 días',
        'periodStart': Timestamp.fromDate(periodStart),
        'periodEnd': Timestamp.fromDate(periodEnd),
        'periodDays': 7,
        'totalMessages': messagesCount,
        'avgSentiment': analysis['weighted_sentiment_score'] ??
                       analysis['sentiment_score'] ?? 0.5,
        'moodStatus': analysis['mood_description'] ?? 'neutral',
        'moodIcon': analysis['mood_icon'] ?? '😐',
        'positiveCount': analysis['message_count_positive'] ?? 0,
        'negativeCount': analysis['message_count_negative'] ?? 0,
        'neutralCount': analysis['message_count_neutral'] ?? 0,
        'bullyingIncidents': analysis['bullying_detected'] == true ? 1 : 0,
        'bullyingSeverity': analysis['bullying_severity'] ?? 0.0,
        'bullyingIndicators': analysis['bullying_indicators'] ?? [],
        'positiveAspects': analysis['positive_aspects'] ?? [],
        'concerns': analysis['concerns'] ?? [],
        'recommendations': analysis['recommendations'] ?? [],
        'sentimentChange': sentimentChange,
        'percentageChange': percentageChange,
        'weightedAnalysis': analysis['event_analysis'] ?? {},
        'weightedCalculation': analysis['weighted_calculation'] ?? {},
        'originalSentimentScore': analysis['sentiment_score'] ?? 0.5,
        'weightedSentimentScore': analysis['weighted_sentiment_score'] ??
                                 analysis['sentiment_score'] ?? 0.5,
        'generatedAt': FieldValue.serverTimestamp(),
        'aiGenerated': true,
      };

      // 4. Guardar reporte
      await _firestore.collection('weekly_reports').add(report);

      ReleaseLogger.log('Reporte generado con IA exitosamente', tag: 'GeminiAIService');
      ReleaseLogger.log('Periodo: ${periodStart.day}/${periodStart.month} - ${periodEnd.day}/${periodEnd.month}, Mensajes analizados: $messagesCount', tag: 'GeminiAIService');

      // Obtener todos los padres vinculados y enviar notificación
      final childDoc = await _firestore.collection('users').doc(childId).get();
      final childName = childDoc.data()?['name'] ?? 'tu hijo';

      final userRoleService = UserRoleService();
      final linkedParents = await userRoleService.getLinkedParents(childId);

      // Enviar notificación a todos los padres vinculados
      for (final parentId in linkedParents) {
        await NotificationService().sendReportReadyNotification(
          parentId: parentId,
          childName: childName,
          childId: childId,
        );
        ReleaseLogger.log('Notificación de reporte enviada al padre: $parentId', tag: 'GeminiAIService');
      }

      ReleaseLogger.log('Notificaciones enviadas a ${linkedParents.length} padre(s)', tag: 'GeminiAIService');

      return report;
    } catch (e) {
      ReleaseLogger.error('Error generando reporte: $e', tag: 'GeminiAIService');
      return {'status': 'error', 'message': 'Error al generar reporte: $e'};
    }
  }

  // Obtener último análisis con IA
  Future<Map<String, dynamic>?> getLatestAIAnalysis(String childId) async {
    try {
      final query = await _firestore
          .collection('ai_batch_analysis')
          .where('childId', isEqualTo: childId)
          .orderBy('analyzedAt', descending: true)
          .limit(1)
          .get();

      if (query.docs.isEmpty) return null;

      return query.docs.first.data();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo análisis: $e', tag: 'GeminiAIService');
      return null;
    }
  }

  // Test de conexión con Gemini (DESHABILITADO - usar Cloud Function)
  Future<bool> testAPIConnection() async {
    ReleaseLogger.log('SEGURIDAD: No usar Gemini desde cliente. Usar Cloud Function "generateChildReport"', tag: 'GeminiAIService');
    return false;

    /* CÓDIGO DESHABILITADO POR SEGURIDAD
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl?key=$_apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': 'Di "Conexión exitosa" en español'},
              ],
            },
          ],
        }),
      );

      if (response.statusCode == 200) {
        print('✅ Conexión con Gemini API exitosa');
        return true;
      } else {
        print('❌ Error de conexión: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('❌ Error de conexión: $e');
      return false;
    }
    */
  }
}
