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
    let audioManager: GameAudioManager

    private let store: UserDefaults
    private let saveKey: String

    init(store: UserDefaults = .standard, saveKey: String = "stellarStrike.progress.v1") {
        self.store = store
        self.saveKey = saveKey
        progress = Self.loadProgress(from: store, key: saveKey)
        audioManager = GameAudioManager()
        audioManager.updateVolumes(
            interface: progress.interfaceVolume,
            combat: progress.combatVolume,
            background: progress.backgroundVolume
        )
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

        if let activeScene {
            activeScene.isPaused = true
            audioManager.stopAll()
        }

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
            session: battle,
            audioManager: audioManager
        )
        scene.scaleMode = .aspectFit
        activeScene = scene
        screen = .game
    }

    @discardableResult
    func settleCurrentBattle() -> BattleSettlement? {
        guard let session, let outcome = session.claimOutcome(),
              let definition = LevelDefinition.all.first(where: { $0.id == outcome.level }) else {
            return nil
        }

        let previousBest = progress.highScores[outcome.level, default: 0]
        let isPersonalBest = outcome.score > previousBest
        let isFirstClear = outcome.victory && !progress.clearedLevels.contains(outcome.level)
        let stars = definition.stars(
            victory: outcome.victory,
            score: outcome.score,
            hitsTaken: outcome.hitsTaken
        )
        let battleReward = outcome.victory ? outcome.level * 120 : max(20, outcome.score / 40)
        let firstClearBonus = isFirstClear ? outcome.level * 200 : 0
        let earnedCoins = battleReward + firstClearBonus
        let settlement = BattleSettlement(
            outcome: outcome,
            stars: stars,
            earnedCoins: earnedCoins,
            isFirstClear: isFirstClear,
            isPersonalBest: isPersonalBest
        )

        progress.coins += earnedCoins
        progress.highScores[outcome.level] = max(previousBest, outcome.score)
        progress.bestStars[outcome.level] = max(progress.bestStars[outcome.level, default: 0], stars)
        if outcome.victory {
            progress.clearedLevels.insert(outcome.level)
            progress.highestUnlockedLevel = min(5, max(progress.highestUnlockedLevel, outcome.level + 1))
        }
        session.applySettlement(settlement)
        save()
        return settlement
    }

    func startNextLevel() {
        let next = min(5, selectedLevel + 1)
        guard next != selectedLevel, next <= progress.highestUnlockedLevel else {
            leaveBattle()
            return
        }
        start(level: next)
    }

    func leaveBattle() {
        activeScene?.isPaused = true
        audioManager.stopAll()
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

    func setInterfaceVolume(_ value: Double) {
        progress.interfaceVolume = value
        applyAudioVolumes()
        save()
    }

    func setCombatVolume(_ value: Double) {
        progress.combatVolume = value
        applyAudioVolumes()
        save()
    }

    func setBackgroundVolume(_ value: Double) {
        progress.backgroundVolume = value
        applyAudioVolumes()
        save()
    }

    func playTouchFeedback() {
        audioManager.play(.interfaceTap)
    }

    private func applyAudioVolumes() {
        audioManager.updateVolumes(
            interface: progress.interfaceVolume,
            combat: progress.combatVolume,
            background: progress.backgroundVolume
        )
    }

    func setControlSensitivity(_ value: Double) {
        progress.controlSensitivity = value
        save()
    }

    func setFingerOffset(_ value: Double) {
        progress.fingerOffset = value
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        store.set(data, forKey: saveKey)
    }

    static func loadProgress(from store: UserDefaults, key: String) -> GameProgress {
        guard let data = store.data(forKey: key) else { return GameProgress() }
        if let decoded = try? JSONDecoder().decode(GameProgress.self, from: data) {
            return decoded
        }

        store.set(data, forKey: key + ".unreadable-backup")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return GameProgress()
        }

        var recovered = GameProgress()
        recovered.coins = object["coins"] as? Int ?? recovered.coins
        recovered.highestUnlockedLevel = object["highestUnlockedLevel"] as? Int ?? recovered.highestUnlockedLevel
        recovered.musicEnabled = object["musicEnabled"] as? Bool ?? recovered.musicEnabled
        recovered.soundEnabled = object["soundEnabled"] as? Bool ?? recovered.soundEnabled
        recovered.hapticsEnabled = object["hapticsEnabled"] as? Bool ?? recovered.hapticsEnabled
        recovered.interfaceVolume = object["interfaceVolume"] as? Double ?? recovered.interfaceVolume
        recovered.combatVolume = object["combatVolume"] as? Double ?? recovered.combatVolume
        recovered.backgroundVolume = object["backgroundVolume"] as? Double ?? recovered.backgroundVolume

        if let rawShip = object["selectedShip"] as? String, let ship = ShipID(rawValue: rawShip) {
            recovered.selectedShip = ship
        }
        if let rawShips = object["unlockedShips"] as? [String] {
            let ships = Set(rawShips.compactMap(ShipID.init(rawValue:)))
            if !ships.isEmpty { recovered.unlockedShips = ships }
        }
        return recovered
    }
}
