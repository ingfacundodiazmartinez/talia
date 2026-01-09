import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../models/trivia.dart';
import '../../models/trivia_response.dart';
import '../../utils/release_logger.dart';
import 'trivia_repository.dart';

/// Estadísticas de una trivia
class TriviaStats {
  final int totalParticipants;
  final double averageScore;
  final double averageAccuracy;
  final int totalQuestions;
  final Map<String, int> questionCorrectCounts;

  TriviaStats({
    required this.totalParticipants,
    required this.averageScore,
    required this.averageAccuracy,
    required this.totalQuestions,
    required this.questionCorrectCounts,
  });
}

/// Resultados completos de una trivia
class TriviaResults {
  final Trivia trivia;
  final List<TriviaLeaderboardEntry> leaderboard;
  final TriviaStats stats;

  TriviaResults({
    required this.trivia,
    required this.leaderboard,
    required this.stats,
  });

  /// Obtener el podio (top 3)
  List<TriviaLeaderboardEntry> get podium =>
      leaderboard.where((e) => e.isOnPodium).toList();

  /// Verificar si hay suficientes participantes para el podio completo
  bool get hasFullPodium => leaderboard.length >= 3;
}

/// Servicio para resultados y rankings de trivias
class TriviaResultsService {
  static TriviaResultsService? _instance;

  final TriviaRepository _repository;
  final FirebaseAuth _auth;

  TriviaResultsService._internal({
    TriviaRepository? repository,
    FirebaseAuth? auth,
  })  : _repository = repository ?? TriviaRepository(),
        _auth = auth ?? FirebaseAuth.instance;

  factory TriviaResultsService({
    TriviaRepository? repository,
    FirebaseAuth? auth,
  }) {
    _instance ??= TriviaResultsService._internal(
      repository: repository,
      auth: auth,
    );
    return _instance!;
  }

  // ==================== Leaderboard ====================

  /// Stream del leaderboard de una trivia
  Stream<List<TriviaLeaderboardEntry>> watchLeaderboard(String triviaId) {
    return _repository.watchLeaderboard(triviaId).map((responses) {
      return _buildLeaderboard(responses);
    });
  }

  /// Obtener leaderboard actual
  Future<List<TriviaLeaderboardEntry>> getLeaderboard(String triviaId) async {
    final responses = await TriviaResponse.getLeaderboard(triviaId);
    return _buildLeaderboard(responses);
  }

  /// Construir lista de leaderboard con rankings
  List<TriviaLeaderboardEntry> _buildLeaderboard(List<TriviaResponse> responses) {
    final entries = <TriviaLeaderboardEntry>[];
    int currentRank = 1;
    int? previousScore;
    DateTime? previousCompletedAt;

    for (int i = 0; i < responses.length; i++) {
      final response = responses[i];

      // Determinar si es empate con el anterior
      if (previousScore != null &&
          response.totalScore == previousScore &&
          response.completedAt != null &&
          previousCompletedAt != null) {
        // Mismo puntaje - el que terminó primero tiene mejor rank
        // (ya están ordenados así)
      } else if (i > 0) {
        // Diferente puntaje, incrementar rank
        currentRank = i + 1;
      }

      entries.add(TriviaLeaderboardEntry(
        response: response,
        rank: currentRank,
      ));

      previousScore = response.totalScore;
      previousCompletedAt = response.completedAt;
    }

    return entries;
  }

  // ==================== Stats ====================

  /// Obtener estadísticas de una trivia
  Future<TriviaStats> getStats(String triviaId) async {
    final responses = await TriviaResponse.getLeaderboard(triviaId, limit: 1000);

    if (responses.isEmpty) {
      return TriviaStats(
        totalParticipants: 0,
        averageScore: 0,
        averageAccuracy: 0,
        totalQuestions: 0,
        questionCorrectCounts: {},
      );
    }

    // Calcular promedios
    final totalScore = responses.fold<int>(0, (sum, r) => sum + r.totalScore);
    final totalCorrect =
        responses.fold<int>(0, (sum, r) => sum + r.correctCount);
    final totalQuestions = responses.first.totalQuestions;
    final totalAnswered = responses.length * totalQuestions;

    // Contar correctas por pregunta
    final questionCorrectCounts = <String, int>{};
    for (final response in responses) {
      for (final answer in response.answers) {
        if (answer.isCorrect) {
          questionCorrectCounts[answer.questionId] =
              (questionCorrectCounts[answer.questionId] ?? 0) + 1;
        }
      }
    }

    return TriviaStats(
      totalParticipants: responses.length,
      averageScore: responses.isNotEmpty ? totalScore / responses.length : 0,
      averageAccuracy: totalAnswered > 0 ? totalCorrect / totalAnswered : 0,
      totalQuestions: totalQuestions,
      questionCorrectCounts: questionCorrectCounts,
    );
  }

  // ==================== Full Results ====================

  /// Obtener resultados completos de una trivia
  Future<TriviaResults> getResults(String triviaId) async {
    final trivia = await _repository.getTrivia(triviaId);
    if (trivia == null) {
      throw TriviaResultsException('Trivia no encontrada');
    }

    final leaderboard = await getLeaderboard(triviaId);
    final stats = await getStats(triviaId);

    return TriviaResults(
      trivia: trivia,
      leaderboard: leaderboard,
      stats: stats,
    );
  }

  // ==================== Share Results ====================

  /// Compartir resultados como historia
  ///
  /// Crea una historia especial de tipo 'trivia_results' que muestra
  /// el podio y los resultados de la trivia.
  /// Retorna el ID de la historia creada
  Future<String> shareResultsAsStory(String triviaId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw TriviaResultsException('Usuario no autenticado');
    }

    final trivia = await _repository.getTrivia(triviaId);
    if (trivia == null) {
      throw TriviaResultsException('Trivia no encontrada');
    }

    if (trivia.creatorId != user.uid) {
      throw TriviaResultsException(
          'Solo el creador puede compartir los resultados');
    }

    if (trivia.hasSharedResults) {
      throw TriviaResultsException('Los resultados ya fueron compartidos');
    }

    // Obtener el leaderboard/podio
    final leaderboard = await getLeaderboard(triviaId);
    final podium = leaderboard.where((e) => e.isOnPodium).toList();

    // Obtener datos del usuario creador
    final userDoc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final userData = userDoc.data() ?? {};
    final userName = userData['name'] as String? ?? 'Usuario';
    final userPhotoURL = userData['photoURL'] as String?;

    // Obtener datos actualizados de los usuarios del podio desde Firestore
    final podiumUserIds = podium.map((e) => e.oderId).toList();
    final podiumUsersData = <String, Map<String, dynamic>>{};

    for (final oderId in podiumUserIds) {
      try {
        final oderDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(oderId)
            .get();
        if (oderDoc.exists) {
          podiumUsersData[oderId] = oderDoc.data() ?? {};
        }
      } catch (e) {
        // Si falla, usar datos del response
        ReleaseLogger.log('⚠️ [TriviaResults] Error obteniendo datos de usuario $oderId: $e');
      }
    }

    // Generar ID único para la historia
    final storyId = FirebaseFirestore.instance.collection('stories').doc().id;

    final now = DateTime.now();
    final expiresAt = now.add(const Duration(hours: 24));

    // Preparar datos del podio para el filter (con fotos actualizadas de Firestore)
    final podiumData = podium.map((entry) {
      final oderData = podiumUsersData[entry.oderId];
      final photoURL = oderData?['photoURL'] as String? ?? entry.oderPhotoURL;
      final name = oderData?['name'] as String? ?? entry.oderName;

      return <String, dynamic>{
        'rank': entry.rank,
        'oderId': entry.oderId,
        'oderName': name,
        'oderPhotoURL': photoURL,
        'totalScore': entry.score,
        'correctCount': entry.correctCount,
        'totalQuestions': entry.totalQuestions,
      };
    }).toList();

    // Crear documento de historia
    final storyData = {
      'userId': user.uid,
      'userName': userName,
      'userPhotoURL': userPhotoURL,
      'mediaUrl': 'trivia://results/$triviaId',
      'mediaType': 'trivia_results',
      'caption': '🏆 Resultados de mi trivia: ${trivia.title}',
      'createdAt': Timestamp.fromDate(now),
      'expiresAt': Timestamp.fromDate(expiresAt),
      'viewedBy': <String>[],
      'replies': <Map<String, dynamic>>[],
      'filter': {
        'type': 'trivia_results',
        'triviaId': triviaId,
        'triviaTitle': trivia.title,
        'triviaBackgroundImageUrl': trivia.backgroundImageUrl,
        'participantCount': trivia.participantCount,
        'questionCount': trivia.questionCount,
        'podium': podiumData,
      },
      'status': 'approved',
      'visibility': 'temporary',
      'availableFor': trivia.availableFor,
      'parentViewers': <String>[],
      'likedBy': <String>[],
    };

    // Guardar historia en Firestore
    await FirebaseFirestore.instance
        .collection('stories')
        .doc(storyId)
        .set(storyData);

    // Guardar referencia en la trivia
    await _repository.saveResultsStoryId(triviaId, storyId);

    ReleaseLogger.log(
        '📤 [TriviaResults] Resultados compartidos como historia: $storyId (podio: ${podium.length} participantes)');

    return storyId;
  }

  // ==================== User Position ====================

  /// Obtener mi posición en el leaderboard
  Future<TriviaLeaderboardEntry?> getMyPosition(String triviaId) async {
    final user = _auth.currentUser;
    if (user == null) return null;

    final leaderboard = await getLeaderboard(triviaId);
    try {
      return leaderboard.firstWhere((e) => e.oderId == user.uid);
    } catch (_) {
      return null;
    }
  }

  /// Stream de mi posición
  Stream<TriviaLeaderboardEntry?> watchMyPosition(String triviaId) {
    final user = _auth.currentUser;
    if (user == null) return Stream.value(null);

    return watchLeaderboard(triviaId).map((leaderboard) {
      try {
        return leaderboard.firstWhere((e) => e.oderId == user.uid);
      } catch (_) {
        return null;
      }
    });
  }

  // ==================== Top Winners ====================

  /// Obtener IDs de los ganadores (top 3) para notificaciones
  Future<List<String>> getTopWinnerIds(String triviaId, {int limit = 3}) async {
    final responses = await _repository.getTopResponses(triviaId, limit: limit);
    return responses.map((r) => r.oderId).toList();
  }
}

/// Excepción para errores de resultados
class TriviaResultsException implements Exception {
  final String message;

  TriviaResultsException(this.message);

  @override
  String toString() => 'TriviaResultsException: $message';
}
