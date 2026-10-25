import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class AppStateIdleSessionRemovalTests: XCTestCase {
    private func session(_ status: AgentStatus, parent: String? = nil) -> SessionSnapshot {
        var value = SessionSnapshot()
        value.status = status
        value.parentSessionId = parent
        return value
    }

    func testRemovalKeepsNonIdleCardsAndDrainsCompletionCard() {
        let app = AppState()
        app.sessions = [
            "idle": session(.idle),
            "running": session(.running),
            "thinking": session(.processing),
            "approval": session(.waitingApproval),
        ]
        app.surface = .completionCard(sessionId: "idle")

        app.removeIdleSessions()

        XCTAssertNil(app.sessions["idle"])
        XCTAssertEqual(Set(app.sessions.keys), ["running", "thinking", "approval"])
        XCTAssertNotEqual(app.surface, .completionCard(sessionId: "idle"))
        XCTAssertNotNil(app.manuallyRemovedSessions["idle"])
    }

    func testParentAndChildAreRemovedAtomically() {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.idle, parent: "parent")]

        let selection = app.idleSessionRemovalSelection
        XCTAssertEqual(selection.groups, [Set(["parent", "child"])])
        app.removeIdleSessions(selection: selection)

        XCTAssertTrue(app.sessions.isEmpty)
    }

    func testActiveChildRetainsWholeGroup() {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.running, parent: "parent")]

        XCTAssertTrue(app.idleSessionRemovalSelection.isEmpty)
        app.removeIdleSessions()

        XCTAssertEqual(Set(app.sessions.keys), ["parent", "child"])
    }

    func testPendingRequestOnChildRetainsWholeGroup() async throws {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.idle, parent: "parent")]
        let raw: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "child",
            "tool_name": "Bash", "tool_input": ["command": "echo test"],
        ]
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: raw)))
        let response = await startHookRequest { app.handlePermissionRequest(event, continuation: $0) }
        app.sessions["child"]?.status = .idle

        XCTAssertTrue(app.idleSessionRemovalSelection.isEmpty)
        app.denyPermission(expectedSessionId: "child")
        _ = try await awaitValue(of: response)
    }

    func testEmbeddedLiveSubagentRetainsParent() {
        let app = AppState()
        var parent = session(.idle)
        var child = SubagentState(agentId: "worker", agentType: "test")
        child.status = .running
        parent.subagents["worker"] = child
        app.sessions = ["parent": parent]

        XCTAssertTrue(app.idleSessionRemovalSelection.isEmpty)
    }

    func testChecklistInProgressDoesNotPretendTheAgentIsRunning() {
        let app = AppState()
        var idle = session(.idle)
        idle.agentTasks.apply(.replace(opId: "old", items: [
            AgentTaskDraft(title: "Stale checklist item", status: .inProgress),
        ]), now: Date())
        app.sessions = ["idle": idle]

        XCTAssertEqual(app.idleSessionRemovalSelection.sessionIDs, ["idle"])
    }

    func testNewChildDuringConfirmationRetainsOriginalGroup() {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.idle, parent: "parent")]
        let selected = app.idleSessionRemovalSelection
        app.sessions["late-child"] = session(.idle, parent: "parent")

        app.removeIdleSessions(selection: selected)

        XCTAssertEqual(Set(app.sessions.keys), ["parent", "child", "late-child"])
    }

    func testStatusChangeDuringConfirmationRetainsWholeGroupAndNewlyIdleGroupIsNotAdded() {
        let app = AppState()
        app.sessions = [
            "parent": session(.idle),
            "child": session(.idle, parent: "parent"),
            "other": session(.running),
        ]
        let selected = app.idleSessionRemovalSelection
        app.sessions["child"]?.status = .running
        app.sessions["other"]?.status = .idle

        app.removeIdleSessions(selection: selected)

        XCTAssertEqual(Set(app.sessions.keys), ["parent", "child", "other"])
    }

    func testParentCycleIsCycleSafeAndAtomic() {
        let app = AppState()
        app.sessions = ["a": session(.idle, parent: "b"), "b": session(.idle, parent: "a")]

        XCTAssertEqual(app.idleSessionRemovalSelection.groups, [Set(["a", "b"])])
    }

    func testPassiveInputsStaySuppressedUntilRealActivity() throws {
        let app = AppState()
        app.sessions = ["removed": session(.idle)]
        app.removeIdleSessions()

        var rediscovered = DiscoveredSession(
            sessionId: "removed", cwd: "/nonexistent", tty: nil, model: nil, pid: nil,
            modifiedAt: Date().addingTimeInterval(60), recentMessages: []
        )
        rediscovered.status = .idle
        app.integrateDiscovered([rediscovered])
        let stop = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "session_id": "removed",
        ])))
        app.handleEvent(stop)

        XCTAssertNil(app.sessions["removed"])
        XCTAssertNotNil(app.manuallyRemovedSessions["removed"])

        rediscovered.status = .processing
        app.integrateDiscovered([rediscovered])
        XCTAssertNotNil(app.sessions["removed"])
        XCTAssertNil(app.manuallyRemovedSessions["removed"])
    }

    func testNewPromptRevivesRemovedSession() throws {
        let app = AppState()
        app.sessions = ["removed": session(.idle)]
        app.removeIdleSessions()
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "removed", "prompt": "new task",
        ])))

        app.handleEvent(event)

        XCTAssertEqual(app.sessions["removed"]?.status, .processing)
        XCTAssertNil(app.manuallyRemovedSessions["removed"])
    }

    func testActivityFromOneRemovedGroupMemberReleasesTheWholeGroup() throws {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.idle, parent: "parent")]
        app.removeIdleSessions()
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "child", "prompt": "continue",
        ])))

        app.handleEvent(event)

        XCTAssertNil(app.manuallyRemovedSessions["parent"])
        XCTAssertNil(app.manuallyRemovedSessions["child"])
    }

    func testPassiveAiWorkHydrateDoesNotReviveButActiveStreamDoes() {
        let app = AppState()
        let key = AppState.aiworkSessionPrefix + "acp:coder:removed"
        app.sessions = [key: session(.idle)]
        app.removeIdleSessions()

        app.applyAiWorkHydrate(
            key: key,
            daemonSessionId: "acp:coder:removed",
            entry: ["status": .string("idle")]
        )
        XCTAssertNil(app.sessions[key])

        let frame = AiWorkWatchClient.parseFrame(Data(#"""
        {"kind":"event","event":{"name":"stream.started"},"data":{"session":{"session_id":"acp:coder:removed"}},"meta":{"session_id":"acp:coder:removed"}}
        """#.utf8))!
        app.handleAiWorkStreamEvent(name: "stream.started", frame: frame, agentId: "coder")

        XCTAssertNotNil(app.sessions[key])
        XCTAssertNil(app.manuallyRemovedSessions[key])
    }
}
