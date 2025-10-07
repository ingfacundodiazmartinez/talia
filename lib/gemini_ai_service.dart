import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'notification_service.dart';
import 'services/user_role_service.dart';

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
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ❌ CREDENTIAL REMOVIDA POR SEGURIDAD
  // API Key debe estar SOLO en Cloud Functions, NO en el cliente
  // static const String _apiKey = 'REMOVED_FOR_SECURITY';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent';

  // Analizar mensajes por lotes
  Future<Map<String, dynamic>> analyzeMessagesBatch(String childId) async {
    try {
      // 1. Obtener todos los mensajes del hijo (últimos 7 días EXACTOS)
      final DateTime now = DateTime.now();
      final DateTime sevenDaysAgo = now.subtract(Duration(days: 7));

      print('📅 Analizando mensajes desde: ${sevenDaysAgo.toString()}');
      print('📅 Hasta: ${now.toString()}');

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

      print(
        '📊 Total de mensajes encontrados (últimos 7 días): ${allMessages.length}',
      );
      print('📅 Primer mensaje: ${allMessages.first['date']}');
      print('📅 Último mensaje: ${allMessages.last['date']}');

      print('📊 Analizando ${allMessages.length} mensajes con IA...');

      // 2. Preparar el prompt para Gemini
      final messagesText = allMessages.map((m) => m['text']).join('\n---\n');

      final prompt =
          '''
Eres un experto en psicología infantil y análisis de comunicación. Analiza los siguientes mensajes de un niño/adolescente de los ÚLTIMOS 7 DÍAS usando un sistema de PONDERACIÓN AVANZADA que prioriza eventos emocionales graves.

PERIODO ANALIZADO: Últimos 7 días (${sevenDaysAgo.day}/${sevenDaysAgo.month} - ${now.day}/${now.month}/${now.year})
TOTAL DE MENSAJES: ${allMessages.length}

MENSAJES A ANALIZAR:
$messagesText

SISTEMA DE PONDERACIÓN (del más grave al menos grave):
- CRÍTICOS (peso x5): bullying, autolesión, amenazas, depresión severa, ideas suicidas
- NEGATIVOS GRAVES (peso x3): conflictos familiares serios, problemas académicos graves, ansiedad severa, aislamiento social
- NEGATIVOS MODERADOS (peso x2): tristeza persistente, frustración, enojo, problemas menores
- NEUTROS (peso x1): actividades cotidianas, conversaciones normales
- POSITIVOS MODERADOS (peso x1): alegría momentánea, actividades divertidas
- POSITIVOS SIGNIFICATIVOS (peso x2): logros importantes, momentos de felicidad profunda, apoyo social fuerte

REGLAS DE ANÁLISIS:
1. UN SOLO evento CRÍTICO debe dominar el estado general, incluso con múltiples eventos positivos
2. Eventos NEGATIVOS GRAVES requieren al menos 3-4 eventos POSITIVOS SIGNIFICATIVOS para equilibrar
3. El contexto y la frecuencia de eventos negativos es crucial
4. Considera patrones: ¿los eventos negativos están aumentando o disminuyendo?

EJEMPLOS DE PONDERACIÓN:
- 5 mensajes positivos + 1 bullying = ESTADO NEGATIVO (bullying domina)
- 2 conflictos familiares + 3 alegrias menores = ESTADO NEGATIVO (conflictos pesan más)
- 1 logro importante + 2 alegrias + 1 tristeza menor = ESTADO POSITIVO (equilibrio favorable)

Proporciona tu análisis en el siguiente formato JSON EXACTO (solo JSON, sin texto adicional):
{
  "sentiment_overall": "positive|negative|neutral",
  "sentiment_score": 0.0 a 1.0,
  "weighted_sentiment_score": 0.0 a 1.0,
  "mood_description": "descripción breve del estado de ánimo considerando ponderación",
  "mood_icon": "emoji representativo",
  "bullying_detected": true|false,
  "bullying_severity": 0.0 a 1.0,
  "bullying_indicators": ["lista de indicadores encontrados"],
  "positive_aspects": ["aspectos positivos detectados"],
  "concerns": ["preocupaciones identificadas"],
  "recommendations": ["recomendaciones para los padres"],
  "event_analysis": {
    "critical_events": {"count": número, "details": ["lista de eventos críticos"]},
    "negative_grave_events": {"count": número, "details": ["lista de eventos negativos graves"]},
    "negative_moderate_events": {"count": número, "details": ["lista de eventos negativos moderados"]},
    "neutral_events": {"count": número},
    "positive_moderate_events": {"count": número, "details": ["lista de eventos positivos moderados"]},
    "positive_significant_events": {"count": número, "details": ["lista de eventos positivos significativos"]}
  },
  "weighted_calculation": {
    "critical_weight": "valor calculado (críticos * 5)",
    "negative_grave_weight": "valor calculado (neg_graves * 3)",
    "negative_moderate_weight": "valor calculado (neg_moderados * 2)",
    "positive_significant_weight": "valor calculado (pos_significativos * 2)",
    "final_weighted_score": "score final ponderado",
    "dominant_factor": "qué tipo de eventos domina el análisis"
  },
  "message_count_positive": número,
  "message_count_negative": número,
  "message_count_neutral": número
}

IMPORTANTE:
- Responde SOLO con el JSON, sin texto adicional antes o después
- Aplica ESTRICTAMENTE el sistema de ponderación: eventos graves SIEMPRE dominan
- weighted_sentiment_score debe reflejar la ponderación real, no solo un promedio
- Si hay eventos críticos, el sentiment_overall debe ser "negative" independientemente de eventos positivos
- Sé preciso y profesional en tu análisis considerando el peso emocional real de cada evento
''';

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
      print('❌ Error en análisis por lotes: $e');
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

      print('📊 Buscando reporte anterior entre: $twoWeeksAgo y $eightDaysAgo');

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

        print(
          '📈 Comparación: Anterior=$prevScore, Actual=$currentScore, Cambio=$percentageChange%',
        );
      } else {
        print('ℹ️ No hay reporte anterior para comparar');
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

      print('✅ Reporte generado con IA exitosamente');
      print(
        '📅 Periodo: ${periodStart.day}/${periodStart.month} - ${periodEnd.day}/${periodEnd.month}',
      );
      print('📊 Mensajes analizados: $messagesCount');

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
        );
        print('📱 Notificación de reporte enviada al padre: $parentId');
      }

      print('✅ Notificaciones enviadas a ${linkedParents.length} padre(s)');

      return report;
    } catch (e) {
      print('❌ Error generando reporte: $e');
      return {'status': 'error', 'message': 'Error al generar reporte: $e'};
    }
  }

  // Evaluar y crear alertas basadas en análisis ponderado
  Future<void> _evaluateAndCreateAlerts(
    String childId,
    Map<String, dynamic> analysis,
  ) async {
    try {
      final eventAnalysis = analysis['event_analysis'] as Map<String, dynamic>?;
      final weightedCalc = analysis['weighted_calculation'] as Map<String, dynamic>?;

      if (eventAnalysis == null) return;

      // Obtener datos del hijo y todos los padres vinculados
      final childDoc = await _firestore.collection('users').doc(childId).get();
      final childName = childDoc.data()?['name'] ?? 'tu hijo';

      final userRoleService = UserRoleService();
      final linkedParents = await userRoleService.getLinkedParents(childId);

      if (linkedParents.isEmpty) {
        print('⚠️ No hay padres vinculados para enviar alertas');
        return;
      }

      // Evaluar eventos críticos para cada padre
      final criticalEvents = eventAnalysis['critical_events'] as Map<String, dynamic>?;
      if (criticalEvents != null && (criticalEvents['count'] ?? 0) > 0) {
        for (final parentId in linkedParents) {
          await _createCriticalAlert(parentId, childId, childName, criticalEvents, analysis);
        }
      }

      // Evaluar bullying específicamente
      if (analysis['bullying_detected'] == true &&
          (analysis['bullying_severity'] ?? 0) > 0.5) {
        await _createBullyingAlert(childId, analysis);
      }

      // Evaluar patrón de eventos negativos graves para cada padre
      final negativeGraveEvents = eventAnalysis['negative_grave_events'] as Map<String, dynamic>?;
      if (negativeGraveEvents != null && (negativeGraveEvents['count'] ?? 0) >= 2) {
        for (final parentId in linkedParents) {
          await _createNegativePatternAlert(parentId, childId, childName, negativeGraveEvents, analysis);
        }
      }

      // Evaluar score ponderado general muy bajo para cada padre
      final weightedScore = analysis['weighted_sentiment_score'] ?? analysis['sentiment_score'] ?? 0.5;
      if (weightedScore < 0.2) {
        for (final parentId in linkedParents) {
          await _createLowMoodAlert(parentId, childId, childName, weightedScore, analysis);
        }
      }

      print('✅ Alertas evaluadas y enviadas a ${linkedParents.length} padre(s)');
    } catch (e) {
      print('❌ Error evaluando alertas: $e');
    }
  }

  // Crear alerta para eventos críticos
  Future<void> _createCriticalAlert(
    String parentId,
    String childId,
    String childName,
    Map<String, dynamic> criticalEvents,
    Map<String, dynamic> analysis,
  ) async {
    try {
      await _firestore.collection('alerts').add({
        'type': 'critical',
        'severity': 1.0,
        'parentId': parentId,
        'childId': childId,
        'criticalEventCount': criticalEvents['count'] ?? 0,
        'criticalEventDetails': criticalEvents['details'] ?? [],
        'analysisData': analysis,
        'aiGenerated': true,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Enviar notificación de emergencia (usando alerta de bullying como crítica)
      await NotificationService().sendBullyingAlert(
        parentId: parentId,
        childName: childName,
        severity: 1.0,
      );

      print('🚨 Alerta crítica creada');
    } catch (e) {
      print('❌ Error creando alerta crítica: $e');
    }
  }

  // Crear alerta para patrón de eventos negativos graves
  Future<void> _createNegativePatternAlert(
    String parentId,
    String childId,
    String childName,
    Map<String, dynamic> negativeGraveEvents,
    Map<String, dynamic> analysis,
  ) async {
    try {
      await _firestore.collection('alerts').add({
        'type': 'negative_pattern',
        'severity': 0.8,
        'parentId': parentId,
        'childId': childId,
        'negativeEventCount': negativeGraveEvents['count'] ?? 0,
        'negativeEventDetails': negativeGraveEvents['details'] ?? [],
        'concerns': analysis['concerns'] ?? [],
        'aiGenerated': true,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      print('⚠️ Alerta de patrón negativo creada');
    } catch (e) {
      print('❌ Error creando alerta de patrón: $e');
    }
  }

  // Crear alerta para estado de ánimo muy bajo
  Future<void> _createLowMoodAlert(
    String parentId,
    String childId,
    String childName,
    double weightedScore,
    Map<String, dynamic> analysis,
  ) async {
    try {
      await _firestore.collection('alerts').add({
        'type': 'low_mood',
        'severity': 0.6,
        'parentId': parentId,
        'childId': childId,
        'weightedScore': weightedScore,
        'moodDescription': analysis['mood_description'] ?? 'Estado de ánimo muy bajo',
        'concerns': analysis['concerns'] ?? [],
        'recommendations': analysis['recommendations'] ?? [],
        'aiGenerated': true,
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      print('😔 Alerta de estado de ánimo bajo creada');
    } catch (e) {
      print('❌ Error creando alerta de estado de ánimo: $e');
    }
  }

  // Crear alerta de bullying (función original preservada)
  Future<void> _createBullyingAlert(
    String childId,
    Map<String, dynamic> analysis,
  ) async {
    try {
      // Obtener todos los padres vinculados
      final childDoc = await _firestore.collection('users').doc(childId).get();
      final childName = childDoc.data()?['name'] ?? 'tu hijo';

      final userRoleService = UserRoleService();
      final linkedParents = await userRoleService.getLinkedParents(childId);

      if (linkedParents.isEmpty) {
        print('⚠️ No hay padres vinculados para enviar alerta de bullying');
        return;
      }

      // Crear alerta para cada padre vinculado
      for (final parentId in linkedParents) {
        await _firestore.collection('alerts').add({
          'type': 'bullying',
          'severity': analysis['bullying_severity'] ?? 0.0,
          'parentId': parentId,
          'childId': childId,
          'indicators': analysis['bullying_indicators'] ?? [],
          'aiGenerated': true,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Enviar notificación de bullying
        await NotificationService().sendBullyingAlert(
          parentId: parentId,
          childName: childName,
          severity: analysis['bullying_severity'] ?? 0.0,
        );

        print('⚠️ Alerta de bullying creada para padre: $parentId');
      }

      print('✅ Alertas de bullying enviadas a ${linkedParents.length} padre(s)');
    } catch (e) {
      print('❌ Error creando alerta: $e');
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
      print('❌ Error obteniendo análisis: $e');
      return null;
    }
  }

  // Test de conexión con Gemini (DESHABILITADO - usar Cloud Function)
  Future<bool> testAPIConnection() async {
    print('🚫 SEGURIDAD: No usar Gemini desde cliente. Usar Cloud Function "generateChildReport"');
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
