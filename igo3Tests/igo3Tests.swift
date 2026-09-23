import Foundation
import SpriteKit
import Testing
@testable import igo3

@MainActor
struct GameFlowTests {
    private func makeStore() -> UserDefaults {
        let suiteName = "igo3Tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    @Test func `Each retry settles independently`() {
        let store = makeStore()
        let model = GameAppModel(store: store, saveKey: "progress")
        let initialCoins = model.progress.coins

        model.start(level: 1)
        let firstSession = model.session!
        firstSession.score = 1_000
        _ = firstSession.finalize(victory: false, level: 1)
        let firstSettlement = model.settleCurrentBattle()

        model.start(level: 1)
        let secondSession = model.session!
        secondSession.score = 800
        _ = secondSession.finalize(victory: false, level: 1)
        let secondSettlement = model.settleCurrentBattle()

        #expect(firstSettlement != nil)
        #expect(secondSettlement != nil)
        #expect(firstSession.id != secondSession.id)
        #expect(model.progress.coins == initialCoins + 25 + 20)
    }

    @Test func `Retry replaces and pauses the finished scene`() {
        let model = GameAppModel(store: makeStore(), saveKey: "progress")
        model.start(level: 1)
        let finishedScene = model.activeScene!
        let finishedSession = model.session!
        _ = finishedSession.finalize(victory: false, level: 1)
        _ = model.settleCurrentBattle()

        model.start(level: 1)

        #expect(finishedScene.isPaused)
        #expect(model.activeScene !== finishedScene)
        #expect(model.session?.id != finishedSession.id)
        #expect(model.session?.state == .playing)
    }

    @Test func `Next level replaces the finished battle`() {
        let model = GameAppModel(store: makeStore(), saveKey: "progress")
        model.start(level: 1)
        let finishedSession = model.session!
        _ = finishedSession.finalize(victory: true, level: 1)
        _ = model.settleCurrentBattle()

        model.startNextLevel()

        #expect(model.selectedLevel == 2)
        #expect(model.session?.id != finishedSession.id)
        #expect(model.session?.state == .playing)
        #expect(model.activeScene != nil)
    }

    @Test func `A battle cannot award twice`() {
        let model = GameAppModel(store: makeStore(), saveKey: "progress")
        model.start(level: 1)
        let session = model.session!
        session.score = 4_000
        _ = session.finalize(victory: true, level: 1)

        let first = model.settleCurrentBattle()
        let coinsAfterFirst = model.progress.coins
        let second = model.settleCurrentBattle()

        #expect(first != nil)
        #expect(second == nil)
        #expect(model.progress.coins == coinsAfterFirst)
    }

    @Test func `Boss contact never requests boss removal`() {
        let level = LevelDefinition.all[0]
        let session = GameSession()
        let scene = GameScene(
            size: CGSize(width: 390, height: 844),
            level: level,
            ship: .nova,
            upgradeLevel: 1,
            session: session
        )
        let boss = scene.testingSpawnBoss()
        let regularEnemy = SKNode()

        #expect(!scene.testingShouldRemoveEnemyOnPlayerContact(boss))
        #expect(scene.testingShouldRemoveEnemyOnPlayerContact(regularEnemy))
    }

    @Test func `Battle state is immutable after ending`() {
        let session = GameSession()
        session.health = 4
        let scene = GameScene(
            size: CGSize(width: 390, height: 844),
            level: LevelDefinition.all[0],
            ship: .nova,
            upgradeLevel: 1,
            session: session
        )

        scene.testingEndBattle(victory: false)
        let outcome = session.outcome
        scene.testingApplyPlayerHit()

        #expect(session.health == 4)
        #expect(session.outcome == outcome)
        #expect(session.state == .defeat)
    }

    @Test func `A discontinuous drag does not teleport the player`() {
        let session = GameSession()
        let scene = GameScene(
            size: CGSize(width: 390, height: 844),
            level: LevelDefinition.all[0],
            ship: .nova,
            upgradeLevel: 1,
            session: session
        )
        let viewSize = CGSize(width: 390, height: 844)

        scene.movePlayer(
            relativeViewTranslation: .zero,
            viewSize: viewSize,
            sensitivity: 1,
            fingerOffset: 80
        )
        scene.movePlayer(
            relativeViewTranslation: CGSize(width: 12, height: 8),
            viewSize: viewSize,
            sensitivity: 1,
            fingerOffset: 80
        )
        let positionBeforeFingerChange = scene.testingPlayerPosition
        scene.movePlayer(
            relativeViewTranslation: CGSize(width: 280, height: -250),
            viewSize: viewSize,
            sensitivity: 1,
            fingerOffset: 80
        )

        #expect(scene.testingPlayerPosition == positionBeforeFingerChange)
    }

    @Test func `Special activation remains available to gestures`() {
        let session = GameSession()
        let scene = GameScene(
            size: CGSize(width: 390, height: 844),
            level: LevelDefinition.all[0],
            ship: .nova,
            upgradeLevel: 1,
            session: session
        )
        session.energy = Double(ShipID.nova.specialDamageRequirement)

        scene.activateSpecial()

        #expect(session.energy == 0)
    }

    @Test func `Shared projectile clearing removes every enemy shot`() {
        let session = GameSession()
        let scene = GameScene(
            size: CGSize(width: 390, height: 844),
            level: LevelDefinition.all[0],
            ship: .nova,
            upgradeLevel: 1,
            session: session
        )

        scene.testingAddEnemyProjectile()
        scene.testingAddEnemyProjectile()
        #expect(scene.testingEnemyProjectileCount == 2)

        scene.testingClearEnemyProjectiles()
        #expect(scene.testingEnemyProjectileCount == 0)
    }

    @Test func `Version one save migrates without losing progress`() throws {
        let source = GameProgress(
            version: 1,
            coins: 2_345,
            highestUnlockedLevel: 4,
            unlockedShips: [.nova, .tempest],
            selectedShip: .tempest,
            upgrades: [.nova: 3, .tempest: 2],
            highScores: [1: 9_000],
            musicEnabled: false,
            soundEnabled: true,
            hapticsEnabled: false
        )
        let currentData = try JSONEncoder().encode(source)
        var legacy = try #require(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacy.removeValue(forKey: "bestStars")
        legacy.removeValue(forKey: "clearedLevels")
        legacy.removeValue(forKey: "controlSensitivity")
        legacy.removeValue(forKey: "fingerOffset")
        legacy["version"] = 1
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(GameProgress.self, from: data)

        #expect(decoded.version == GameProgress.currentVersion)
        #expect(decoded.coins == 2_345)
        #expect(decoded.highestUnlockedLevel == 4)
        #expect(decoded.selectedShip == .tempest)
        #expect(decoded.bestStars.isEmpty)
        #expect(decoded.controlSensitivity == 1)
    }
}
