//
//  TaliaPhotoCache.swift
//  Runner
//
//  Created by Claude Code on 2025-11-24.
//  ✅ UNIFIED: Helper compartido para cache de fotos entre AppDelegate y NSE
//

import Foundation
import UIKit

/// ✅ UNIFIED: Helper centralizado para acceder al cache de fotos
/// Comparte datos entre app principal y Notification Service Extension vía App Group
class TaliaPhotoCache {

    // ✅ CRITICAL: App Group ID (debe coincidir con entitlements)
    private static let appGroupId = "group.com.talia.chat"

    // ✅ CRITICAL: Key prefix para UserDefaults compartido
    private static let photoCacheKeyPrefix = "talia_photo_cache_"

    /// Get cached photo from shared UserDefaults (0ms latency)
    /// - Parameter userId: User ID whose photo to retrieve
    /// - Returns: UIImage if cached, nil otherwise
    static func getCachedPhoto(userId: String) -> UIImage? {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            NSLog("❌ [PhotoCache] Could not access shared UserDefaults")
            return nil
        }

        let key = photoCacheKeyPrefix + userId

        guard let imageData = sharedDefaults.data(forKey: key) else {
            NSLog("⚠️ [PhotoCache] Cache MISS for: \(userId)")
            return nil
        }

        guard let image = UIImage(data: imageData) else {
            NSLog("❌ [PhotoCache] Invalid image data for: \(userId)")
            return nil
        }

        NSLog("✅ [PhotoCache] Cache HIT for: \(userId) (\(imageData.count) bytes)")
        return image
    }

    /// Save photo to shared UserDefaults
    /// - Parameters:
    ///   - userId: User ID to associate with photo
    ///   - image: UIImage to cache
    static func savePhoto(userId: String, image: UIImage) {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            NSLog("❌ [PhotoCache] Could not access shared UserDefaults for saving")
            return
        }

        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            NSLog("❌ [PhotoCache] Could not convert image to JPEG data")
            return
        }

        let key = photoCacheKeyPrefix + userId
        sharedDefaults.set(imageData, forKey: key)
        sharedDefaults.synchronize()  // Force write

        NSLog("✅ [PhotoCache] Saved photo for: \(userId) (\(imageData.count) bytes)")
    }

    /// Save photo from Data
    /// - Parameters:
    ///   - userId: User ID to associate with photo
    ///   - data: Image data (JPEG/PNG)
    static func savePhotoData(userId: String, data: Data) {
        guard let image = UIImage(data: data) else {
            NSLog("❌ [PhotoCache] Invalid image data")
            return
        }
        savePhoto(userId: userId, image: image)
    }

    /// Remove cached photo
    /// - Parameter userId: User ID whose photo to remove
    static func removePhoto(userId: String) {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            return
        }

        let key = photoCacheKeyPrefix + userId
        sharedDefaults.removeObject(forKey: key)
        sharedDefaults.synchronize()

        NSLog("🗑️ [PhotoCache] Removed photo for: \(userId)")
    }

    /// Clear all cached photos
    static func clearAll() {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            return
        }

        // Get all keys with our prefix
        let allKeys = sharedDefaults.dictionaryRepresentation().keys
        let photoKeys = allKeys.filter { $0.hasPrefix(photoCacheKeyPrefix) }

        for key in photoKeys {
            sharedDefaults.removeObject(forKey: key)
        }

        sharedDefaults.synchronize()
        NSLog("🧹 [PhotoCache] Cleared all cached photos (\(photoKeys.count) items)")
    }

    /// Get cache stats for debugging
    static func getStats() -> [String: Any] {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            return ["error": "Cannot access shared UserDefaults"]
        }

        let allKeys = sharedDefaults.dictionaryRepresentation().keys
        let photoKeys = allKeys.filter { $0.hasPrefix(photoCacheKeyPrefix) }

        var totalBytes = 0
        for key in photoKeys {
            if let data = sharedDefaults.data(forKey: key) {
                totalBytes += data.count
            }
        }

        return [
            "cachedPhotos": photoKeys.count,
            "totalBytes": totalBytes,
            "totalMB": Double(totalBytes) / (1024.0 * 1024.0)
        ]
    }
}
