import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'story.dart';
import 'trivia.dart';

/// Tipo de elemento en el visor de historias
enum ViewerItemType { story, ad, trivia }

/// Estado del item de trivia en el visor
enum TriviaViewerState {
  preview, // Vista previa (comportamiento de historia)
  playing, // Jugando (sin timer, interactivo)
  results, // Mostrando resultados (comportamiento de historia)
}

/// Wrapper para representar un elemento en el visor de historias
/// Puede ser una historia, un anuncio nativo, o una trivia
class ViewerItem {
  final Story? story;
  final NativeAd? nativeAd;
  final Trivia? trivia;
  final ViewerItemType type;

  ViewerItem._({
    this.story,
    this.nativeAd,
    this.trivia,
    required this.type,
  });

  factory ViewerItem.story(Story story) => ViewerItem._(
        story: story,
        type: ViewerItemType.story,
      );

  factory ViewerItem.ad(NativeAd ad) => ViewerItem._(
        nativeAd: ad,
        type: ViewerItemType.ad,
      );

  factory ViewerItem.trivia(Trivia trivia) => ViewerItem._(
        trivia: trivia,
        type: ViewerItemType.trivia,
      );

  bool get isStory => type == ViewerItemType.story;
  bool get isAd => type == ViewerItemType.ad;
  bool get isTrivia => type == ViewerItemType.trivia;

  /// ID único del item (para tracking)
  String get id {
    switch (type) {
      case ViewerItemType.story:
        return 'story_${story!.id}';
      case ViewerItemType.ad:
        return 'ad_${nativeAd.hashCode}';
      case ViewerItemType.trivia:
        return 'trivia_${trivia!.id}';
    }
  }

  /// Duración del item en el visor (en segundos)
  /// Trivias en preview tienen más tiempo para leer
  int get viewerDuration {
    switch (type) {
      case ViewerItemType.story:
        return 5;
      case ViewerItemType.ad:
        return 0; // Los ads no tienen timer automático
      case ViewerItemType.trivia:
        return 8; // Más tiempo para leer la pregunta
    }
  }
}

/// Wrapper para UserStories que puede incluir trivias y ads
class UserContent {
  final String oderId;
  final String oderName;
  final String? oderPhotoURL;
  final List<ViewerItem> items;
  final bool hasUnviewed;

  UserContent({
    required this.oderId,
    required this.oderName,
    this.oderPhotoURL,
    required this.items,
    required this.hasUnviewed,
  });

  /// Factory desde UserStories (solo historias).
  ///
  /// [includeUnpublished]: si es true, incluye historias pendientes/rechazadas/
  /// expiradas (allUserStoriesIncludingExpired). Solo tiene sentido cuando el
  /// usuario está viendo su propio histórico (Mis historias del perfil), no
  /// para feeds públicos.
  factory UserContent.fromUserStories(
    UserStories userStories, {
    bool includeUnpublished = false,
  }) {
    final source = includeUnpublished
        ? userStories.allUserStoriesIncludingExpired
        : userStories.sortedStories;
    return UserContent(
      oderId: userStories.userId,
      oderName: userStories.userName,
      oderPhotoURL: userStories.userPhotoURL,
      items: source.map(ViewerItem.story).toList(),
      hasUnviewed: userStories.hasUnviewed,
    );
  }

  /// Factory desde UserStories con trivias intercaladas
  factory UserContent.fromUserStoriesAndTrivias(
    UserStories userStories,
    List<Trivia> trivias, {
    bool includeUnpublished = false,
  }) {
    final items = <ViewerItem>[];

    final storySource = includeUnpublished
        ? userStories.allUserStoriesIncludingExpired
        : userStories.sortedStories;
    // Agregar historias
    for (final story in storySource) {
      items.add(ViewerItem.story(story));
    }

    // Agregar trivias del mismo creador
    final userTrivias = trivias.where((t) => t.creatorId == userStories.userId);
    for (final trivia in userTrivias) {
      items.add(ViewerItem.trivia(trivia));
    }

    // Ordenar por fecha de creación
    items.sort((a, b) {
      final aDate = a.isStory
          ? a.story!.createdAt
          : a.isTrivia
              ? a.trivia!.createdAt
              : DateTime.now();
      final bDate = b.isStory
          ? b.story!.createdAt
          : b.isTrivia
              ? b.trivia!.createdAt
              : DateTime.now();
      return aDate.compareTo(bDate);
    });

    return UserContent(
      oderId: userStories.userId,
      oderName: userStories.userName,
      oderPhotoURL: userStories.userPhotoURL,
      items: items,
      hasUnviewed: userStories.hasUnviewed || trivias.any((t) => t.isActive),
    );
  }

  /// Factory solo para trivias (sin historias)
  factory UserContent.fromTrivia(Trivia trivia) {
    return UserContent(
      oderId: trivia.creatorId,
      oderName: trivia.creatorName,
      oderPhotoURL: trivia.creatorPhotoURL,
      items: [ViewerItem.trivia(trivia)],
      hasUnviewed: trivia.isActive,
    );
  }

  /// Número total de items
  int get itemCount => items.length;

  /// Verificar si tiene items visibles
  bool get hasItems => items.isNotEmpty;
}
