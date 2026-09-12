import Foundation
import PeekabooCore
import Tachikoma
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct ScreenshotConversationQueueTests {
    @Test
    func submissionsReuseOneSessionAndBindCaptureIDsToUserMessages() throws {
        let fixture = self.makeFixture { _, _, _, _ in
            ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
        }
        defer { fixture.cleanup() }

        let first = try fixture.service.submitScreenshot(imageData: Data([1]), reusing: nil)
        let second = try fixture.service.submitScreenshot(imageData: Data([2]), reusing: first.sessionID)

        #expect(first.isNewSession)
        #expect(!second.isNewSession)
        #expect(second.sessionID == first.sessionID)
        #expect(fixture.sessionStore.sessions.count == 1)
        #expect(fixture.service.captures(sessionID: first.sessionID).map(\.captureID) == [
            first.captureID,
            second.captureID,
        ])
        #expect(fixture.sessionStore.session(id: first.sessionID)?.messages.map(\.id) == [
            first.captureID,
            second.captureID,
        ])
    }

    @Test
    func invalidReusableSessionFallsBackToANewScreenshotSession() throws {
        let fixture = self.makeFixture { _, _, _, _ in
            ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
        }
        defer { fixture.cleanup() }

        let submission = try fixture.service.submitScreenshot(
            imageData: Data([1]),
            reusing: "missing-session")

        #expect(submission.isNewSession)
        #expect(submission.sessionID != "missing-session")
        #expect(fixture.sessionStore.session(id: submission.sessionID)?.kind == .screenshot)
    }

    @Test
    func submissionPersistenceFailureRollsBackSessionAndImageContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-submit-rollback-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blockedParent)
        let sessionStore = SessionStore(storageURL: blockedParent.appendingPathComponent("sessions.json"))
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            },
            captureAnalyzer: { _, _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            })

        #expect(throws: (any Error).self) {
            try service.submitScreenshot(imageData: Data([9]), reusing: nil)
        }
        #expect(sessionStore.sessions.isEmpty)
        #expect(try contextStore.cleanupContexts(keeping: []).isEmpty)
    }

    @Test
    func queuedCapturesAreAnalyzedInSubmissionOrder() async throws {
        var analyzedImages: [Data] = []
        let fixture = self.makeFixture { imageData, _, _, _ in
            analyzedImages.append(imageData)
            return ScreenshotConversationAnalysis(
                provider: "openai",
                model: "gpt-5.5",
                text: "answer-\(analyzedImages.count)")
        }
        defer { fixture.cleanup() }

        let first = try fixture.service.submitScreenshot(imageData: Data([1]), reusing: nil)
        let second = try fixture.service.submitScreenshot(imageData: Data([2]), reusing: first.sessionID)
        let third = try fixture.service.submitScreenshot(imageData: Data([3]), reusing: first.sessionID)
        fixture.service.enqueueAnalysis(first)
        fixture.service.enqueueAnalysis(second)
        fixture.service.enqueueAnalysis(third)

        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).map(\.analysisState) == [.ready, .ready, .ready]
        })
        #expect(analyzedImages == [Data([1]), Data([2]), Data([3])])
        #expect(fixture.sessionStore.session(id: first.sessionID)?.messages.map(\.role) == [
            .user,
            .assistant,
            .user,
            .assistant,
            .user,
            .assistant,
        ])
    }

    @Test
    func eachCaptureBindsItsOwnPromptAndUsesOnlyEarlierTurnsAsHistory() async throws {
        var requests: [(history: [PeekabooAIService.ConversationTurn], prompt: String)] = []
        let fixture = self.makeFixture { _, history, currentPrompt, _ in
            requests.append((history, currentPrompt))
            return ScreenshotConversationAnalysis(
                provider: "openai",
                model: "gpt-5.5",
                text: "answer-\(requests.count)")
        }
        defer { fixture.cleanup() }

        let first = try fixture.service.submitScreenshot(
            imageData: Data([1]),
            reusing: nil,
            prompt: "first image")
        let second = try fixture.service.submitScreenshot(
            imageData: Data([2]),
            reusing: first.sessionID,
            prompt: "second image")
        fixture.service.enqueueAnalysis(first)
        fixture.service.enqueueAnalysis(second)

        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).map(\.analysisState) == [.ready, .ready]
        })
        #expect(requests.map(\.prompt) == ["first image", "second image"])
        #expect(requests[0].history.isEmpty)
        #expect(requests[1].history == [
            .init(role: .user, text: "first image"),
            .init(role: .assistant, text: "answer-1"),
        ])
    }

    @Test
    func failedCapturePausesTheQueueAndSkippingItExcludesItsPromptFromLaterHistory() async throws {
        var requestCount = 0
        var laterHistory: [PeekabooAIService.ConversationTurn] = []
        let fixture = self.makeFixture { _, history, _, _ in
            requestCount += 1
            if requestCount == 1 {
                throw QueueFailure.provider
            }
            laterHistory = history
            return ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "second")
        }
        defer { fixture.cleanup() }

        let first = try fixture.service.submitScreenshot(imageData: Data([1]), reusing: nil)
        let second = try fixture.service.submitScreenshot(imageData: Data([2]), reusing: first.sessionID)
        fixture.service.enqueueAnalysis(first)
        fixture.service.enqueueAnalysis(second)

        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).first?.analysisState == .failed
        })
        #expect(requestCount == 1)
        #expect(fixture.service.captures(sessionID: first.sessionID).last?.analysisState == .pending)

        fixture.service.skipFailedCapture(sessionID: first.sessionID, captureID: first.captureID)

        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).last?.analysisState == .ready
        })
        #expect(requestCount == 2)
        #expect(laterHistory.isEmpty)
    }

    @Test
    func screenshotSubmittedAfterFailureCannotPassTheFailedQueueHead() async throws {
        var requestCount = 0
        let fixture = self.makeFixture { _, _, _, _ in
            requestCount += 1
            if requestCount == 1 {
                throw QueueFailure.provider
            }
            return ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "done")
        }
        defer { fixture.cleanup() }

        let first = try fixture.service.submitScreenshot(imageData: Data([1]), reusing: nil)
        fixture.service.enqueueAnalysis(first)
        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).first?.analysisState == .failed
        })

        let second = try fixture.service.submitScreenshot(imageData: Data([2]), reusing: first.sessionID)
        fixture.service.enqueueAnalysis(second)
        for _ in 0..<50 {
            await Task.yield()
        }

        #expect(requestCount == 1)
        #expect(fixture.service.status(for: first.sessionID) == .failed("AI 分析失败，请重试"))
        #expect(fixture.service.captures(sessionID: first.sessionID).map(\.analysisState) == [.failed, .pending])

        fixture.service.skipFailedCapture(sessionID: first.sessionID, captureID: first.captureID)
        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).last?.analysisState == .ready
        })
        #expect(requestCount == 2)
    }

    @Test
    func retryingTheFailedCaptureKeepsFIFOAndUsesOneAssistantID() async throws {
        var requestCount = 0
        var analyzedImages: [Data] = []
        let fixture = self.makeFixture { imageData, _, _, _ in
            requestCount += 1
            analyzedImages.append(imageData)
            if requestCount == 1 {
                throw QueueFailure.provider
            }
            return ScreenshotConversationAnalysis(
                provider: "openai",
                model: "gpt-5.5",
                text: "answer-\(requestCount)")
        }
        defer { fixture.cleanup() }

        let first = try fixture.service.submitScreenshot(imageData: Data([1]), reusing: nil)
        let second = try fixture.service.submitScreenshot(imageData: Data([2]), reusing: first.sessionID)
        let assistantID = try #require(fixture.contextStore
            .context(for: UUID(uuidString: first.sessionID)!)?
            .captures.first?.assistantMessageID)
        fixture.service.enqueueAnalysis(first)
        fixture.service.enqueueAnalysis(second)
        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).first?.analysisState == .failed
        })

        fixture.service.retryCapture(sessionID: first.sessionID, captureID: first.captureID)

        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).map(\.analysisState) == [.ready, .ready]
        })
        #expect(analyzedImages == [Data([1]), Data([1]), Data([2])])
        #expect(fixture.sessionStore.session(id: first.sessionID)?.messages
            .filter { $0.id == assistantID }.count == 1)
    }

    @Test
    func genericRetryOfPausedQueueRemovesCompletedHeadAndContinuesDraining() async throws {
        var requestCount = 0
        let fixture = self.makeFixture { _, _, _, _ in
            requestCount += 1
            if requestCount == 1 {
                throw QueueFailure.provider
            }
            return ScreenshotConversationAnalysis(
                provider: "openai",
                model: "gpt-5.5",
                text: "answer-\(requestCount)")
        }
        defer { fixture.cleanup() }

        let first = try fixture.service.submitScreenshot(imageData: Data([1]), reusing: nil)
        let second = try fixture.service.submitScreenshot(imageData: Data([2]), reusing: first.sessionID)
        fixture.service.enqueueAnalysis(first)
        fixture.service.enqueueAnalysis(second)
        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).first?.analysisState == .failed
        })
        for _ in 0..<50 {
            await Task.yield()
        }

        try await fixture.service.retryAnalysis(sessionID: first.sessionID)

        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: first.sessionID).map(\.analysisState) == [.ready, .ready]
        })
        #expect(requestCount == 3)
    }

    @Test
    func imageReadErrorTurnsPendingQueueHeadIntoRecoverableFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-image-read-error-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contextRoot = root.appendingPathComponent("context-root", isDirectory: true)
        let contextStore = ScreenshotConversationContextStore(rootDirectory: contextRoot)
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            })
        let submission = try service.submitScreenshot(imageData: Data([1]), reusing: nil)
        let sessionUUID = try #require(UUID(uuidString: submission.sessionID))
        let capture = try #require(contextStore.context(for: sessionUUID)?.captures.first)
        let imageURL = contextRoot
            .appendingPathComponent("images", isDirectory: true)
            .appendingPathComponent(capture.imageFileName)
        try FileManager.default.removeItem(at: imageURL)
        try FileManager.default.createDirectory(at: imageURL, withIntermediateDirectories: true)

        service.enqueueAnalysis(submission)

        #expect(await self.waitUntil {
            service.captures(sessionID: submission.sessionID).first?.analysisState == .failed
        })
        #expect(service.status(for: submission.sessionID) == .failed("原截图已丢失，请重新截图"))
    }

    @Test
    func textFollowUpIsRejectedWhileCaptureQueueIsBusy() async throws {
        let analyses = SuspendedCaptureAnalysis()
        let fixture = self.makeFixture { _, _, _, _ in
            await analyses.wait()
        }
        defer { fixture.cleanup() }
        let submission = try fixture.service.submitScreenshot(imageData: Data([1]), reusing: nil)
        fixture.service.enqueueAnalysis(submission)
        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: submission.sessionID).first?.analysisState == .analyzing
        })

        await #expect(throws: ScreenshotConversationServiceError.requestAlreadyInProgress) {
            try await fixture.service.sendFollowUp("must wait", sessionID: submission.sessionID)
        }
        analyses.finish(ScreenshotConversationAnalysis(
            provider: "openai",
            model: "gpt-5.5",
            text: "done"))
        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: submission.sessionID).first?.analysisState == .ready
        })
    }

    @Test
    func analyzeDoesNotDuplicateAnAlreadyCompletedCaptureAnswer() async throws {
        var requestCount = 0
        let fixture = self.makeFixture { _, _, _, _ in
            requestCount += 1
            return ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "done")
        }
        defer { fixture.cleanup() }
        let submission = try fixture.service.submitScreenshot(imageData: Data([1]), reusing: nil)
        fixture.service.enqueueAnalysis(submission)
        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: submission.sessionID).first?.analysisState == .ready
        })

        try await fixture.service.analyze(sessionID: submission.sessionID)

        #expect(requestCount == 1)
        #expect(fixture.sessionStore.session(id: submission.sessionID)?.messages.map(\.role) == [
            .user,
            .assistant,
        ])
    }

    @Test
    func startupReconcileUsesTheFixedAssistantIDAsCommitBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-reconcile-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let captureID = UUID()
        let assistantID = UUID()
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        sessionStore.sessions = [ConversationSession(
            id: sessionID.uuidString.lowercased(),
            title: "截图分析",
            messages: [
                ConversationMessage(id: captureID, role: .user, content: "analyze"),
                ConversationMessage(id: assistantID, role: .assistant, content: "committed answer"),
            ],
            kind: .screenshot)]
        try sessionStore.persistSessionsNow()
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        _ = try contextStore.save(
            imageData: Data([1]),
            for: sessionID,
            captureID: captureID,
            assistantMessageID: assistantID)
        _ = try contextStore.updateAnalysisState(.analyzing, for: captureID, in: sessionID)

        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            })

        #expect(service.captures(sessionID: sessionID.uuidString.lowercased()).map(\.analysisState) == [.ready])
        #expect(sessionStore.session(id: sessionID.uuidString.lowercased())?.messages.count == 2)
    }

    @Test
    func startupMigratesV1ImageToTheExistingPromptAndAdjacentAnswer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-v1-service-migration-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let promptID = UUID()
        let assistantID = UUID()
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        sessionStore.sessions = [ConversationSession(
            id: sessionID.uuidString.lowercased(),
            title: "截图分析",
            messages: [
                ConversationMessage(id: promptID, role: .user, content: "legacy prompt"),
                ConversationMessage(id: assistantID, role: .assistant, content: "legacy answer"),
            ],
            kind: .screenshot)]
        try sessionStore.persistSessionsNow()
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        _ = try contextStore.save(imageData: Data([1]), for: sessionID)

        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            })

        let migrated = try #require(contextStore.context(for: sessionID))
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.captures == [ScreenshotCapture(
            id: promptID,
            imageFileName: migrated.imageFileName,
            createdAt: migrated.createdAt,
            analysisState: .ready,
            assistantMessageID: assistantID,
        )])
        #expect(service.captures(sessionID: sessionID.uuidString.lowercased()).map(\.analysisState) == [.ready])
    }

    @Test
    func restartWithFailedCaptureBlocksTextInsteadOfMisroutingItAsCaptureRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-restart-failed-capture-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let captureID = UUID()
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        sessionStore.sessions = [ConversationSession(
            id: sessionID.uuidString.lowercased(),
            title: "截图分析",
            messages: [ConversationMessage(id: captureID, role: .user, content: "unfinished screenshot")],
            kind: .screenshot)]
        try sessionStore.persistSessionsNow()
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        _ = try contextStore.save(
            imageData: Data([1]),
            for: sessionID,
            captureID: captureID,
            assistantMessageID: UUID())

        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unexpected")
            })

        #expect(service.isBusy(sessionID: sessionID.uuidString.lowercased()))
        await #expect(throws: ScreenshotConversationServiceError.requestAlreadyInProgress) {
            try await service.sendFollowUp("new text", sessionID: sessionID.uuidString.lowercased())
        }
        #expect(sessionStore.session(id: sessionID.uuidString.lowercased())?.messages.map(\.content) == [
            "unfinished screenshot",
        ])
    }

    @Test
    func restartCannotRetryALaterCaptureBeforeItsEarlierFailedBarrier() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-restart-capture-order-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let firstCaptureID = UUID()
        let secondCaptureID = UUID()
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        sessionStore.sessions = [ConversationSession(
            id: sessionID.uuidString.lowercased(),
            title: "截图分析",
            messages: [
                ConversationMessage(id: firstCaptureID, role: .user, content: "first"),
                ConversationMessage(id: secondCaptureID, role: .user, content: "second"),
            ],
            kind: .screenshot)]
        try sessionStore.persistSessionsNow()
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        _ = try contextStore.save(
            imageData: Data([1]),
            for: sessionID,
            captureID: firstCaptureID,
            assistantMessageID: UUID())
        _ = try contextStore.append(
            imageData: Data([2]),
            captureID: secondCaptureID,
            assistantMessageID: UUID(),
            to: sessionID)
        var analyzedImages: [Data] = []
        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "unused")
            },
            captureAnalyzer: { imageData, _, _, _ in
                analyzedImages.append(imageData)
                return ScreenshotConversationAnalysis(
                    provider: "openai",
                    model: "gpt-5.5",
                    text: "answer-\(analyzedImages.count)")
            })

        #expect(service.captures(sessionID: sessionID.uuidString.lowercased()).map(\.analysisState) == [
            .failed,
            .failed,
        ])
        service.retryCapture(sessionID: sessionID.uuidString.lowercased(), captureID: secondCaptureID)
        for _ in 0..<50 {
            await Task.yield()
        }
        #expect(analyzedImages.isEmpty)

        service.retryCapture(sessionID: sessionID.uuidString.lowercased(), captureID: firstCaptureID)
        #expect(await self.waitUntil {
            service.captures(sessionID: sessionID.uuidString.lowercased()).first?.analysisState == .ready
        })
        service.retryCapture(sessionID: sessionID.uuidString.lowercased(), captureID: secondCaptureID)
        #expect(await self.waitUntil {
            service.captures(sessionID: sessionID.uuidString.lowercased()).map(\.analysisState) == [.ready, .ready]
        })
        #expect(analyzedImages == [Data([1]), Data([2])])
    }

    @Test
    func screenshotWaitsForTextAnswerAndPreservesPromptAnswerOrdering() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-text-capture-serialization-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let textAnalysis = SuspendedCaptureAnalysis()
        var captureRequestCount = 0
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: ScreenshotConversationContextStore(
                rootDirectory: root.appendingPathComponent("contexts", isDirectory: true)),
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in await textAnalysis.wait() },
            captureAnalyzer: { _, _, _, _ in
                captureRequestCount += 1
                return ScreenshotConversationAnalysis(
                    provider: "openai",
                    model: "gpt-5.5",
                    text: "capture-answer-\(captureRequestCount)")
            })
        let first = try service.submitScreenshot(imageData: Data([1]), reusing: nil)
        service.enqueueAnalysis(first)
        #expect(await self.waitUntil {
            service.captures(sessionID: first.sessionID).first?.analysisState == .ready
        })

        let followUp = Task {
            try await service.sendFollowUp("text-question", sessionID: first.sessionID)
        }
        #expect(await self.waitUntil { service.status(for: first.sessionID) == .analyzing })
        let second = try service.submitScreenshot(imageData: Data([2]), reusing: first.sessionID)
        service.enqueueAnalysis(second)
        await Task.yield()
        #expect(captureRequestCount == 1)

        textAnalysis.finish(ScreenshotConversationAnalysis(
            provider: "openai",
            model: "gpt-5.5",
            text: "text-answer"))
        try await followUp.value
        #expect(await self.waitUntil {
            service.captures(sessionID: first.sessionID).map(\.analysisState) == [.ready, .ready]
        })
        #expect(sessionStore.session(id: first.sessionID)?.messages.map(\.content) == [
            ScreenshotConversationService.defaultPrompt,
            "capture-answer-1",
            "text-question",
            "text-answer",
            ScreenshotConversationService.defaultPrompt,
            "capture-answer-2",
        ])
    }

    @Test
    func failedTextTurnPausesNewScreenshotUntilExactTextRetrySucceeds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-text-failure-barrier-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suspendedText = SuspendedThrowingAnalysis()
        var textRequestCount = 0
        var captureRequestCount = 0
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: ScreenshotConversationContextStore(
                rootDirectory: root.appendingPathComponent("contexts", isDirectory: true)),
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                textRequestCount += 1
                if textRequestCount == 1 {
                    return try await suspendedText.wait()
                }
                return ScreenshotConversationAnalysis(
                    provider: "openai",
                    model: "gpt-5.5",
                    text: "text-retry-answer")
            },
            captureAnalyzer: { _, _, _, _ in
                captureRequestCount += 1
                return ScreenshotConversationAnalysis(
                    provider: "openai",
                    model: "gpt-5.5",
                    text: "capture-answer-\(captureRequestCount)")
            })
        let first = try service.submitScreenshot(imageData: Data([1]), reusing: nil)
        service.enqueueAnalysis(first)
        #expect(await self.waitUntil {
            service.captures(sessionID: first.sessionID).first?.analysisState == .ready
        })

        let followUp = Task {
            try await service.sendFollowUp("text-that-fails", sessionID: first.sessionID)
        }
        #expect(await self.waitUntil { service.status(for: first.sessionID) == .analyzing })
        let second = try service.submitScreenshot(imageData: Data([2]), reusing: first.sessionID)
        service.enqueueAnalysis(second)
        suspendedText.finish(.failure(QueueFailure.provider))
        await #expect(throws: QueueFailure.provider) {
            try await followUp.value
        }
        for _ in 0..<50 {
            await Task.yield()
        }
        #expect(captureRequestCount == 1)
        #expect(service.captures(sessionID: first.sessionID).last?.analysisState == .pending)
        #expect(service.status(for: first.sessionID) == .failed("AI 分析失败，请重试"))

        try await service.retryAnalysis(sessionID: first.sessionID)

        #expect(await self.waitUntil {
            service.captures(sessionID: first.sessionID).map(\.analysisState) == [.ready, .ready]
        })
        #expect(textRequestCount == 2)
        #expect(captureRequestCount == 2)
        #expect(sessionStore.session(id: first.sessionID)?.messages.map(\.content) == [
            ScreenshotConversationService.defaultPrompt,
            "capture-answer-1",
            "text-that-fails",
            "text-retry-answer",
            ScreenshotConversationService.defaultPrompt,
            "capture-answer-2",
        ])
    }

    @Test
    func textPersistenceFailureRetriesWithTheSameAssistantID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-text-persistence-retry-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("sessions.json")
        var textRequestCount = 0
        let sessionStore = SessionStore(storageURL: storageURL)
        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: ScreenshotConversationContextStore(
                rootDirectory: root.appendingPathComponent("contexts", isDirectory: true)),
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                textRequestCount += 1
                return ScreenshotConversationAnalysis(
                    provider: "openai",
                    model: "gpt-5.5",
                    text: textRequestCount == 1 ? "uncommitted" : "committed")
            },
            captureAnalyzer: { _, _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "first")
            })
        let submission = try service.submitScreenshot(imageData: Data([1]), reusing: nil)
        service.enqueueAnalysis(submission)
        #expect(await self.waitUntil {
            service.captures(sessionID: submission.sessionID).first?.analysisState == .ready
        })
        try FileManager.default.removeItem(at: storageURL)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            try await service.sendFollowUp("persist me", sessionID: submission.sessionID)
        }
        #expect(service.status(for: submission.sessionID) == .failed(
            "无法保存 AI 回答，请检查磁盘空间后重试"))
        let failedAssistantID = try #require(sessionStore.session(id: submission.sessionID)?.messages
            .first(where: { $0.content == "uncommitted" })?.id)
        try FileManager.default.removeItem(at: storageURL)

        try await service.retryAnalysis(sessionID: submission.sessionID)

        let messages = try #require(sessionStore.session(id: submission.sessionID)?.messages)
        #expect(messages.filter { $0.id == failedAssistantID }.map(\.content) == ["committed"])
        #expect(messages.filter { $0.role == .assistant }.map(\.content) == ["first", "committed"])
    }

    @Test
    func deletingSessionDuringNoncooperativeCaptureDoesNotRestoreStatusOrContext() async throws {
        let analyses = SuspendedCaptureAnalysis()
        let fixture = self.makeFixture { _, _, _, _ in
            await analyses.wait()
        }
        defer { fixture.cleanup() }
        let submission = try fixture.service.submitScreenshot(imageData: Data([1]), reusing: nil)
        fixture.service.enqueueAnalysis(submission)
        #expect(await self.waitUntil {
            fixture.service.captures(sessionID: submission.sessionID).first?.analysisState == .analyzing
        })

        try fixture.service.deleteSession(sessionID: submission.sessionID)
        analyses.finish(ScreenshotConversationAnalysis(
            provider: "openai",
            model: "gpt-5.5",
            text: "late"))
        for _ in 0..<50 {
            await Task.yield()
        }

        #expect(fixture.sessionStore.session(id: submission.sessionID) == nil)
        #expect(fixture.service.status(for: submission.sessionID) == .idle)
        #expect(fixture.service.captures(sessionID: submission.sessionID).isEmpty)
    }

    private func makeFixture(
        captureAnalyzer: @escaping ScreenshotConversationService.CaptureAnalyzer) -> Fixture
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-queue-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionStore = SessionStore(storageURL: root.appendingPathComponent("sessions.json"))
        let contextStore = ScreenshotConversationContextStore(
            rootDirectory: root.appendingPathComponent("contexts", isDirectory: true))
        let service = ScreenshotConversationService(
            sessionStore: sessionStore,
            contextStore: contextStore,
            modelResolver: { _ in .openai(.gpt55) },
            analyzer: { _, _, _ in
                ScreenshotConversationAnalysis(provider: "openai", model: "gpt-5.5", text: "ordinary")
            },
            captureAnalyzer: captureAnalyzer)
        return Fixture(
            root: root,
            sessionStore: sessionStore,
            contextStore: contextStore,
            service: service)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    private enum QueueFailure: Error, Equatable {
        case provider
    }

    @MainActor
    private final class SuspendedCaptureAnalysis {
        private var continuation: CheckedContinuation<ScreenshotConversationAnalysis, Never>?
        private var bufferedResult: ScreenshotConversationAnalysis?

        func wait() async -> ScreenshotConversationAnalysis {
            if let bufferedResult = self.bufferedResult {
                self.bufferedResult = nil
                return bufferedResult
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish(_ result: ScreenshotConversationAnalysis) {
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(returning: result)
            } else {
                self.bufferedResult = result
            }
        }
    }

    @MainActor
    private final class SuspendedThrowingAnalysis {
        private var continuation: CheckedContinuation<Result<ScreenshotConversationAnalysis, any Error>, Never>?
        private var bufferedResult: Result<ScreenshotConversationAnalysis, any Error>?

        func wait() async throws -> ScreenshotConversationAnalysis {
            if let bufferedResult = self.bufferedResult {
                self.bufferedResult = nil
                return try bufferedResult.get()
            }
            let result = await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
            return try result.get()
        }

        func finish(_ result: Result<ScreenshotConversationAnalysis, any Error>) {
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(returning: result)
            } else {
                self.bufferedResult = result
            }
        }
    }

    private struct Fixture {
        let root: URL
        let sessionStore: SessionStore
        let contextStore: ScreenshotConversationContextStore
        let service: ScreenshotConversationService

        func cleanup() {
            try? FileManager.default.removeItem(at: self.root)
        }
    }
}
