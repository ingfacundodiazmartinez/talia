import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';

import '../../models/trivia.dart';
import '../../models/trivia_question.dart';
import '../../utils/release_logger.dart';
import 'trivia_repository.dart';

/// Draft de pregunta para creación (antes de guardar)
class TriviaQuestionDraft {
  String text;
  QuestionType type;
  List<String> optionTexts;
  int correctOptionIndex;
  String? imagePath;

  TriviaQuestionDraft({
    required this.text,
    this.type = QuestionType.multipleChoice,
    required this.optionTexts,
    required this.correctOptionIndex,
    this.imagePath,
  });

  /// Validar que el draft está completo
  bool get isValid {
    if (text.trim().isEmpty) return false;
    if (optionTexts.isEmpty) return false;
    if (optionTexts.any((t) => t.trim().isEmpty)) return false;
    if (correctOptionIndex < 0 || correctOptionIndex >= optionTexts.length) {
      return false;
    }
    return true;
  }

  /// Convertir a TriviaQuestion con IDs generados
  TriviaQuestion toQuestion({
    required String triviaId,
    required int order,
    String? imageUrl,
  }) {
    final optionIds = ['a', 'b', 'c', 'd'];
    final options = <TriviaOption>[];

    for (int i = 0; i < optionTexts.length; i++) {
      options.add(TriviaOption(
        id: optionIds[i],
        text: optionTexts[i].trim(),
      ));
    }

    return TriviaQuestion(
      id: '', // Se asigna al guardar
      triviaId: triviaId,
      order: order,
      text: text.trim(),
      type: type,
      options: options,
      correctOptionId: optionIds[correctOptionIndex],
      imageUrl: imageUrl,
    );
  }
}

/// Servicio atómico para creación y gestión de trivias
class TriviaCreationService {
  static TriviaCreationService? _instance;

  final TriviaRepository _repository;
  final FirebaseAuth _auth;
  final FirebaseStorage _storage;
  final FirebaseFirestore _firestore;

  TriviaCreationService._internal({
    TriviaRepository? repository,
    FirebaseAuth? auth,
    FirebaseStorage? storage,
    FirebaseFirestore? firestore,
  })  : _repository = repository ?? TriviaRepository(),
        _auth = auth ?? FirebaseAuth.instance,
        _storage = storage ?? FirebaseStorage.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  factory TriviaCreationService({
    TriviaRepository? repository,
    FirebaseAuth? auth,
    FirebaseStorage? storage,
    FirebaseFirestore? firestore,
  }) {
    _instance ??= TriviaCreationService._internal(
      repository: repository,
      auth: auth,
      storage: storage,
      firestore: firestore,
    );
    return _instance!;
  }

  // ==================== Validation ====================

  /// Validar cantidad de preguntas (1-10)
  void _validateQuestionCount(List<TriviaQuestionDraft> questions) {
    if (questions.isEmpty) {
      throw TriviaCreationException('Debe tener al menos 1 pregunta');
    }
    if (questions.length > 10) {
      throw TriviaCreationException('Máximo 10 preguntas permitidas');
    }
  }

  /// Validar que todas las preguntas estén completas
  void _validateQuestions(List<TriviaQuestionDraft> questions) {
    for (int i = 0; i < questions.length; i++) {
      if (!questions[i].isValid) {
        throw TriviaCreationException(
            'Pregunta ${i + 1} está incompleta o inválida');
      }
    }
  }

  // ==================== Creation ====================

  /// Crear una nueva trivia con preguntas
  ///
  /// [title] - Título de la trivia
  /// [questions] - Lista de preguntas (1-10)
  /// [backgroundImagePath] - Path local de imagen de fondo (opcional)
  ///
  /// Retorna el ID de la trivia creada
  Future<String> createTrivia({
    required String title,
    required List<TriviaQuestionDraft> questions,
    String? backgroundImagePath,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw TriviaCreationException('Usuario no autenticado');
    }

    // Validaciones
    _validateQuestionCount(questions);
    _validateQuestions(questions);

    if (title.trim().isEmpty) {
      throw TriviaCreationException('El título es requerido');
    }

    ReleaseLogger.log(
        '📝 [TriviaCreation] Creando trivia: "$title" con ${questions.length} preguntas');

    try {
      // 1. Subir imagen de fondo si existe
      String? backgroundImageUrl;
      if (backgroundImagePath != null) {
        backgroundImageUrl = await _uploadBackgroundImage(
          backgroundImagePath,
          user.uid,
        );
      }

      // 2. Obtener contactos aprobados para availableFor
      final availableFor = await _getAvailableContacts(user.uid);

      // 3. Crear objeto Trivia
      final now = DateTime.now();
      final trivia = Trivia(
        id: '', // Se asigna en repository
        creatorId: user.uid,
        creatorName: user.displayName ?? 'Usuario',
        creatorPhotoURL: user.photoURL,
        title: title.trim(),
        backgroundImageUrl: backgroundImageUrl,
        questionIds: [], // Se actualizan después
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 24)),
        availableFor: availableFor,
      );

      // 4. Subir imágenes de preguntas y crear objetos
      final triviaQuestions = <TriviaQuestion>[];
      for (int i = 0; i < questions.length; i++) {
        String? questionImageUrl;
        if (questions[i].imagePath != null) {
          questionImageUrl = await _uploadQuestionImage(
            questions[i].imagePath!,
            user.uid,
            i,
          );
        }

        triviaQuestions.add(questions[i].toQuestion(
          triviaId: '', // Se asigna en repository
          order: i + 1,
          imageUrl: questionImageUrl,
        ));
      }

      // 5. Guardar en Firestore
      final triviaId = await _repository.createTrivia(
        trivia: trivia,
        questions: triviaQuestions,
      );

      ReleaseLogger.log('✅ [TriviaCreation] Trivia creada exitosamente: $triviaId');
      return triviaId;
    } catch (e) {
      ReleaseLogger.error('❌ [TriviaCreation] Error creando trivia: $e');
      rethrow;
    }
  }

  /// Obtener contactos aprobados del usuario
  /// Retorna lista de userIds con los que tiene contacto aprobado
  Future<List<String>> _getAvailableContacts(String userId) async {
    try {
      final snapshot = await _firestore
          .collection('contacts')
          .where('users', arrayContains: userId)
          .where('status', isEqualTo: 'approved')
          .get();

      final contactIds = <String>[];
      for (final doc in snapshot.docs) {
        final users = List<String>.from(doc.data()['users'] ?? []);
        // Obtener el otro usuario (no el actual)
        for (final id in users) {
          if (id != userId) {
            contactIds.add(id);
          }
        }
      }

      return contactIds;
    } catch (e) {
      ReleaseLogger.error(
          '⚠️ [TriviaCreation] Error obteniendo contactos: $e');
      return [];
    }
  }

  /// Subir imagen de fondo a Storage
  Future<String> _uploadBackgroundImage(String localPath, String userId) async {
    final file = File(localPath);
    if (!await file.exists()) {
      throw TriviaCreationException('Imagen de fondo no encontrada');
    }

    final uuid = const Uuid().v4();
    final ref = _storage.ref('trivia_backgrounds/$userId/$uuid.jpg');

    await ref.putFile(
      file,
      SettableMetadata(contentType: 'image/jpeg'),
    );

    return await ref.getDownloadURL();
  }

  /// Subir imagen de pregunta a Storage
  Future<String> _uploadQuestionImage(
    String localPath,
    String userId,
    int questionIndex,
  ) async {
    final file = File(localPath);
    if (!await file.exists()) {
      throw TriviaCreationException(
          'Imagen de pregunta ${questionIndex + 1} no encontrada');
    }

    final uuid = const Uuid().v4();
    final ref = _storage.ref('trivia_questions/$userId/$uuid.jpg');

    await ref.putFile(
      file,
      SettableMetadata(contentType: 'image/jpeg'),
    );

    return await ref.getDownloadURL();
  }

  // ==================== Edit ====================

  /// Editar una trivia existente (solo si no tiene respuestas)
  Future<void> editTrivia({
    required String triviaId,
    String? title,
    String? backgroundImagePath,
  }) async {
    final trivia = await _repository.getTrivia(triviaId);
    if (trivia == null) {
      throw TriviaCreationException('Trivia no encontrada');
    }

    if (!trivia.isEditable) {
      throw TriviaCreationException(
          'No se puede editar una trivia que ya tiene respuestas');
    }

    final updates = <String, dynamic>{};

    if (title != null && title.trim().isNotEmpty) {
      updates['title'] = title.trim();
    }

    if (backgroundImagePath != null) {
      final user = _auth.currentUser;
      if (user != null) {
        final url = await _uploadBackgroundImage(backgroundImagePath, user.uid);
        updates['backgroundImageUrl'] = url;
      }
    }

    if (updates.isNotEmpty) {
      await _repository.updateTrivia(triviaId, updates);
      ReleaseLogger.log('📝 [TriviaCreation] Trivia editada: $triviaId');
    }
  }

  // ==================== Delete ====================

  /// Eliminar una trivia y todas sus dependencias
  Future<void> deleteTrivia(String triviaId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw TriviaCreationException('Usuario no autenticado');
    }

    final trivia = await _repository.getTrivia(triviaId);
    if (trivia == null) {
      throw TriviaCreationException('Trivia no encontrada');
    }

    if (trivia.creatorId != user.uid) {
      throw TriviaCreationException(
          'No tienes permiso para eliminar esta trivia');
    }

    await _repository.deleteTrivia(triviaId);
    ReleaseLogger.log('🗑️ [TriviaCreation] Trivia eliminada: $triviaId');
  }

  // ==================== Close ====================

  /// Cerrar una trivia manualmente
  Future<void> closeTrivia(String triviaId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw TriviaCreationException('Usuario no autenticado');
    }

    final trivia = await _repository.getTrivia(triviaId);
    if (trivia == null) {
      throw TriviaCreationException('Trivia no encontrada');
    }

    if (trivia.creatorId != user.uid) {
      throw TriviaCreationException(
          'No tienes permiso para cerrar esta trivia');
    }

    if (!trivia.canClose) {
      throw TriviaCreationException('Esta trivia ya está cerrada');
    }

    await _repository.closeTrivia(triviaId);
    ReleaseLogger.log('🔒 [TriviaCreation] Trivia cerrada: $triviaId');
  }
}

/// Excepción para errores de creación de trivia
class TriviaCreationException implements Exception {
  final String message;

  TriviaCreationException(this.message);

  @override
  String toString() => 'TriviaCreationException: $message';
}
