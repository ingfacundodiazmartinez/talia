/// Servicio para cálculo de puntajes de trivia
///
/// Implementa la fórmula:
/// - 100 puntos base por respuesta correcta
/// - Hasta 50 puntos bonus por velocidad
/// - Desempate: quien respondió primero gana
class TriviaScoringService {
  static TriviaScoringService? _instance;

  TriviaScoringService._internal();

  factory TriviaScoringService() {
    _instance ??= TriviaScoringService._internal();
    return _instance!;
  }

  /// Puntos base por respuesta correcta
  static const int basePoints = 100;

  /// Bonus máximo por velocidad
  static const int maxSpeedBonus = 50;

  /// Tiempo máximo default en milisegundos (30 segundos)
  static const int defaultMaxTimeMs = 30000;

  /// Calcular puntos por una respuesta
  ///
  /// [isCorrect] - Si la respuesta fue correcta
  /// [responseTimeMs] - Tiempo que tardó en responder (en milisegundos)
  /// [maxTimeMs] - Tiempo máximo permitido (default: 30000ms)
  ///
  /// Retorna:
  /// - 0 si la respuesta es incorrecta
  /// - 100-150 puntos si es correcta (según velocidad)
  int calculatePoints({
    required bool isCorrect,
    required int responseTimeMs,
    int maxTimeMs = defaultMaxTimeMs,
  }) {
    if (!isCorrect) return 0;

    // Calcular ratio de velocidad (1.0 = instantáneo, 0.0 = tiempo máximo)
    final speedRatio = 1.0 - (responseTimeMs / maxTimeMs).clamp(0.0, 1.0);

    // Calcular bonus por velocidad
    final speedBonus = (speedRatio * maxSpeedBonus).round();

    return basePoints + speedBonus;
  }

  /// Calcular puntaje total de múltiples respuestas
  int calculateTotalScore(List<int> pointsPerQuestion) {
    return pointsPerQuestion.fold(0, (sum, points) => sum + points);
  }

  /// Contar respuestas correctas
  int countCorrectAnswers(List<bool> correctnessPerQuestion) {
    return correctnessPerQuestion.where((c) => c).length;
  }

  /// Calcular porcentaje de aciertos
  double calculateAccuracy(int correctCount, int totalQuestions) {
    if (totalQuestions == 0) return 0.0;
    return correctCount / totalQuestions;
  }

  /// Comparar dos respuestas para el ranking
  ///
  /// Retorna:
  /// - Negativo si a debe estar antes que b
  /// - Positivo si b debe estar antes que a
  /// - 0 si son iguales
  ///
  /// Criterios:
  /// 1. Mayor puntaje primero
  /// 2. Si empate: quien terminó primero gana
  int compareForRanking({
    required int scoreA,
    required DateTime? completedAtA,
    required int scoreB,
    required DateTime? completedAtB,
  }) {
    // Primero comparar por puntaje (mayor primero)
    if (scoreA != scoreB) {
      return scoreB.compareTo(scoreA);
    }

    // Si empate, comparar por tiempo de finalización (primero gana)
    if (completedAtA == null && completedAtB == null) return 0;
    if (completedAtA == null) return 1; // B gana si A no completó
    if (completedAtB == null) return -1; // A gana si B no completó

    return completedAtA.compareTo(completedAtB);
  }

  /// Obtener descripción del puntaje obtenido
  String getScoreDescription(int points) {
    if (points == 0) return 'Incorrecta';
    if (points >= 140) return 'Excelente';
    if (points >= 120) return 'Muy bien';
    if (points >= 100) return 'Bien';
    return 'Correcto';
  }

  /// Obtener emoji según el puntaje
  String getScoreEmoji(int points) {
    if (points == 0) return '❌';
    if (points >= 140) return '🌟';
    if (points >= 120) return '⭐';
    if (points >= 100) return '✅';
    return '👍';
  }

  /// Calcular el bonus de velocidad en porcentaje
  int getSpeedBonusPercent(int points) {
    if (points <= basePoints) return 0;
    final bonus = points - basePoints;
    return ((bonus / maxSpeedBonus) * 100).round();
  }
}
