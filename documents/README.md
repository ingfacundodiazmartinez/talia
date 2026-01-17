# System Flows Documentation

Documentation created during CODING_RULES.md compliance refactor.

## Core Flows

### Authentication & Users
- **[AUTH_FLOW.md](./AUTH_FLOW.md)** - Authentication, verification, device sessions
- **[USER_ROLES.md](./USER_ROLES.md)** - Parent/Child/Adult role management

### Communication
- **[CHAT_FLOW.md](./CHAT_FLOW.md)** - 1-1 and group messaging
- **[CALLING_FLOW.md](./CALLING_FLOW.md)** - Video calls, VoIP, CallKit integration
- **[MODERATION.md](./MODERATION.md)** - AI content moderation

### Content & Features
- **[STORY_FLOW.md](./STORY_FLOW.md)** - Story creation, camera, DeepAR
- **[NOTIFICATIONS.md](./NOTIFICATIONS.md)** - FCM, VoIP, local notifications
- **[PARENT_FEATURES.md](./PARENT_FEATURES.md)** - Dashboard, monitoring, controls

## Architecture Overview

```
lib/
├── models/              # Domain entities with business logic
├── controllers/         # Screen coordinators
├── services/           # Application services
├── screens/            # UI only (no business logic)
└── widgets/            # Reusable components
```

**Data Flow:** Screen → Controller → Service/Model → Firestore

## Critical Files Status

| File | Lines | Status | Priority |
|------|-------|--------|----------|
| StoryCameraScreen | 2,293 | 🚨 Critical | High |
| GroupChatScreen | 1,067 | 🚨 Critical | High |
| ParentChatsScreen | 941 | ⚠️ High | Medium |
| ChatDetailScreen | 731 | ⚠️ High | Medium |

## Refactor Progress

- ✅ IncomingCallDialog removed (native CallKit/VoIP only)
- ✅ CallKit foreground notifications fixed
- ✅ Favorites system fixed
- 🚧 CODING_RULES.md compliance refactor in progress