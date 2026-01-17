import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'story.dart';

/// Wrapper para representar un elemento en el visor de historias
/// Puede ser una historia real o un anuncio nativo
class StoryOrAd {
  final Story? story;
  final NativeAd? nativeAd;
  final bool isAd;

  StoryOrAd.story(this.story)
      : nativeAd = null,
        isAd = false;

  StoryOrAd.ad(this.nativeAd)
      : story = null,
        isAd = true;
}

/// Wrapper para UserStories que puede incluir ads insertados
class UserStoriesWithAds {
  final UserStories userStories;
  final List<StoryOrAd> items; // Historias mezcladas con ads

  UserStoriesWithAds({
    required this.userStories,
    required this.items,
  });

  /// Factory para crear desde UserStories normales
  factory UserStoriesWithAds.fromUserStories(
    UserStories userStories, {
    NativeAd? adToInsert,
  }) {
    final stories = userStories.sortedStories;
    final items = <StoryOrAd>[];

    // Agregar todas las historias
    for (final story in stories) {
      items.add(StoryOrAd.story(story));
    }

    // Si hay un ad, insertarlo al final
    if (adToInsert != null) {
      items.add(StoryOrAd.ad(adToInsert));
    }

    return UserStoriesWithAds(
      userStories: userStories,
      items: items,
    );
  }
}
