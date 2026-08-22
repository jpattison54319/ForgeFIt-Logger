import ForgeCore
import ForgeData
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import ForgeFit

/// A user's exercise photos and description are device-local files. These lock
/// both halves of that: the file behaviour the editor depends on, and the
/// promise that nothing carries them off the device.
@MainActor
struct CustomExerciseMediaTests {

    /// Every test works on its own exercise id and cleans up after itself —
    /// the store is a real directory under Application Support, shared by the
    /// whole test host.
    private func withExercise(_ body: (UUID) throws -> Void) rethrows {
        let id = UUID()
        defer { CustomExerciseMedia.shared.deleteAll(for: id) }
        try body(id)
    }

    #if canImport(UIKit)
    private func imageData(_ color: UIColor, size: CGFloat = 40) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    // MARK: - Photos

    @Test
    func storesEachPositionUnderItsOwnSlot() throws {
        try withExercise { id in
            #expect(CustomExerciseMedia.shared.photoURLs(for: id).isEmpty)
            try CustomExerciseMedia.shared.apply(
                ExercisePhotoSet(start: .new(imageData(.red)), end: .new(imageData(.green))),
                for: id
            )
            #expect(CustomExerciseMedia.shared.photoURL(for: id, slot: .start)?.lastPathComponent == "start.jpg")
            #expect(CustomExerciseMedia.shared.photoURL(for: id, slot: .end)?.lastPathComponent == "end.jpg")
            #expect(CustomExerciseMedia.shared.animates(for: id))
            #expect(CustomExerciseMedia.shared.photoURLs(for: id).count == 2)
        }
    }

    /// Either position stands alone. An end-only exercise still has a photo to
    /// show, and it must not be mistaken for an animation.
    @Test
    func oneSlotAloneIsAValidExercise() throws {
        try withExercise { id in
            try CustomExerciseMedia.shared.apply(ExercisePhotoSet(end: .new(imageData(.green))), for: id)
            #expect(CustomExerciseMedia.shared.hasPhotos(for: id))
            #expect(!CustomExerciseMedia.shared.animates(for: id))
            #expect(CustomExerciseMedia.shared.photoURL(for: id, slot: .start) == nil)
            #expect(CustomExerciseMedia.shared.photoURLs(for: id).count == 1)
        }
    }

    /// The thumbnail every list shows is the start position, or the end when
    /// that is the only photo — never nothing.
    @Test
    func theThumbnailFallsBackToWhicheverPositionExists() async throws {
        try withExercise { id in
            try CustomExerciseMedia.shared.apply(ExercisePhotoSet(end: .new(imageData(.blue))), for: id)
            #expect(CustomExerciseMedia.shared.photoURLs(for: id).first?.lastPathComponent == "end.jpg")
        }
        try withExercise { id in
            try CustomExerciseMedia.shared.apply(
                ExercisePhotoSet(start: .new(imageData(.red)), end: .new(imageData(.blue))),
                for: id
            )
            #expect(CustomExerciseMedia.shared.photoURLs(for: id).first?.lastPathComponent == "start.jpg")
        }
    }

    /// Swapping the two positions is a reorder of the same drafts, so the
    /// bytes have to follow the slot rather than the file they came from.
    @Test
    func swappingPositionsMovesTheBytes() throws {
        try withExercise { id in
            try CustomExerciseMedia.shared.apply(
                ExercisePhotoSet(start: .new(imageData(.red)), end: .new(imageData(.green))),
                for: id
            )
            let originalStart = try Data(contentsOf: #require(CustomExerciseMedia.shared.photoURL(for: id, slot: .start)))
            let stored = CustomExerciseMedia.shared.photoSet(for: id)

            try CustomExerciseMedia.shared.apply(
                ExercisePhotoSet(start: stored.end, end: stored.start),
                for: id
            )
            let newEnd = try Data(contentsOf: #require(CustomExerciseMedia.shared.photoURL(for: id, slot: .end)))
            let newStart = try Data(contentsOf: #require(CustomExerciseMedia.shared.photoURL(for: id, slot: .start)))
            #expect(newEnd == originalStart)
            #expect(newStart != originalStart)
        }
    }

    @Test
    func removingOnePositionLeavesTheOther() throws {
        try withExercise { id in
            try CustomExerciseMedia.shared.apply(
                ExercisePhotoSet(start: .new(imageData(.red)), end: .new(imageData(.green))),
                for: id
            )
            let keptEnd = try Data(contentsOf: #require(CustomExerciseMedia.shared.photoURL(for: id, slot: .end)))
            let stored = CustomExerciseMedia.shared.photoSet(for: id)

            try CustomExerciseMedia.shared.apply(ExercisePhotoSet(end: stored.end), for: id)
            #expect(CustomExerciseMedia.shared.photoURL(for: id, slot: .start) == nil)
            #expect(try Data(contentsOf: #require(CustomExerciseMedia.shared.photoURL(for: id, slot: .end))) == keptEnd)
            #expect(!CustomExerciseMedia.shared.animates(for: id))
        }
    }

    /// Camera originals are megabytes. Import re-encodes so a library of
    /// photos stays proportionate to a training app.
    @Test
    func downsamplesOnImport() throws {
        try withExercise { id in
            let large = imageData(.orange, size: 3000)
            try CustomExerciseMedia.shared.apply(ExercisePhotoSet(start: .new(large)), for: id)
            let stored = try #require(CustomExerciseMedia.shared.photoURL(for: id, slot: .start))
            let storedSize = try Data(contentsOf: stored).count
            #expect(storedSize < large.count)
            let image = try #require(UIImage(contentsOfFile: stored.path))
            #expect(max(image.size.width, image.size.height) <= 1600)
        }
    }

    @Test
    func applyingAnEmptySetClearsThePhotos() throws {
        try withExercise { id in
            try CustomExerciseMedia.shared.apply(ExercisePhotoSet(start: .new(imageData(.red))), for: id)
            try CustomExerciseMedia.shared.apply(.empty, for: id)
            #expect(CustomExerciseMedia.shared.photoURLs(for: id).isEmpty)
            #expect(!CustomExerciseMedia.shared.hasPhotos(for: id))
        }
    }

    /// A description must survive a photo edit — they are two independent
    /// fields that happen to share a directory.
    @Test
    func photoEditsLeaveTheDescriptionAlone() throws {
        try withExercise { id in
            try CustomExerciseMedia.shared.setNotes("Seat height 4", for: id)
            try CustomExerciseMedia.shared.apply(ExercisePhotoSet(start: .new(imageData(.red))), for: id)
            #expect(CustomExerciseMedia.shared.notes(for: id) == "Seat height 4")
            try CustomExerciseMedia.shared.apply(.empty, for: id)
            #expect(CustomExerciseMedia.shared.notes(for: id) == "Seat height 4")
        }
    }

    /// An unreadable pick is refused loudly. The form reports it instead of
    /// dismissing over a photo that silently never arrived.
    @Test
    func refusesDataThatIsNotAnImage() throws {
        try withExercise { id in
            #expect(throws: CustomExerciseMedia.MediaError.unreadableImage) {
                try CustomExerciseMedia.shared.apply(
                    ExercisePhotoSet(start: .new(Data("not an image".utf8))),
                    for: id
                )
            }
            #expect(CustomExerciseMedia.shared.photoURLs(for: id).isEmpty)
        }
    }
    #endif

    // MARK: - Description

    @Test
    func roundTripsADescription() throws {
        try withExercise { id in
            #expect(CustomExerciseMedia.shared.notes(for: id) == nil)
            try CustomExerciseMedia.shared.setNotes("  Pin 7, elbows tucked  ", for: id)
            #expect(CustomExerciseMedia.shared.notes(for: id) == "Pin 7, elbows tucked")
        }
    }

    /// Clearing the field means there is no description, not an empty one that
    /// renders as a blank card.
    @Test
    func clearingADescriptionRemovesIt() throws {
        try withExercise { id in
            try CustomExerciseMedia.shared.setNotes("Pin 7", for: id)
            try CustomExerciseMedia.shared.setNotes("   ", for: id)
            #expect(CustomExerciseMedia.shared.notes(for: id) == nil)
        }
    }

    // MARK: - Deletion

    @Test
    func deletingAnExerciseTakesItsMedia() throws {
        let id = UUID()
        try CustomExerciseMedia.shared.setNotes("Pin 7", for: id)
        CustomExerciseMedia.shared.deleteAll(for: id)
        #expect(CustomExerciseMedia.shared.notes(for: id) == nil)
    }

    /// Reset promises the device is left with nothing. Files under Application
    /// Support outlive a model wipe, so the store has to be cleared too.
    @Test
    func resetClearsTheWholeStore() throws {
        let first = UUID()
        let second = UUID()
        try CustomExerciseMedia.shared.setNotes("one", for: first)
        try CustomExerciseMedia.shared.setNotes("two", for: second)
        CustomExerciseMedia.shared.deleteEverything()
        #expect(CustomExerciseMedia.shared.notes(for: first) == nil)
        #expect(CustomExerciseMedia.shared.notes(for: second) == nil)
        #expect(!FileManager.default.fileExists(atPath: CustomExerciseMedia.rootDirectory.path))
    }

    // MARK: - Local-only invariant

    /// The reason this lives in files rather than on `ExerciseLibraryModel`:
    /// that model is in the plan store, which mirrors to CloudKit. A photo or
    /// description attribute there would sync by construction.
    @Test
    func theExerciseModelCarriesNoPhotoOrDescriptionAttribute() {
        let exercise = ExerciseLibraryModel(name: "Atlantis Press")
        let mirror = Mirror(reflecting: exercise)
        let names = mirror.children.compactMap(\.label).map { $0.lowercased() }
        #expect(!names.contains { $0.contains("photo") })
        #expect(!names.contains { $0.contains("userdescription") })
        #expect(ForgeDataSchema.planModels.contains { $0 == ExerciseLibraryModel.self })
    }

    /// The policy promises this in two places that must not drift: the
    /// in-app screen and the published document.
    @Test
    func thePrivacyPolicyStatesTheLocalOnlyPromiseInBothPlaces() throws {
        let phrase = "are stored as ordinary files on that iPhone only"
        let view = try readRepoFile("ForgeFit", "Settings", "PrivacyPolicyView.swift", file: #filePath)
        let document = try readRepoFile("docs", "privacy-policy.md", file: #filePath)
        #expect(normalized(view).contains(normalized(phrase)))
        #expect(normalized(document).contains(normalized(phrase)))
    }

    private func readRepoFile(_ components: String..., file: String) throws -> String {
        // #filePath is the test source on the host; walking up two levels
        // from ForgeFitTests/ lands on the repository root.
        let repoRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = components.reduce(repoRoot) { $0.appendingPathComponent($1) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The files sit in the app's own container, never in the iCloud
    /// ubiquity container the workout backup is written to — the one
    /// directory on the device whose contents leave it.
    @Test
    func mediaLivesOutsideTheICloudContainer() {
        let root = CustomExerciseMedia.rootDirectory.standardizedFileURL.path
        #expect(root.contains("CustomExerciseMedia"))
        #expect(!root.contains("Mobile Documents"))
        #expect(!root.contains(BackupExporter.containerID))
    }

    /// End-to-end: the backup file the app writes to iCloud Drive is built
    /// from the workout models. Encode one whose exercise carries a photo and
    /// a description, and neither may appear anywhere in the bytes.
    @Test
    func theBackupPayloadCarriesNoPhotoOrDescription() throws {
        let exerciseID = UUID()
        defer { CustomExerciseMedia.shared.deleteAll(for: exerciseID) }
        let secret = "Seat height 4, handles wide"
        try CustomExerciseMedia.shared.setNotes(secret, for: exerciseID)
        #if canImport(UIKit)
        try CustomExerciseMedia.shared.apply(ExercisePhotoSet(start: .new(imageData(.red))), for: exerciseID)
        #endif

        let workout = WorkoutModel(userID: UUID(), startedAt: Date())
        let row = WorkoutExerciseModel(userID: workout.userID, exerciseID: exerciseID, position: 0)
        workout.exercises = [row]
        let backup = BackupMapper.backupWorkout(
            from: workout,
            exerciseNames: [exerciseID: "Atlantis Press"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(String(data: try encoder.encode(backup), encoding: .utf8))
        #expect(!json.contains(secret))
        #expect(!json.lowercased().contains("customexercisemedia"))
        #expect(!json.lowercased().contains("photo"))
    }
}
