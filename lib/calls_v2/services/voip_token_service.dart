/// VoIP Token Service
///
/// Centralized service for managing VoIP push notification tokens:
/// - Token validation and refresh
/// - Token expiration checking
/// - Automatic token renewal
/// - Token cleanup for device transfers
///
/// This service ensures reliable VoIP push delivery by maintaining
/// valid tokens and handling edge cases like token invalidation.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import '../../utils/release_logger.dart';

class VoIPTokenService {
  static final VoIPTokenService _instance = VoIPTokenService._internal();
  factory VoIPTokenService() => _instance;
  VoIPTokenService._internal();

  static const String _tag = 'VoIPTokenService';
  static const MethodChannel _voipChannel = MethodChannel('com.talia.chat/voip');

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Token validation settings
  static const Duration _tokenStaleThreshold = Duration(days: 30);
  static const Duration _tokenRefreshRetryInterval = Duration(seconds: 2);
  static const int _maxRefreshRetries = 5;

  /// Check if the current VoIP token is valid
  /// Returns true if token exists and is not stale
  Future<bool> isTokenValid() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        ReleaseLogger.log('No authenticated user', tag: _tag);
        return false;
      }

      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (!userDoc.exists) {
        ReleaseLogger.log('User document not found', tag: _tag);
        return false;
      }

      final data = userDoc.data() as Map<String, dynamic>;
      final voipToken = data['voipToken'] as String?;
      final tokenUpdatedAt = data['voipTokenUpdatedAt'] as Timestamp?;

      // Check if token exists
      if (voipToken == null || voipToken.isEmpty) {
        ReleaseLogger.log('No VoIP token found', tag: _tag);
        return false;
      }

      // Check if token is stale (optional - Apple tokens don't expire by time)
      // But we still check for very old tokens that might indicate issues
      if (tokenUpdatedAt != null) {
        final tokenAge = DateTime.now().difference(tokenUpdatedAt.toDate());
        if (tokenAge > _tokenStaleThreshold) {
          ReleaseLogger.log(
            'VoIP token is stale (${tokenAge.inDays} days old)',
            tag: _tag,
          );
          // Note: We don't invalidate old tokens automatically since Apple
          // tokens don't expire. But we log it for monitoring.
        }
      }

      ReleaseLogger.log(
        'VoIP token is valid: ${voipToken.substring(0, 20)}...',
        tag: _tag,
      );
      return true;
    } catch (e) {
      ReleaseLogger.error('Error checking token validity: $e', tag: _tag);
      return false;
    }
  }

  /// Get the current VoIP token
  Future<String?> getToken() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return null;

      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (!userDoc.exists) return null;

      final data = userDoc.data() as Map<String, dynamic>;
      return data['voipToken'] as String?;
    } catch (e) {
      ReleaseLogger.error('Error getting VoIP token: $e', tag: _tag);
      return null;
    }
  }

  /// Save a VoIP token to Firestore
  /// Automatically cleans up duplicate tokens from other users
  Future<bool> saveToken(String token) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        ReleaseLogger.log('No authenticated user to save token', tag: _tag);
        return false;
      }

      ReleaseLogger.log(
        'Saving VoIP token: ${token.substring(0, 20)}...',
        tag: _tag,
      );

      // Clean up duplicate tokens from other users first
      await _cleanupDuplicateTokens(token, userId);

      // Save the token
      await _firestore.collection('users').doc(userId).update({
        'voipToken': token,
        'voipTokenUpdatedAt': FieldValue.serverTimestamp(),
        'voipTokenRefreshNeeded': FieldValue.delete(), // Clear refresh flag
      });

      ReleaseLogger.log('VoIP token saved successfully', tag: _tag);
      return true;
    } catch (e) {
      ReleaseLogger.error('Error saving VoIP token: $e', tag: _tag);
      return false;
    }
  }

  /// Request a fresh VoIP token from iOS
  /// This triggers the native PKPushRegistry to re-register
  Future<String?> requestFreshToken() async {
    try {
      ReleaseLogger.log('Requesting fresh VoIP token from iOS...', tag: _tag);

      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        ReleaseLogger.log('No authenticated user', tag: _tag);
        return null;
      }

      // Get previous token for comparison
      final previousToken = await getToken();

      // Request token from native iOS
      try {
        await _voipChannel.invokeMethod('requestVoIPToken');
      } catch (e) {
        ReleaseLogger.error(
          'Failed to invoke native requestVoIPToken: $e',
          tag: _tag,
        );
        return null;
      }

      // Wait for the token to be received and saved via the native callback
      for (int attempt = 1; attempt <= _maxRefreshRetries; attempt++) {
        ReleaseLogger.log(
          'Waiting for token (attempt $attempt/$_maxRefreshRetries)...',
          tag: _tag,
        );

        await Future.delayed(_tokenRefreshRetryInterval);

        final userDoc = await _firestore.collection('users').doc(userId).get();
        if (userDoc.exists) {
          final data = userDoc.data() as Map<String, dynamic>;
          final currentToken = data['voipToken'] as String?;
          final tokenUpdatedAt = data['voipTokenUpdatedAt'] as Timestamp?;

          // Check if we got a new token (different from previous)
          if (currentToken != null &&
              currentToken != previousToken &&
              tokenUpdatedAt != null) {
            // Verify it's recent (less than 30 seconds)
            final tokenAge = DateTime.now().difference(tokenUpdatedAt.toDate());
            if (tokenAge.inSeconds < 30) {
              ReleaseLogger.log(
                'New token received: ${currentToken.substring(0, 20)}...',
                tag: _tag,
              );
              return currentToken;
            }
          }
        }

        // Retry the request if not the last attempt
        if (attempt < _maxRefreshRetries) {
          try {
            await _voipChannel.invokeMethod('requestVoIPToken');
          } catch (e) {
            ReleaseLogger.log('Retry $attempt failed: $e', tag: _tag);
          }
        }
      }

      ReleaseLogger.error(
        'Failed to receive new token after $_maxRefreshRetries attempts',
        tag: _tag,
      );
      return null;
    } catch (e) {
      ReleaseLogger.error('Error requesting fresh token: $e', tag: _tag);
      return null;
    }
  }

  /// Validate the current token and refresh if needed
  /// This should be called on app startup and periodically
  Future<bool> validateAndRefreshIfNeeded() async {
    try {
      ReleaseLogger.log('Validating VoIP token...', tag: _tag);

      // Check if token is valid
      if (await isTokenValid()) {
        ReleaseLogger.log('Token is valid, no refresh needed', tag: _tag);
        return true;
      }

      // Token is invalid or missing, request a fresh one
      ReleaseLogger.log('Token invalid, requesting fresh token...', tag: _tag);
      final newToken = await requestFreshToken();

      if (newToken != null) {
        ReleaseLogger.log('Token successfully refreshed', tag: _tag);
        return true;
      }

      ReleaseLogger.error('Failed to refresh token', tag: _tag);
      return false;
    } catch (e) {
      ReleaseLogger.error('Error in validateAndRefreshIfNeeded: $e', tag: _tag);
      return false;
    }
  }

  /// Check if a token refresh has been requested/needed
  Future<bool> isRefreshNeeded() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return false;

      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (!userDoc.exists) return false;

      final data = userDoc.data() as Map<String, dynamic>;
      return data['voipTokenRefreshNeeded'] == true;
    } catch (e) {
      ReleaseLogger.error('Error checking refresh flag: $e', tag: _tag);
      return false;
    }
  }

  /// Mark that a token refresh is needed
  /// This can be called when push notifications fail or other issues occur
  Future<void> markRefreshNeeded() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      await _firestore.collection('users').doc(userId).update({
        'voipTokenRefreshNeeded': true,
        'lastTokenRefreshAttempt': FieldValue.serverTimestamp(),
      });

      ReleaseLogger.log('Marked token for refresh', tag: _tag);
    } catch (e) {
      ReleaseLogger.error('Error marking refresh needed: $e', tag: _tag);
    }
  }

  /// Clean up duplicate tokens from other users
  /// This prevents VoIP pushes from going to wrong devices
  Future<void> _cleanupDuplicateTokens(String token, String currentUserId) async {
    try {
      ReleaseLogger.log(
        'Checking for duplicate tokens: ${token.substring(0, 20)}...',
        tag: _tag,
      );

      // Find all users with this token
      final duplicateUsers = await _firestore
          .collection('users')
          .where('voipToken', isEqualTo: token)
          .get();

      int cleanedCount = 0;
      for (final doc in duplicateUsers.docs) {
        final userId = doc.id;

        // Don't clean the current user's token
        if (userId == currentUserId) continue;

        // Remove token from previous user
        await _firestore.collection('users').doc(userId).update({
          'voipToken': FieldValue.delete(),
          'voipTokenClearedAt': FieldValue.serverTimestamp(),
          'voipTokenClearedReason': 'duplicate_token_cleanup',
        });

        cleanedCount++;
        ReleaseLogger.log(
          'Cleaned duplicate token from user: $userId',
          tag: _tag,
        );
      }

      if (cleanedCount > 0) {
        ReleaseLogger.log(
          'Cleaned $cleanedCount duplicate token(s)',
          tag: _tag,
        );
      }
    } catch (e) {
      ReleaseLogger.error('Error cleaning duplicate tokens: $e', tag: _tag);
    }
  }

  /// Clear the current user's VoIP token
  /// Used during logout or when explicitly removing the device
  Future<void> clearToken() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      await _firestore.collection('users').doc(userId).update({
        'voipToken': FieldValue.delete(),
        'voipTokenClearedAt': FieldValue.serverTimestamp(),
        'voipTokenClearedReason': 'user_logout',
      });

      ReleaseLogger.log('VoIP token cleared', tag: _tag);
    } catch (e) {
      ReleaseLogger.error('Error clearing token: $e', tag: _tag);
    }
  }

  /// Get token statistics for debugging
  Future<Map<String, dynamic>> getTokenStats() async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) {
        return {'error': 'No authenticated user'};
      }

      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (!userDoc.exists) {
        return {'error': 'User document not found'};
      }

      final data = userDoc.data() as Map<String, dynamic>;
      final token = data['voipToken'] as String?;
      final tokenUpdatedAt = data['voipTokenUpdatedAt'] as Timestamp?;
      final refreshNeeded = data['voipTokenRefreshNeeded'] as bool?;

      return {
        'hasToken': token != null,
        'tokenPrefix': token?.substring(0, 20),
        'tokenAge': tokenUpdatedAt != null
            ? DateTime.now().difference(tokenUpdatedAt.toDate()).inDays
            : null,
        'refreshNeeded': refreshNeeded ?? false,
        'isValid': await isTokenValid(),
      };
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}
