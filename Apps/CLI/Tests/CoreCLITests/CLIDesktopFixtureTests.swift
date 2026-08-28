import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.tags(.safe))
struct CLIDesktopFixtureTests {
    @Test
    func `separate fixtures do not share watermarks`() throws {
        let first = try CLIDesktopFixture()
        defer { first.removeDirectory() }
        let second = try CLIDesktopFixture()
        defer { second.removeDirectory() }
        let cutoff = Date()
        let mutation = try first.watermarkStore.beginMutation(at: cutoff)
        try first.watermarkStore.completeMutation(mutation, through: cutoff)

        #expect(first.root != second.root)
        #expect(first.watermarkStore.effectiveWatermark() == cutoff)
        #expect(second.watermarkStore.effectiveWatermark() == nil)
    }

    @Test
    func `separate fixtures allow independent lanes`() async throws {
        let first = try CLIDesktopFixture()
        defer { first.removeDirectory() }
        let second = try CLIDesktopFixture()
        defer { second.removeDirectory() }

        let result = try await first.laneCoordinator.run(scope: .global, access: .write) {
            try await second.laneCoordinator.run(scope: .global, access: .write) { 42 }
        }
        #expect(result == 42)
    }

    @Test
    func `borrowed coordinator retains same root exclusion`() async throws {
        let fixture = try CLIDesktopFixture()
        defer { fixture.removeDirectory() }
        let borrowed = DesktopOperationLaneCoordinator(coordinationRootURL: fixture.root)

        try await fixture.laneCoordinator.run(scope: .global, access: .write) {
            do {
                try await borrowed.run(scope: .global, access: .write) {
                    Issue.record("A second coordinator must not bypass the same-root lane")
                }
                Issue.record("Expected nested same-root acquisition to fail")
            } catch DesktopOperationLaneError.nestedAcquisition {
                // The real lane retains ownership until the outer operation returns.
            }
        }
        let result = try await borrowed.run(scope: .global, access: .write) { 42 }
        #expect(result == 42)
    }
}
