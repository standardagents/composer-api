import XCTest
@testable import CursorAPI
import CursorAPICore

final class AppModelTests: XCTestCase {
    func testInstallAllTitleUsesUnlockActionWhenSavedKeyIsLocked() {
        let statuses = [
            AgentIntegrationStatus(
                id: .opencode,
                installed: false,
                configPath: nil,
                detail: "Provider points at a hosted API"
            )
        ]

        XCTAssertEqual(
            CursorAPIAppModel.installAllIntegrationsTitle(
                for: statuses,
                isRunning: true,
                needsKeychainPermission: true
            ),
            "Unlock & Update All"
        )
    }

    func testInstallAllTitleUsesStartOnlyWhenServerIsStoppedAndKeyIsUnlocked() {
        let statuses = [
            AgentIntegrationStatus(
                id: .codex,
                installed: false,
                configPath: nil,
                detail: "Ready to install"
            )
        ]

        XCTAssertEqual(
            CursorAPIAppModel.installAllIntegrationsTitle(
                for: statuses,
                isRunning: false,
                needsKeychainPermission: false
            ),
            "Start & Install All"
        )
    }

    func testInstallAllTitleOmitsPrefixWhenServerIsReady() {
        let statuses = [
            AgentIntegrationStatus(
                id: .codex,
                installed: false,
                configPath: nil,
                detail: "Ready to install"
            )
        ]

        XCTAssertEqual(
            CursorAPIAppModel.installAllIntegrationsTitle(
                for: statuses,
                isRunning: true,
                needsKeychainPermission: false
            ),
            "Install All"
        )
    }

    func testIntegrationActionTitleUsesUnlockActionWhenSavedKeyIsLocked() {
        let status = AgentIntegrationStatus(
            id: .opencode,
            installed: false,
            configPath: nil,
            detail: "Provider points at a hosted API"
        )

        XCTAssertEqual(
            CursorAPIAppModel.actionTitle(
                for: status,
                isRunning: true,
                needsKeychainPermission: true
            ),
            "Unlock & Update"
        )
    }

    func testIntegrationActionTitleUsesStartOnlyWhenServerIsStoppedAndKeyIsUnlocked() {
        let status = AgentIntegrationStatus(
            id: .codex,
            installed: false,
            configPath: nil,
            detail: "Ready to install"
        )

        XCTAssertEqual(
            CursorAPIAppModel.actionTitle(
                for: status,
                isRunning: false,
                needsKeychainPermission: false
            ),
            "Start & Install"
        )
    }

    func testIntegrationActionTitlePreservesTerminalStates() {
        let installed = AgentIntegrationStatus(
            id: .codex,
            installed: true,
            configPath: nil,
            detail: "Custom provider installed"
        )
        let unavailable = AgentIntegrationStatus(
            id: .cline,
            installed: false,
            configPath: nil,
            detail: "Extension state not found",
            canInstall: false
        )

        XCTAssertEqual(
            CursorAPIAppModel.actionTitle(
                for: installed,
                isRunning: false,
                needsKeychainPermission: true
            ),
            "Installed"
        )
        XCTAssertEqual(
            CursorAPIAppModel.actionTitle(
                for: unavailable,
                isRunning: false,
                needsKeychainPermission: true
            ),
            "Unavailable"
        )
    }
}
