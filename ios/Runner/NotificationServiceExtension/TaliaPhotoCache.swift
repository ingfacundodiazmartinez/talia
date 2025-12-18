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
    private static let photoUrlKeyPrefix = "talia_photo_url_"  // ✅ FIX: Guardar URL para detectar cambios

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

    /// ✅ FIX: Get cached photo ONLY if URL matches (to detect profile photo updates)
    /// - Parameters:
    ///   - userId: User ID whose photo to retrieve
    ///   - currentUrl: The current photo URL from notification payload
    /// - Returns: UIImage if cached AND URL matches, nil otherwise (forces re-download)
    static func getCachedPhotoIfUrlMatches(userId: String, currentUrl: String?) -> UIImage? {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            NSLog("❌ [PhotoCache] Could not access shared UserDefaults")
            return nil
        }

        // First check if URLs match
        let urlKey = photoUrlKeyPrefix + userId
        let cachedUrl = sharedDefaults.string(forKey: urlKey)

        // If currentUrl is provided and differs from cached, return nil to force re-download
        if let current = currentUrl, !current.isEmpty, current != "null" {
            if cachedUrl != current {
                NSLog("🔄 [PhotoCache] URL changed for \(userId): cached=\(cachedUrl?.prefix(30) ?? "nil")... vs new=\(current.prefix(30))...")
                return nil  // Force re-download
            }
        }

        // URLs match (or no URL to compare), return cached photo if exists
        let photoKey = photoCacheKeyPrefix + userId

        guard let imageData = sharedDefaults.data(forKey: photoKey) else {
            NSLog("⚠️ [PhotoCache] Cache MISS for: \(userId)")
            return nil
        }

        guard let image = UIImage(data: imageData) else {
            NSLog("❌ [PhotoCache] Invalid image data for: \(userId)")
            return nil
        }

        NSLog("✅ [PhotoCache] Cache HIT (URL match) for: \(userId) (\(imageData.count) bytes)")
        return image
    }

    /// Save photo to shared UserDefaults
    /// - Parameters:
    ///   - userId: User ID to associate with photo
    ///   - image: UIImage to cache
    ///   - photoUrl: Optional URL to store for cache invalidation
    static func savePhoto(userId: String, image: UIImage, photoUrl: String? = nil) {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            NSLog("❌ [PhotoCache] Could not access shared UserDefaults for saving")
            return
        }

        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            NSLog("❌ [PhotoCache] Could not convert image to JPEG data")
            return
        }

        let photoKey = photoCacheKeyPrefix + userId
        sharedDefaults.set(imageData, forKey: photoKey)

        // ✅ FIX: Also save the URL for cache invalidation
        if let url = photoUrl, !url.isEmpty, url != "null" {
            let urlKey = photoUrlKeyPrefix + userId
            sharedDefaults.set(url, forKey: urlKey)
            NSLog("✅ [PhotoCache] Saved photo + URL for: \(userId) (\(imageData.count) bytes)")
        } else {
            NSLog("✅ [PhotoCache] Saved photo for: \(userId) (\(imageData.count) bytes)")
        }

        sharedDefaults.synchronize()  // Force write
    }

    /// Save photo from Data
    /// - Parameters:
    ///   - userId: User ID to associate with photo
    ///   - data: Image data (JPEG/PNG)
    ///   - photoUrl: Optional URL to store for cache invalidation
    static func savePhotoData(userId: String, data: Data, photoUrl: String? = nil) {
        guard let image = UIImage(data: data) else {
            NSLog("❌ [PhotoCache] Invalid image data")
            return
        }
        savePhoto(userId: userId, image: image, photoUrl: photoUrl)
    }

    /// Remove cached photo
    /// - Parameter userId: User ID whose photo to remove
    static func removePhoto(userId: String) {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            return
        }

        let photoKey = photoCacheKeyPrefix + userId
        let urlKey = photoUrlKeyPrefix + userId
        sharedDefaults.removeObject(forKey: photoKey)
        sharedDefaults.removeObject(forKey: urlKey)  // ✅ FIX: Also remove URL
        sharedDefaults.synchronize()

        NSLog("🗑️ [PhotoCache] Removed photo + URL for: \(userId)")
    }

    /// Clear all cached photos
    static func clearAll() {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupId) else {
            return
        }

        // Get all keys with our prefixes
        let allKeys = sharedDefaults.dictionaryRepresentation().keys
        let photoKeys = allKeys.filter { $0.hasPrefix(photoCacheKeyPrefix) }
        let urlKeys = allKeys.filter { $0.hasPrefix(photoUrlKeyPrefix) }  // ✅ FIX: Also clear URLs

        for key in photoKeys {
            sharedDefaults.removeObject(forKey: key)
        }
        for key in urlKeys {
            sharedDefaults.removeObject(forKey: key)
        }

        sharedDefaults.synchronize()
        NSLog("🧹 [PhotoCache] Cleared all cached photos + URLs (\(photoKeys.count) photos, \(urlKeys.count) URLs)")
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
