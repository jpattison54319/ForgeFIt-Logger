import Foundation
import Observation
#if canImport(Darwin)
import Darwin
#endif
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
struct ExercisePhotoDraft: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case stored(URL)
        case new(Data)
        /// Already normalized to the app's bounded JPEG representation. The
        /// photo picker produces this off the main actor so Save only performs
        /// file operations.
        case prepared(Data)
    }

    let kind: Kind

    static func stored(_ url: URL) -> ExercisePhotoDraft { ExercisePhotoDraft(kind: .stored(url)) }
    static func new(_ data: Data) -> ExercisePhotoDraft { ExercisePhotoDraft(kind: .new(data)) }
    static func prepared(_ data: Data) -> ExercisePhotoDraft { ExercisePhotoDraft(kind: .prepared(data)) }
}

/// The pair of photos an exercise can hold. Either slot may be empty: one
/// photo of the machine is a complete answer, and so is a start/end pair.
struct ExercisePhotoSet: Equatable, Sendable {
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
    nonisolated private static let maxStoredPixelSize: CGFloat = 1600
    nonisolated private static let compressionQuality: CGFloat = 0.8

    /// Bumped on every mutation. Views read it through the accessors below, so
    /// a thumbnail on any screen refreshes the moment a photo changes.
    private(set) var revision = 0

    #if canImport(UIKit)
    private let thumbnailCache = NSCache<NSString, UIImage>()
    #endif

    private init() {}

    /// Deterministic failure seams for transaction regression tests. These are
    /// main-actor isolated with the store and never consulted in release builds.
    enum TransactionFailurePoint: Equatable {
        case beforeInstall
        case afterInstall
    }

    #if DEBUG
    var transactionFailurePointForTesting: TransactionFailurePoint?
    #endif

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
        try apply(photos: photos, notes: notes(for: exerciseID), for: exerciseID)
    }
    #endif

    /// Commits the complete media record as one directory transaction. Photos
    /// and description either all become visible together or the previous
    /// directory is restored byte-for-byte.
    func apply(photos: ExercisePhotoSet, notes text: String?, for exerciseID: UUID) throws {
        let fileManager = FileManager.default
        let live = directory(for: exerciseID)
        let transactionID = UUID().uuidString
        let staging = Self.rootDirectory.appending(
            path: ".\(exerciseID.uuidString).\(transactionID).staging",
            directoryHint: .isDirectory
        )
        let hadLiveDirectory = fileManager.fileExists(atPath: live.path)

        do {
            try fileManager.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer {
                try? fileManager.removeItem(at: staging)
            }

            #if canImport(UIKit)
            for slot in ExercisePhotoSlot.allCases {
                guard let draft = photos[slot] else { continue }
                let destination = staging.appending(path: slot.fileName, directoryHint: .notDirectory)
                switch draft.kind {
                case .stored(let url):
                    try fileManager.copyItem(at: url, to: destination)
                case .new(let data):
                    guard let stored = Self.reencodedForStorage(data) else {
                        throw MediaError.unreadableImage
                    }
                    try stored.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                case .prepared(let data):
                    try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            }
            #endif

            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                let notes = staging.appending(path: "notes.txt", directoryHint: .notDirectory)
                try Data(trimmed.utf8).write(
                    to: notes,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            }

            try failForTesting(at: .beforeInstall)

            if hadLiveDirectory {
                // Both directories live under the same Application Support
                // root, so Darwin can exchange their names atomically. After
                // the swap `live` is the complete new record and `staging` is
                // the untouched previous record, ready for an exact rollback.
                try swapDirectories(staging, live)
            } else {
                try fileManager.moveItem(at: staging, to: live)
            }

            do {
                try failForTesting(at: .afterInstall)
            } catch {
                if hadLiveDirectory {
                    try swapDirectories(staging, live)
                } else if fileManager.fileExists(atPath: live.path) {
                    try fileManager.removeItem(at: live)
                }
                throw error
            }

            invalidate(exerciseID)
        } catch let error as MediaError {
            throw error
        } catch {
            throw MediaError.couldNotWrite
        }
    }

    /// Throws rather than swallowing: a description the user typed and lost is
    /// exactly as bad as a photo they lost, and the form reports both.
    func setNotes(_ text: String?, for exerciseID: UUID) throws {
        try apply(photos: photoSet(for: exerciseID), notes: text, for: exerciseID)
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

    /// The picker can hand over a multi-megabyte camera original. Normalize it
    /// before placing it in SwiftUI state so the editor retains only bounded
    /// data and Save never performs image work on the main actor.
    nonisolated static func preparedForStorage(_ data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            reencodedForStorage(data)
        }.value
    }

    nonisolated static func previewImage(
        for draft: ExercisePhotoDraft,
        maxPixelSize: CGFloat
    ) async -> UIImage? {
        switch draft.kind {
        case .stored(let url):
            await downsampled(url: url, maxPixelSize: maxPixelSize)
        case .new(let data), .prepared(let data):
            await Task.detached(priority: .userInitiated) {
                downsampled(data: data, maxPixelSize: maxPixelSize)
            }.value
        }
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

    /// Atomically exchanges two existing directories on the same volume.
    /// There is never an instant where the live record is absent or partial.
    private func swapDirectories(_ first: URL, _ second: URL) throws {
        #if canImport(Darwin)
        let result = first.withUnsafeFileSystemRepresentation { firstPath in
            second.withUnsafeFileSystemRepresentation { secondPath in
                guard let firstPath, let secondPath else { return Int32(-1) }
                return renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else { throw MediaError.couldNotWrite }
        #else
        throw MediaError.couldNotWrite
        #endif
    }

    private func failForTesting(at point: TransactionFailurePoint) throws {
        #if DEBUG
        guard transactionFailurePointForTesting == point else { return }
        transactionFailurePointForTesting = nil
        throw MediaError.couldNotWrite
        #endif
    }
}
