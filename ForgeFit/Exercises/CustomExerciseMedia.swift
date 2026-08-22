import Foundation
import Observation
#if canImport(UIKit)
import ImageIO
import UIKit
#endif

/// Which position in the movement a photo shows. Two slots, because that is
/// what an exercise photo is for: the start of the rep and the end of it. With
/// both filled the exercise screen animates between them, the same way the
/// bundled illustrations do.
enum ExercisePhotoSlot: String, CaseIterable, Sendable {
    case start
    case end

    var title: String {
        switch self {
        case .start: "Start"
        case .end: "End"
        }
    }

    var fileName: String { "\(rawValue).jpg" }
}

/// One photo in the editor: either the one already stored in this slot, or one
/// the user just picked and hasn't committed yet.
struct ExercisePhotoDraft: Equatable {
    enum Kind: Equatable {
        case stored(URL)
        case new(Data)
    }

    let kind: Kind

    static func stored(_ url: URL) -> ExercisePhotoDraft { ExercisePhotoDraft(kind: .stored(url)) }
    static func new(_ data: Data) -> ExercisePhotoDraft { ExercisePhotoDraft(kind: .new(data)) }
}

/// The pair of photos an exercise can hold. Either slot may be empty: one
/// photo of the machine is a complete answer, and so is a start/end pair.
struct ExercisePhotoSet: Equatable {
    var start: ExercisePhotoDraft?
    var end: ExercisePhotoDraft?

    static let empty = ExercisePhotoSet()

    var isEmpty: Bool { start == nil && end == nil }
    /// Both positions present is what turns two stills into a movement.
    var animates: Bool { start != nil && end != nil }

    subscript(slot: ExercisePhotoSlot) -> ExercisePhotoDraft? {
        get { slot == .start ? start : end }
        set { if slot == .start { start = newValue } else { end = newValue } }
    }
}

/// A user's own exercise photos and written description, kept on this device
/// only.
///
/// Deliberately NOT a SwiftData attribute. `ExerciseLibraryModel` lives in the
/// plan store, which mirrors to CloudKit automatically — anything added there
/// syncs, and these are the user's own camera-roll images and private notes.
/// Holding them as files under Application Support makes "local only" a
/// property of where the bytes are, not a promise some future field has to
/// keep. Nothing here is written into the iCloud Drive backup, a data export,
/// a shared plan, or a shared workout.
///
/// The files are NOT excluded from the system device backup: the app's own
/// backup deliberately does not carry them, so a device restore is the only
/// way a user's photos survive a lost phone. That is Apple's encrypted device
/// backup, not app-driven sync.
///
/// Layout, one directory per exercise:
///
///     CustomExerciseMedia/{exerciseID}/start.jpg
///     CustomExerciseMedia/{exerciseID}/end.jpg
///     CustomExerciseMedia/{exerciseID}/notes.txt
///
/// The slot is the filename, so either photo can exist without the other and
/// there is no index bookkeeping to fall out of step with the files.
@Observable
@MainActor
final class CustomExerciseMedia {
    static let shared = CustomExerciseMedia()

    /// Longest edge kept on import. A camera-roll original is ~4000px and
    /// several megabytes; nothing in the app renders one larger than a phone
    /// screen.
    private static let maxStoredPixelSize: CGFloat = 1600
    private static let compressionQuality: CGFloat = 0.8

    /// Bumped on every mutation. Views read it through the accessors below, so
    /// a thumbnail on any screen refreshes the moment a photo changes.
    private(set) var revision = 0

    #if canImport(UIKit)
    private let thumbnailCache = NSCache<NSString, UIImage>()
    #endif

    private init() {}

    // MARK: - Locations

    static var rootDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "CustomExerciseMedia", directoryHint: .isDirectory)
    }

    private func directory(for exerciseID: UUID) -> URL {
        Self.rootDirectory.appending(path: exerciseID.uuidString, directoryHint: .isDirectory)
    }

    private func fileURL(for exerciseID: UUID, slot: ExercisePhotoSlot) -> URL {
        directory(for: exerciseID).appending(path: slot.fileName, directoryHint: .notDirectory)
    }

    private func notesURL(for exerciseID: UUID) -> URL {
        directory(for: exerciseID).appending(path: "notes.txt", directoryHint: .notDirectory)
    }

    // MARK: - Reading

    /// The stored photo for one slot, or nil when that slot is empty.
    func photoURL(for exerciseID: UUID, slot: ExercisePhotoSlot) -> URL? {
        _ = revision
        let url = fileURL(for: exerciseID, slot: slot)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Every stored photo, start first. One entry when only one slot is
    /// filled, two when the exercise animates.
    func photoURLs(for exerciseID: UUID) -> [URL] {
        ExercisePhotoSlot.allCases.compactMap { photoURL(for: exerciseID, slot: $0) }
    }

    func hasPhotos(for exerciseID: UUID) -> Bool { !photoURLs(for: exerciseID).isEmpty }

    /// True only when both positions exist, which is what makes the exercise
    /// screen animate through the movement instead of showing one frame.
    func animates(for exerciseID: UUID) -> Bool {
        photoURL(for: exerciseID, slot: .start) != nil && photoURL(for: exerciseID, slot: .end) != nil
    }

    /// The stored photos as editor drafts, so the form opens on what the
    /// exercise already holds.
    func photoSet(for exerciseID: UUID) -> ExercisePhotoSet {
        ExercisePhotoSet(
            start: photoURL(for: exerciseID, slot: .start).map(ExercisePhotoDraft.stored),
            end: photoURL(for: exerciseID, slot: .end).map(ExercisePhotoDraft.stored)
        )
    }

    /// The user's own description, or nil when they haven't written one.
    func notes(for exerciseID: UUID) -> String? {
        _ = revision
        guard let text = try? String(contentsOf: notesURL(for: exerciseID), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    #if canImport(UIKit)
    /// Row-sized thumbnail of whichever photo represents the exercise (the
    /// start position, or the end when that is the only one). Decoded and
    /// downsampled off the main thread on first use and cached after, exactly
    /// like the bundled illustrations.
    func cachedThumbnail(for exerciseID: UUID) -> UIImage? {
        _ = revision
        return thumbnailCache.object(forKey: cacheKey(exerciseID))
    }

    @discardableResult
    func primeThumbnail(for exerciseID: UUID, maxPixelSize: CGFloat = 46 * 3) async -> UIImage? {
        _ = revision
        if let cached = thumbnailCache.object(forKey: cacheKey(exerciseID)) { return cached }
        guard let url = photoURLs(for: exerciseID).first else { return nil }
        let image = await Self.downsampled(url: url, maxPixelSize: maxPixelSize)
        if let image { thumbnailCache.setObject(image, forKey: cacheKey(exerciseID)) }
        return image
    }
    #endif

    // MARK: - Writing

    enum MediaError: LocalizedError, Equatable {
        case unreadableImage
        case couldNotWrite

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "That image could not be read."
            case .couldNotWrite: "This device could not save the change."
            }
        }
    }

    #if canImport(UIKit)
    /// Commits an edited pair in one step: the exercise ends up holding
    /// exactly these photos, in these slots.
    ///
    /// The editor stages its changes and applies them on Save, so a form the
    /// user cancels leaves their photos exactly as they were — the same
    /// contract every other field on that form has. Written through a staging
    /// directory so a failure part-way cannot leave the exercise holding one
    /// new photo and one stale one.
    func apply(_ photos: ExercisePhotoSet, for exerciseID: UUID) throws {
        let directory = directory(for: exerciseID)
        let staging = directory.appending(path: ".staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for slot in ExercisePhotoSlot.allCases {
            guard let draft = photos[slot] else { continue }
            let destination = staging.appending(path: slot.fileName, directoryHint: .notDirectory)
            switch draft.kind {
            case .stored(let url):
                try FileManager.default.copyItem(at: url, to: destination)
            case .new(let data):
                guard let stored = Self.reencodedForStorage(data) else { throw MediaError.unreadableImage }
                try stored.write(to: destination, options: .atomic)
            }
        }

        for slot in ExercisePhotoSlot.allCases {
            try? FileManager.default.removeItem(at: fileURL(for: exerciseID, slot: slot))
            let staged = staging.appending(path: slot.fileName, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: staged.path) else { continue }
            try FileManager.default.moveItem(at: staged, to: fileURL(for: exerciseID, slot: slot))
        }
        invalidate(exerciseID)
    }
    #endif

    /// Throws rather than swallowing: a description the user typed and lost is
    /// exactly as bad as a photo they lost, and the form reports both.
    func setNotes(_ text: String?, for exerciseID: UUID) throws {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let url = notesURL(for: exerciseID)
        defer { invalidate(exerciseID) }
        guard !trimmed.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory(for: exerciseID), withIntermediateDirectories: true)
            try Data(trimmed.utf8).write(to: url, options: .atomic)
        } catch {
            throw MediaError.couldNotWrite
        }
    }

    /// Everything one exercise owns. No in-app flow deletes a single exercise
    /// today; this exists so the flow that adds one has the call to make, and
    /// so a fixture can clear a single row.
    func deleteAll(for exerciseID: UUID) {
        try? FileManager.default.removeItem(at: directory(for: exerciseID))
        invalidate(exerciseID)
    }

    /// Whole-store wipe for account reset. The reset promises the device is
    /// left with nothing; photos on disk would outlive it otherwise.
    func deleteEverything() {
        try? FileManager.default.removeItem(at: Self.rootDirectory)
        #if canImport(UIKit)
        thumbnailCache.removeAllObjects()
        #endif
        revision &+= 1
    }

    // MARK: - Internals

    // There is deliberately no orphan sweep. A directory whose exercise no
    // longer exists costs a few kilobytes; a sweep that runs while the plan
    // store is mid-sync and sees a short library would delete photos the user
    // cannot get back. Account reset clears the whole store instead.

    private func invalidate(_ exerciseID: UUID) {
        #if canImport(UIKit)
        thumbnailCache.removeObject(forKey: cacheKey(exerciseID))
        #endif
        revision &+= 1
    }

    #if canImport(UIKit)
    private func cacheKey(_ exerciseID: UUID) -> NSString {
        "custom-thumb:\(exerciseID.uuidString)" as NSString
    }

    /// Downsample + re-encode on import. Keeps a library of user photos in the
    /// tens of KB each rather than the multi-megabyte camera originals.
    nonisolated static func reencodedForStorage(_ data: Data) -> Data? {
        downsampled(data: data, maxPixelSize: maxStoredPixelSize)?
            .jpegData(compressionQuality: compressionQuality)
    }

    /// Shared ImageIO downsample, used for storage, for row thumbnails, and by
    /// the editor's own tiles — nothing in the app decodes a camera-sized
    /// original just to draw it small.
    nonisolated static func downsampled(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsampled(source: source, maxPixelSize: maxPixelSize)
    }

    nonisolated static func downsampled(url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return downsampled(source: source, maxPixelSize: maxPixelSize)
        }.value
    }

    private nonisolated static func downsampled(source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
    #endif
}
