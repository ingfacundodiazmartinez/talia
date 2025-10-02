import 'package:cloud_firestore/cloud_firestore.dart';
import 'services/user_role_service.dart';

class AIAnalysisService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Palabras clave para análisis de sentimiento
  static const Map<String, double> _sentimentKeywords = {
    // Positivas
    'feliz': 0.8, 'bien': 0.6, 'genial': 0.9, 'excelente': 0.9,
    'bueno': 0.7, 'alegre': 0.8, 'contento': 0.8, 'divertido': 0.7,
    'amo': 0.9, 'me gusta': 0.7, 'increíble': 0.9, 'perfecto': 0.8,
    'hermoso': 0.8, 'maravilloso': 0.9, 'fantástico': 0.9,
    'gracias': 0.6, 'jaja': 0.7, 'jeje': 0.7, 'lol': 0.7,
    '😊': 0.8, '😄': 0.8, '😃': 0.8, '❤️': 0.9, '😍': 0.9,
    '👍': 0.7, '✨': 0.6, '🎉': 0.8, '😁': 0.8,

    // Negativas
    'triste': -0.8, 'mal': -0.6, 'horrible': -0.9, 'terrible': -0.9,
    'odio': -0.9, 'feo': -0.7, 'aburrido': -0.5, 'molesto': -0.7,
    'enojado': -0.8, 'furioso': -0.9, 'llorar': -0.7, 'deprimido': -0.9,
    'asqueroso': -0.8, 'malo': -0.7, 'pésimo': -0.9,
    'no me gusta': -0.7, 'detesto': -0.9,
    '😢': -0.8, '😭': -0.9, '😡': -0.9, '😞': -0.7, '😔': -0.7,
    '👎': -0.7, '💔': -0.9, '😠': -0.8,
  };

  // Palabras clave para detectar bullying
  static const List<String> _bullyingKeywords = [
    'tonto',
    'idiota',
    'estúpido',
    'burro',
    'inútil',
    'gordo',
    'feo',
    'perdedor',
    'nadie',
    'basura',
    'patético',
    'fracasado',
    'ridículo',
    'asco',
    'muérete',
    'mátate',
    'no sirves',
    'eres un',
    'callate',
    'cállate',
    'inservible',
    'débil',
    'te odio',
    'todos te odian',
    'nadie te quiere',
  ];

  // Analizar sentimiento de un mensaje
  Map<String, dynamic> analyzeSentiment(String message) {
    if (message.isEmpty) {
      return {'sentiment': 'neutral', 'score': 0.0, 'confidence': 0.0};
    }

    final messageLower = message.toLowerCase();
    double totalScore = 0.0;
    int matchCount = 0;

    // Buscar palabras clave
    _sentimentKeywords.forEach((keyword, score) {
      if (messageLower.contains(keyword)) {
        totalScore += score;
        matchCount++;
      }
    });

    // Calcular score promedio
    final avgScore = matchCount > 0 ? totalScore / matchCount : 0.0;

    // Determinar sentimiento
    String sentiment;
    if (avgScore > 0.3) {
      sentiment = 'positive';
    } else if (avgScore < -0.3) {
      sentiment = 'negative';
    } else {
      sentiment = 'neutral';
    }

    // Calcular confianza basada en cantidad de matches
    final confidence = (matchCount / 3).clamp(0.0, 1.0);

    return {
      'sentiment': sentiment,
      'score': avgScore,
      'confidence': confidence,
      'keywords_found': matchCount,
    };
  }

  // Detectar posible bullying
  Map<String, dynamic> detectBullying(String message) {
    if (message.isEmpty) {
      return {'has_bullying': false, 'severity': 0.0, 'keywords_found': []};
    }

    final messageLower = message.toLowerCase();
    final List<String> foundKeywords = [];

    for (var keyword in _bullyingKeywords) {
      if (messageLower.contains(keyword)) {
        foundKeywords.add(keyword);
      }
    }

    final hasBullying = foundKeywords.isNotEmpty;
    final severity = (foundKeywords.length / 3).clamp(0.0, 1.0);

    return {
      'has_bullying': hasBullying,
      'severity': severity,
      'keywords_found': foundKeywords,
      'keyword_count': foundKeywords.length,
    };
  }

  // Analizar mensaje completo y guardar en Firestore
  Future<void> analyzeAndSaveMessage({
    required String messageId,
    required String chatId,
    required String text,
    required String senderId,
  }) async {
    try {
      final sentimentAnalysis = analyzeSentiment(text);
      final bullyingAnalysis = detectBullying(text);

      await _firestore.collection('message_analysis').doc(messageId).set({
        'messageId': messageId,
        'chatId': chatId,
        'senderId': senderId,
        'sentiment': sentimentAnalysis['sentiment'],
        'sentimentScore': sentimentAnalysis['score'],
        'confidence': sentimentAnalysis['confidence'],
        'hasBullying': bullyingAnalysis['has_bullying'],
        'bullyingSeverity': bullyingAnalysis['severity'],
        'bullyingKeywords': bullyingAnalysis['keywords_found'],
        'analyzedAt': FieldValue.serverTimestamp(),
      });

      // Si detecta bullying severo, crear alerta
      if (bullyingAnalysis['severity'] > 0.5) {
        await _createBullyingAlert(
          senderId: senderId,
          messageId: messageId,
          severity: bullyingAnalysis['severity'],
          keywords: bullyingAnalysis['keywords_found'],
        );
      }
    } catch (e) {
      print('Error analyzing message: $e');
    }
  }

  // Crear alerta de bullying
  Future<void> _createBullyingAlert({
    required String senderId,
    required String messageId,
    required double severity,
    required List<String> keywords,
  }) async {
    try {
      // Obtener el childId (receptor del mensaje)
      final messageDoc = await _firestore
          .collection('chats')
          .where('participants', arrayContains: senderId)
          .limit(1)
          .get();

      if (messageDoc.docs.isEmpty) return;

      final participants = List<String>.from(
        messageDoc.docs.first.data()['participants'] ?? [],
      );
      final childId = participants.firstWhere(
        (id) => id != senderId,
        orElse: () => '',
      );

      if (childId.isEmpty) return;

      // Obtener todos los padres vinculados
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
          'severity': severity,
          'parentId': parentId,
          'childId': childId,
          'messageId': messageId,
          'keywords': keywords,
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });
        print('📱 Alerta de bullying enviada al padre: $parentId');
      }

      print('✅ Alertas de bullying enviadas a ${linkedParents.length} padre(s)');
    } catch (e) {
      print('Error creating bullying alert: $e');
    }
  }

  // Generar reporte semanal
  Future<Map<String, dynamic>> generateWeeklyReport(String childId) async {
    try {
      final weekAgo = DateTime.now().subtract(Duration(days: 7));

      // Obtener todos los análisis de la semana
      final analysisQuery = await _firestore
          .collection('message_analysis')
          .where('senderId', isEqualTo: childId)
          .where('analyzedAt', isGreaterThan: Timestamp.fromDate(weekAgo))
          .get();

      if (analysisQuery.docs.isEmpty) {
        return {
          'status': 'no_data',
          'message': 'No hay suficientes datos para generar un reporte',
        };
      }

      // Calcular estadísticas
      int totalMessages = analysisQuery.docs.length;
      int positiveCount = 0;
      int negativeCount = 0;
      int neutralCount = 0;
      int bullyingCount = 0;
      double totalSentimentScore = 0.0;

      for (var doc in analysisQuery.docs) {
        final data = doc.data();
        final sentiment = data['sentiment'];
        final score = (data['sentimentScore'] ?? 0.0) as double;
        final hasBullying = data['hasBullying'] ?? false;

        totalSentimentScore += score;

        if (sentiment == 'positive') positiveCount++;
        if (sentiment == 'negative') negativeCount++;
        if (sentiment == 'neutral') neutralCount++;
        if (hasBullying) bullyingCount++;
      }

      final avgSentiment = totalSentimentScore / totalMessages;

      // Determinar estado de ánimo general
      String moodStatus;
      String moodIcon;
      if (avgSentiment > 0.3) {
        moodStatus = 'muy positivo';
        moodIcon = '😊';
      } else if (avgSentiment > 0.1) {
        moodStatus = 'positivo';
        moodIcon = '🙂';
      } else if (avgSentiment > -0.1) {
        moodStatus = 'neutral';
        moodIcon = '😐';
      } else if (avgSentiment > -0.3) {
        moodStatus = 'negativo';
        moodIcon = '😔';
      } else {
        moodStatus = 'muy negativo';
        moodIcon = '😢';
      }

      // Comparar con semana anterior
      final twoWeeksAgo = DateTime.now().subtract(Duration(days: 14));
      final previousWeekQuery = await _firestore
          .collection('message_analysis')
          .where('senderId', isEqualTo: childId)
          .where(
            'analyzedAt',
            isGreaterThan: Timestamp.fromDate(twoWeeksAgo),
            isLessThan: Timestamp.fromDate(weekAgo),
          )
          .get();

      double previousAvgSentiment = 0.0;
      if (previousWeekQuery.docs.isNotEmpty) {
        double previousTotal = 0.0;
        for (var doc in previousWeekQuery.docs) {
          previousTotal += (doc.data()['sentimentScore'] ?? 0.0) as double;
        }
        previousAvgSentiment = previousTotal / previousWeekQuery.docs.length;
      }

      final sentimentChange = avgSentiment - previousAvgSentiment;
      final percentageChange = previousAvgSentiment != 0
          ? ((sentimentChange / previousAvgSentiment.abs()) * 100).toInt()
          : 0;

      // Construir reporte
      final report = {
        'childId': childId,
        'period': 'Última semana',
        'totalMessages': totalMessages,
        'avgSentiment': avgSentiment,
        'moodStatus': moodStatus,
        'moodIcon': moodIcon,
        'positiveCount': positiveCount,
        'negativeCount': negativeCount,
        'neutralCount': neutralCount,
        'bullyingIncidents': bullyingCount,
        'sentimentChange': sentimentChange,
        'percentageChange': percentageChange,
        'generatedAt': FieldValue.serverTimestamp(),
      };

      // Guardar reporte
      await _firestore.collection('weekly_reports').add(report);

      return report;
    } catch (e) {
      print('Error generating weekly report: $e');
      return {'status': 'error', 'message': 'Error al generar el reporte: $e'};
    }
  }

  // Obtener último reporte semanal
  Future<Map<String, dynamic>?> getLatestWeeklyReport(String childId) async {
    try {
      final reportQuery = await _firestore
          .collection('weekly_reports')
          .where('childId', isEqualTo: childId)
          .orderBy('generatedAt', descending: true)
          .limit(1)
          .get();

      if (reportQuery.docs.isEmpty) return null;

      return reportQuery.docs.first.data();
    } catch (e) {
      print('Error getting latest report: $e');
      return null;
    }
  }

  // Obtener alertas no leídas para un padre
  Stream<QuerySnapshot> getUnreadAlerts(String parentId) {
    return _firestore
        .collection('alerts')
        .where('parentId', isEqualTo: parentId)
        .where('isRead', isEqualTo: false)
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  // Marcar alerta como leída
  Future<void> markAlertAsRead(String alertId) async {
    try {
      await _firestore.collection('alerts').doc(alertId).update({
        'isRead': true,
        'readAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error marking alert as read: $e');
    }
  }
}
