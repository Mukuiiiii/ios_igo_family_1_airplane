import Foundation
import SwiftUI

enum AppScreen: Equatable {
    case menu
    case hangar
    case levels
    case game
    case settings
}

enum ShipID: String, Codable, CaseIterable, Identifiable {
    case nova
    case tempest
    case aegis

    var id: String { rawValue }

    var name: LocalizedStringResource {
        switch self {
        case .nova: "新星戰機"
        case .tempest: "暴風戰機"
        case .aegis: "神盾戰機"
        }
    }

    var subtitle: LocalizedStringResource {
        switch self {
        case .nova: "均衡型・集中雙連發"
        case .tempest: "高速型・廣角扇形炮"
        case .aegis: "重裝型・貫穿雷射"
        }
    }

    var color: Color {
        switch self {
        case .nova: .cyan
        case .tempest: .orange
        case .aegis: .mint
        }
    }

    var baseHealth: Int {
        switch self {
        case .nova: 5
        case .tempest: 4
        case .aegis: 7
        }
    }

    var unlockCost: Int {
        switch self {
        case .nova: 0
        case .tempest: 600
        case .aegis: 1_000
        }
    }
}

struct WeaponConfiguration: Equatable {
    let fireInterval: TimeInterval
    let baseDamage: Int
    let projectileSpeed: CGFloat
    let baseProjectileCount: Int
    let spreadAngle: CGFloat
    let isPiercing: Bool

    static func configuration(for ship: ShipID, power: Int, upgrade: Int) -> WeaponConfiguration {
        switch ship {
        case .nova:
            WeaponConfiguration(
                fireInterval: 0.17,
                baseDamage: 2 + upgrade,
                projectileSpeed: 930,
                baseProjectileCount: 2,
                spreadAngle: 0,
                isPiercing: false
            )
        case .tempest:
            WeaponConfiguration(
                fireInterval: 0.14,
                baseDamage: 1 + upgrade,
                projectileSpeed: 840,
                baseProjectileCount: power == 1 ? 3 : (power == 2 ? 5 : 7),
                spreadAngle: .pi / 18,
                isPiercing: false
            )
        case .aegis:
            WeaponConfiguration(
                fireInterval: 0.28,
                baseDamage: 3 + upgrade,
                projectileSpeed: 760,
                baseProjectileCount: power,
                spreadAngle: 0,
                isPiercing: true
            )
        }
    }
}

struct LevelDefinition: Identifiable, Equatable {
    let id: Int
    let title: LocalizedStringResource
    let sector: LocalizedStringResource
    let accent: Color
    let duration: TimeInterval
    let enemyRate: TimeInterval
    let bossHealth: Int
    let threeStarScore: Int
    let maxHitsForThreeStars: Int

    static let all: [LevelDefinition] = [
        .init(id: 1, title: "星海啟程", sector: "蔚藍星域", accent: .cyan, duration: 42, enemyRate: 1.20, bossHealth: 4_000, threeStarScore: 8_000, maxHitsForThreeStars: 2),
        .init(id: 2, title: "赤色警戒", sector: "緋紅星雲", accent: .red, duration: 48, enemyRate: 1.05, bossHealth: 4_500, threeStarScore: 11_000, maxHitsForThreeStars: 2),
        .init(id: 3, title: "雷霆邊界", sector: "紫電禁區", accent: .purple, duration: 54, enemyRate: 0.92, bossHealth: 5_000, threeStarScore: 14_000, maxHitsForThreeStars: 3),
        .init(id: 4, title: "虛空裂隙", sector: "翡翠深空", accent: .green, duration: 60, enemyRate: 0.80, bossHealth: 5_, threeStarScore: 18_000, maxHitsForThreeStars: 3),
        .init(id: 5, title: "終焉要塞", sector: "黃金核心", accent: .yellow, duration: 66, enemyRate: 0.68, bossHealth: 6_000, threeStarScore: 23_000, maxHitsForThreeStars: 4)
    ]

    func stars(victory: Bool, score: Int, hitsTaken: Int) -> Int {
        guard victory else { return 0 }
        var value = 1
        if hitsTaken <= maxHitsForThreeStars { value += 1 }
        if score >= threeStarScore { value += 1 }
        return value
    }
}

struct GameProgress: Codable, Equatable {
    static let currentVersion = 2

    var version: Int
    var coins: Int
    var highestUnlockedLevel: Int
    var unlockedShips: Set<ShipID>
    var selectedShip: ShipID
    var upgrades: [ShipID: Int]
    var highScores: [Int: Int]
    var bestStars: [Int: Int]
    var clearedLevels: Set<Int>
    var musicEnabled: Bool
    var soundEnabled: Bool
    var hapticsEnabled: Bool
    var controlSensitivity: Double
    var fingerOffset: Double

    init(
        version: Int = currentVersion,
        coins: Int = 350,
        highestUnlockedLevel: Int = 1,
        unlockedShips: Set<ShipID> = [.nova],
        selectedShip: ShipID = .nova,
        upgrades: [ShipID: Int] = [.nova: 1, .tempest: 1, .aegis: 1],
        highScores: [Int: Int] = [:],
        bestStars: [Int: Int] = [:],
        clearedLevels: Set<Int> = [],
        musicEnabled: Bool = true,
        soundEnabled: Bool = true,
        hapticsEnabled: Bool = true,
        controlSensitivity: Double = 1,
        fingerOffset: Double = 70
    ) {
        self.version = version
        self.coins = coins
        self.highestUnlockedLevel = highestUnlockedLevel
        self.unlockedShips = unlockedShips
        self.selectedShip = selectedShip
        self.upgrades = upgrades
        self.highScores = highScores
        self.bestStars = bestStars
        self.clearedLevels = clearedLevels
        self.musicEnabled = musicEnabled
        self.soundEnabled = soundEnabled
        self.hapticsEnabled = hapticsEnabled
        self.controlSensitivity = controlSensitivity
        self.fingerOffset = fingerOffset
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        coins = try values.decodeIfPresent(Int.self, forKey: .coins) ?? 350
        highestUnlockedLevel = try values.decodeIfPresent(Int.self, forKey: .highestUnlockedLevel) ?? 1
        unlockedShips = try values.decodeIfPresent(Set<ShipID>.self, forKey: .unlockedShips) ?? [.nova]
        selectedShip = try values.decodeIfPresent(ShipID.self, forKey: .selectedShip) ?? .nova
        upgrades = try values.decodeIfPresent([ShipID: Int].self, forKey: .upgrades) ?? [.nova: 1, .tempest: 1, .aegis: 1]
        highScores = try values.decodeIfPresent([Int: Int].self, forKey: .highScores) ?? [:]
        bestStars = try values.decodeIfPresent([Int: Int].self, forKey: .bestStars) ?? [:]
        clearedLevels = try values.decodeIfPresent(Set<Int>.self, forKey: .clearedLevels) ?? []
        musicEnabled = try values.decodeIfPresent(Bool.self, forKey: .musicEnabled) ?? true
        soundEnabled = try values.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        hapticsEnabled = try values.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        controlSensitivity = try values.decodeIfPresent(Double.self, forKey: .controlSensitivity) ?? 1
        fingerOffset = try values.decodeIfPresent(Double.self, forKey: .fingerOffset) ?? 70
        version = Self.currentVersion
    }
}

enum BattleState: Equatable {
    case playing
    case paused
    case victory
    case defeat
}

struct BattleOutcome: Equatable {
    let victory: Bool
    let score: Int
    let hitsTaken: Int
    let level: Int
}

struct BattleSettlement: Equatable {
    let outcome: BattleOutcome
    let stars: Int
    let earnedCoins: Int
    let isFirstClear: Bool
    let isPersonalBest: Bool
}

@MainActor
@Observable
final class GameSession {
    let id = UUID()
    var score = 0
    var health = 5
    var maxHealth = 5
    var power = 1
    var energy = 0.0
    var shieldCharges = 0
    var hitsTaken = 0
    var bossHealth = 0
    var bossMaxHealth = 0
    var bossVisible = false
    var bossPhase = 1
    var bossInvulnerable = false
    var elapsed = 0.0
    var state: BattleState = .playing
    var waveMessage: LocalizedStringResource?
    private(set) var outcome: BattleOutcome?
    private(set) var settlement: BattleSettlement?
    private var outcomeClaimed = false

    @discardableResult
    func finalize(victory: Bool, level: Int) -> BattleOutcome {
        if let outcome { return outcome }
        let snapshot = BattleOutcome(victory: victory, score: score, hitsTaken: hitsTaken, level: level)
        outcome = snapshot
        state = victory ? .victory : .defeat
        return snapshot
    }

    func claimOutcome() -> BattleOutcome? {
        guard !outcomeClaimed, let outcome else { return nil }
        outcomeClaimed = true
        return outcome
    }

    func applySettlement(_ settlement: BattleSettlement) {
        guard self.settlement == nil else { return }
        self.settlement = settlement
    }
}
