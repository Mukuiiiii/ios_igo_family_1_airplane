import Foundation
import Observation
import SpriteKit

@MainActor
@Observable
final class GameAppModel {
    var screen: AppScreen = .menu
    var progress: GameProgress
    var selectedLevel = 1
    var session: GameSession?
    var activeScene: GameScene?

    private let saveKey = "stellarStrike.progress.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode(GameProgress.self, from: data) {
            progress = decoded
        } else {
            progress = GameProgress()
        }
    }

    var selectedShip: ShipID { progress.selectedShip }

    func selectShip(_ ship: ShipID) {
        guard progress.unlockedShips.contains(ship) else { return }
        progress.selectedShip = ship
        save()
    }

    func unlockShip(_ ship: ShipID) {
        guard !progress.unlockedShips.contains(ship),
              progress.coins >= ship.unlockCost else { return }
        progress.coins -= ship.unlockCost
        progress.unlockedShips.insert(ship)
        progress.selectedShip = ship
        save()
    }

    func upgradeSelectedShip() {
        let ship = progress.selectedShip
        let level = progress.upgrades[ship, default: 1]
        guard level < 5 else { return }
        let cost = upgradeCost(for: level)
        guard progress.coins >= cost else { return }
        progress.coins -= cost
        progress.upgrades[ship] = level + 1
        save()
    }

    func upgradeCost(for level: Int) -> Int {
        180 * level
    }

    func start(level: Int) {
        guard level <= progress.highestUnlockedLevel,
              let definition = LevelDefinition.all.first(where: { $0.id == level }) else { return }

        selectedLevel = level
        let upgrade = progress.upgrades[progress.selectedShip, default: 1]
        let battle = GameSession()
        battle.maxHealth = progress.selectedShip.baseHealth + upgrade - 1
        battle.health = battle.maxHealth
        session = battle

        let scene = GameScene(
            size: CGSize(width: 390, height: 844),
            level: definition,
            ship: progress.selectedShip,
            upgradeLevel: upgrade,
            session: battle
        )
        scene.scaleMode = .aspectFill
        activeScene = scene
        screen = .game
    }

    func finishBattle(victory: Bool) {
        guard let session else { return }
        let baseReward = victory ? selectedLevel * 120 : max(20, session.score / 40)
        session.earnedCoins = baseReward
        progress.coins += baseReward
        progress.highScores[selectedLevel] = max(progress.highScores[selectedLevel, default: 0], session.score)
        if victory {
            progress.highestUnlockedLevel = min(5, max(progress.highestUnlockedLevel, selectedLevel + 1))
        }
        save()
    }

    func leaveBattle() {
        activeScene?.isPaused = true
        activeScene = nil
        session = nil
        screen = .levels
    }

    func setMusic(_ enabled: Bool) {
        progress.musicEnabled = enabled
        save()
    }

    func setSound(_ enabled: Bool) {
        progress.soundEnabled = enabled
        save()
    }

    func setHaptics(_ enabled: Bool) {
        progress.hapticsEnabled = enabled
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }
}
