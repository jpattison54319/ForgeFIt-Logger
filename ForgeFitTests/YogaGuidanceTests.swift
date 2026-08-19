import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct YogaGuidanceTests {
    @Test func everyBundledPoseHasCompleteReviewedGuidance() throws {
        let poses = YogaPoseCatalog.load()
        #expect(poses.count == 30)
        #expect(YogaGuidanceCatalog.poses.count == poses.count)
        #expect(YogaGuidanceCatalog.reviewStatus.contains("source-audited"))

        let poseSlugs = Set(poses.map(\.slug))
        let guidanceSlugs = Set(YogaGuidanceCatalog.poses.map(\.slug))
        #expect(guidanceSlugs == poseSlugs)

        for pose in poses {
            let guidance = try #require(YogaGuidanceCatalog.guidance(forSlug: pose.slug))
            #expect(!guidance.cues.entry.isEmpty, "\(pose.slug): entry")
            #expect(!guidance.cues.alignment.isEmpty, "\(pose.slug): alignment")
            #expect(!guidance.cues.breath.isEmpty, "\(pose.slug): breath")
            #expect(!guidance.cues.options.isEmpty, "\(pose.slug): options")
            #expect(!guidance.cues.reflection.isEmpty, "\(pose.slug): reflection")
            #expect(!guidance.cues.exit.isEmpty, "\(pose.slug): exit")
            #expect(!guidance.considerations.isEmpty, "\(pose.slug): considerations")
            #expect(!guidance.sources.isEmpty, "\(pose.slug): sources")
            #expect(guidance.sources.allSatisfy { $0.url.scheme == "https" })

            let script = guidance.cues.technique.joined(separator: " ").lowercased()
            for legacyPhrase in [
                "same pose, other side",
                "square your hips",
                "two panes of glass",
                "rotate a little further",
                "lay it across the mat",
                "shift your weight slightly forward toward the balls"
            ] {
                #expect(!script.contains(legacyPhrase), "\(pose.slug): legacy cue `\(legacyPhrase)`")
            }
        }
    }

    @Test func everyUnilateralPoseResolvesToExplicitAndDifferentSides() throws {
        for pose in YogaPoseCatalog.load() where pose.unilateral {
            let guidance = try #require(YogaGuidanceCatalog.guidance(forSlug: pose.slug))
            let templates = guidance.cues.technique.joined(separator: " ")
            #expect(templates.contains("{side}") || templates.contains("{oppositeSide}"),
                    "\(pose.slug): no authored side semantics")

            let left = YogaGuidanceCatalog.resolved(templates, side: .left)
            let right = YogaGuidanceCatalog.resolved(templates, side: .right)
            #expect(left != right)
            #expect(left.contains("left"))
            #expect(right.contains("right"))
            #expect(!left.contains("{") && !right.contains("{"))
        }
    }

    @Test func pigeonStartsWithDiagonalShinAndNamesKneeAlternative() throws {
        let pigeon = try #require(YogaGuidanceCatalog.guidance(forSlug: "pigeon-pose"))
        let script = (pigeon.cues.technique + pigeon.considerations).joined(separator: " ").lowercased()
        #expect(script.contains("comfortable diagonal"))
        #expect(script.contains("reclined figure"))
        #expect(script.contains("knee"))
        #expect(script.contains("sacroiliac"))
        #expect(!script.contains("force your shin parallel"))
    }

    @Test func plannerIsDeterministicAndKeepsEveryClipInsideTheHold() throws {
        let context = YogaGuidancePlanningContext(
            poseSlug: "pigeon-pose",
            poseName: "Pigeon Pose",
            side: .left,
            holdSeconds: 120,
            style: .yin,
            isFirstStep: true
        )
        let first = YogaGuidancePlanner.plan(context: context, sessionSeed: 42, stepIndex: 3)
        let second = YogaGuidancePlanner.plan(context: context, sessionSeed: 42, stepIndex: 3)
        #expect(first == second)
        #expect(first.cues.first?.clip.kind == .poseName)
        #expect(first.cues.last?.clip.kind == .exit)

        for cue in first.cues {
            #expect(cue.offset >= 0)
            #expect(cue.offset + cue.estimatedDuration <= 120)
        }
        for pair in zip(first.cues, first.cues.dropFirst()) {
            #expect(pair.1.offset >= pair.0.offset + pair.0.estimatedDuration)
        }
    }

    @Test func shortHoldPrioritizesExplicitSetupAndExitOverFiller() {
        let context = YogaGuidancePlanningContext(
            poseSlug: "upward-facing-dog",
            poseName: "Upward-Facing Dog",
            side: nil,
            holdSeconds: 15,
            style: .vinyasa
        )
        let plan = YogaGuidancePlanner.plan(context: context, sessionSeed: 5, stepIndex: 0)
        let kinds = plan.cues.map(\.clip.kind)
        #expect(kinds.first == .poseName)
        #expect(kinds.contains(.entry))
        #expect(kinds.last == .exit)
        #expect(!kinds.contains(.reflection))
        #expect(!kinds.contains(.spiritual))
        #expect(!kinds.contains(.awareness))
    }

    @Test func longerHoldPlacesModularGuidanceAfterOnePromptRefinement() throws {
        let context = YogaGuidancePlanningContext(
            poseSlug: "pigeon-pose",
            poseName: "Pigeon Pose",
            side: .left,
            holdSeconds: 180,
            style: .yin
        )
        let plan = YogaGuidancePlanner.plan(context: context, sessionSeed: 51, stepIndex: 2)
        let entryIndex = try #require(plan.cues.firstIndex { $0.clip.kind == .entry })
        let refinementIndexes = plan.cues.indices.filter { index in
            [.alignment, .breath, .option].contains(plan.cues[index].clip.kind)
        }
        let firstRefinementIndex = try #require(refinementIndexes.first)
        let secondRefinementIndex = try #require(refinementIndexes.dropFirst().first)
        let firstVariableIndex = try #require(plan.cues.firstIndex { $0.clip.isVariableFiller })

        #expect(firstRefinementIndex > entryIndex)
        #expect(firstVariableIndex > firstRefinementIndex)
        #expect(firstVariableIndex < secondRefinementIndex)

        let entry = plan.cues[entryIndex]
        let firstRefinement = plan.cues[firstRefinementIndex]
        let refinementGap = firstRefinement.offset - (entry.offset + entry.estimatedDuration)
        #expect(refinementGap >= 0.79 && refinementGap <= 0.81)
        #expect(plan.cues.last?.clip.kind == .exit)
    }

    @Test func windDownSchedulesModularGuidanceWithMeasuredNarration() throws {
        let seed = try #require(YogaFlowCatalog.flow(forSlug: "wind-down"))
        let flow = YogaFlowCatalog.plan(for: seed)
        let runtimeSteps = YogaFlowRunner.expand(flow)
        let measuredDurations = try measuredManifestDurations()
        var plannedIDs = Set<String>()

        for (index, step) in runtimeSteps.enumerated() {
            let plan = YogaGuidancePlanner.plan(
                context: YogaGuidancePlanningContext(
                    poseSlug: step.poseStep.poseSlug,
                    poseName: step.poseStep.name,
                    side: step.side,
                    holdSeconds: step.seconds,
                    style: flow.style,
                    isFirstStep: index == 0
                ),
                sessionSeed: 42,
                stepIndex: index,
                excludedClipIDs: plannedIDs,
                measuredDurations: measuredDurations
            )
            #expect(plan.cues.contains { $0.clip.isVariableFiller }, "hold \(index)")
            plannedIDs.formUnion(plan.clipIDs)
        }
    }

    @Test func everyBundledFlowHoldFitsACompleteSetupAndExit() throws {
        for flow in YogaFlowCatalog.load() {
            for step in flow.steps {
                let pose = try #require(YogaPoseCatalog.pose(forSlug: step.poseSlug))
                let sides: [YogaFlowPlan.Side?] = pose.unilateral ? [.left, .right] : [nil]
                for side in sides {
                    let context = YogaGuidancePlanningContext(
                        poseSlug: pose.slug,
                        poseName: pose.name,
                        side: side,
                        holdSeconds: step.holdSeconds,
                        style: flow.style
                    )
                    expectCompleteCriticalGuidance(
                        YogaGuidancePlanner.plan(context: context, sessionSeed: 11, stepIndex: 0),
                        label: "\(flow.slug)/\(pose.slug)/\(side?.rawValue ?? "center")"
                    )
                }
            }
        }
    }

    @Test func everyPoseFitsCriticalGuidanceAtItsShortestGeneratedPowerHold() {
        let generatorInputs = Dictionary(
            uniqueKeysWithValues: YogaPoseCatalog.generatorInputs().map { ($0.slug, $0) }
        )
        for pose in YogaPoseCatalog.load() {
            let input = generatorInputs[pose.slug]
            let hold = max(
                min(max(pose.defaultHoldSeconds * 3 / 4, 15), 45),
                input?.minimumHoldSeconds ?? 1
            )
            let sides: [YogaFlowPlan.Side?] = pose.unilateral ? [.left, .right] : [nil]
            for side in sides {
                let context = YogaGuidancePlanningContext(
                    poseSlug: pose.slug,
                    poseName: pose.name,
                    side: side,
                    holdSeconds: hold,
                    style: .power
                )
                expectCompleteCriticalGuidance(
                    YogaGuidancePlanner.plan(context: context, sessionSeed: 23, stepIndex: 0),
                    label: "power/\(pose.slug)/\(side?.rawValue ?? "center")/\(hold)s"
                )
            }
        }
    }

    @Test func everyPoseCriticalMinimumFitsNameCanonicalEntryAndExitExactly() throws {
        for pose in YogaPoseCatalog.load() {
            let sides: [YogaFlowPlan.Side?] = pose.unilateral ? [.left, .right] : [nil]
            for side in sides {
                let baseContext = YogaGuidancePlanningContext(
                    poseSlug: pose.slug,
                    poseName: pose.name,
                    side: side,
                    holdSeconds: 1,
                    style: .hatha
                )
                let minimum = try #require(
                    YogaGuidancePlanner.minimumCriticalHoldSeconds(context: baseContext)
                )
                let context = YogaGuidancePlanningContext(
                    poseSlug: pose.slug,
                    poseName: pose.name,
                    side: side,
                    holdSeconds: minimum,
                    style: .hatha
                )
                expectCompleteCriticalGuidance(
                    YogaGuidancePlanner.plan(context: context, sessionSeed: 31, stepIndex: 0),
                    label: "minimum/\(pose.slug)/\(side?.rawValue ?? "center")/\(minimum)s"
                )
            }
        }
    }

    @Test func recentVariableGuidanceIsNotSelectedAgain() {
        let context = YogaGuidancePlanningContext(
            poseSlug: "savasana",
            poseName: "Savasana",
            side: nil,
            holdSeconds: 300,
            style: .restorative,
            isFirstStep: true
        )
        let baseline = YogaGuidancePlanner.plan(context: context, sessionSeed: 77, stepIndex: 0)
        let variable = Set(baseline.cues.filter(\.clip.isVariableFiller).map(\.clip.id))
        #expect(!variable.isEmpty)

        let varied = YogaGuidancePlanner.plan(
            context: context,
            sessionSeed: 77,
            stepIndex: 0,
            excludedClipIDs: variable
        )
        let repeated = Set(varied.cues.filter(\.clip.isVariableFiller).map(\.clip.id))
            .intersection(variable)
        #expect(repeated.isEmpty)
    }

    @Test func generatedAudioManifestCannotClaimApprovalWithoutCompleteAssets() {
        let manifest = YogaAudioLibrary.manifest
        #expect(manifest?.contentVersion == YogaGuidanceCatalog.contentVersion)
        if YogaAudioLibrary.isApproved {
            let expectedIDs = expectedTranscriptIDs()
            for instructor in YogaInstructor.allCases {
                let actual = Set((manifest?.clips ?? [])
                    .filter { $0.instructor == instructor }
                    .map(\.id))
                #expect(actual == expectedIDs, "approved \(instructor.rawValue) audio is incomplete")
            }
        } else {
            #expect(manifest?.status != "approved")
        }
    }

    @Test func generatedAudioManifestIndexesWhenPreviewApprovalIsApplied() throws {
        let source = try #require(Bundle.main.url(
            forResource: "yoga_audio_manifest",
            withExtension: "json"
        ))
        let data = try Data(contentsOf: source)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["status"] = "approved"
        object["listeningApproval"] = "Automated playback-index regression test"
        let approvedData = try JSONSerialization.data(withJSONObject: object)
        let manifest = try JSONDecoder().decode(YogaAudioManifest.self, from: approvedData)

        #expect(YogaAudioLibrary.validatesForPlayback(manifest))
    }

    private func expectedTranscriptIDs() -> Set<String> {
        var ids = Set<String>()
        for pose in YogaPoseCatalog.load() {
            let sides: [YogaFlowPlan.Side?] = pose.unilateral ? [.left, .right] : [nil]
            for side in sides {
                let context = YogaGuidancePlanningContext(
                    poseSlug: pose.slug,
                    poseName: pose.name,
                    side: side,
                    holdSeconds: pose.defaultHoldSeconds,
                    style: .hatha
                )
                let guidance = YogaGuidanceCatalog.guidance(forSlug: pose.slug)
                ids.formUnion(YogaGuidancePlanner.poseClips(context: context, guidance: guidance).map(\.id))
            }
        }
        if let global = YogaGuidanceCatalog.global {
            let counts: [(YogaGuidanceKind, Int)] = [
                (.opening, global.openings.count),
                (.breath, global.breath.count),
                (.awareness, global.awareness.count),
                (.encouragement, global.encouragement.count),
                (.spiritual, global.spiritual.count),
                (.closing, global.closings.count),
            ]
            for (kind, count) in counts {
                ids.formUnion((0..<count).map { "global.\(kind.rawValue).\($0)" })
            }
        }
        return ids
    }

    private func measuredManifestDurations() throws -> [String: TimeInterval] {
        let url = try #require(Bundle.main.url(
            forResource: "yoga_audio_manifest",
            withExtension: "json"
        ))
        let manifest = try JSONDecoder().decode(YogaAudioManifest.self, from: Data(contentsOf: url))
        return Dictionary(grouping: manifest.clips, by: \YogaAudioManifest.Clip.id)
            .mapValues { clips in clips.map(\.durationSeconds).max() ?? 0 }
    }

    private func expectCompleteCriticalGuidance(_ plan: YogaGuidancePlan, label: String) {
        let kinds = plan.cues.map(\.clip.kind)
        #expect(kinds.first == .poseName, "\(label): pose name")
        #expect(
            plan.cues.contains { $0.clip.id.contains(".entry.0.") },
            "\(label): canonical self-contained entry"
        )
        #expect(kinds.last == .exit, "\(label): exit")
        for pair in zip(plan.cues, plan.cues.dropFirst()) {
            #expect(
                pair.1.offset >= pair.0.offset + pair.0.estimatedDuration,
                "\(label): overlapping clips"
            )
        }
    }
}
