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
        case .nova: "均衡型・雙重脈衝炮"
        case .tempest: "高速型・廣角散射炮"
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

struct LevelDefinition: Identifiable, Equatable {
    let id: Int
    let title: LocalizedStringResource
    let sector: LocalizedStringResource
    let accent: Color
    let duration: TimeInterval
    let enemyRate: TimeInterval
    let bossHealth: Int

    static let all: [LevelDefinition] = [
        .init(id: 1, title: "星海啟程", sector: "蔚藍星域", accent: .cyan, duration: 42, enemyRate: 1.20, bossHealth: 70),
        .init(id: 2, title: "赤色警戒", sector: "緋紅星雲", accent: .red, duration: 48, enemyRate: 1.05, bossHealth: 95),
        .init(id: 3, title: "雷霆邊界", sector: "紫電禁區", accent: .purple, duration: 54, enemyRate: 0.92, bossHealth: 125),
        .init(id: 4, title: "虛空裂隙", sector: "翡翠深空", accent: .green, duration: 60, enemyRate: 0.80, bossHealth: 160),
        .init(id: 5, title: "終焉要塞", sector: "黃金核心", accent: .yellow, duration: 66, enemyRate: 0.68, bossHealth: 210)
    ]
}

struct GameProgress: Codable, Equatable {
    var version = 1
    var coins = 350
    var highestUnlockedLevel = 1
    var unlockedShips: Set<ShipID> = [.nova]
    var selectedShip: ShipID = .nova
    var upgrades: [ShipID: Int] = [.nova: 1, .tempest: 1, .aegis: 1]
    var highScores: [Int: Int] = [:]
    var musicEnabled = true
    var soundEnabled = true
    var hapticsEnabled = true
}

enum BattleState: Equatable {
    case playing
    case paused
    case victory
    case defeat
}

@MainActor
@Observable
final class GameSession {
    var score = 0
    var health = 5
    var maxHealth = 5
    var power = 1
    var energy = 0.0
    var bossHealth = 0
    var bossMaxHealth = 0
    var bossVisible = false
    var elapsed = 0.0
    var state: BattleState = .playing
    var earnedCoins = 0
}
