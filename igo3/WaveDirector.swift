import Foundation
import CoreGraphics

enum EnemyArchetype: CaseIterable, Equatable {
    case rammer
    case strafer
    case turret
}

struct WaveSpawn: Equatable {
    let time: TimeInterval
    let archetype: EnemyArchetype
    let normalizedX: CGFloat
}

struct WaveCue: Equatable {
    let time: TimeInterval
    let message: String
}

@MainActor
final class WaveDirector {
    private let spawns: [WaveSpawn]
    private let cues: [WaveCue]
    private var nextSpawnIndex = 0
    private var nextCueIndex = 0

    init(level: LevelDefinition) {
        var generated: [WaveSpawn] = []
        let duration = level.duration

        // 暖身：交替衝撞機。
        for index in 0..<6 {
            generated.append(.init(
                time: 2 + Double(index) * 1.4,
                archetype: .rammer,
                normalizedX: index.isMultiple(of: 2) ? 0.25 : 0.75
            ))
        }

        // 交錯隊形：橫移射擊機。
        for index in 0..<8 {
            generated.append(.init(
                time: duration * 0.28 + Double(index) * 1.05,
                archetype: .strafer,
                normalizedX: CGFloat((index % 4) + 1) / 5
            ))
        }

        // 混合敵群：三種敵機交替。
        for index in 0..<12 {
            generated.append(.init(
                time: duration * 0.56 + Double(index) * max(0.55, level.enemyRate * 0.72),
                archetype: EnemyArchetype.allCases[index % EnemyArchetype.allCases.count],
                normalizedX: CGFloat((index * 37) % 80 + 10) / 100
            ))
        }

        spawns = generated.sorted { $0.time < $1.time }
        cues = [
            .init(time: 0.8, message: "WAVE 1・敵軍接近"),
            .init(time: duration * 0.26, message: "WAVE 2・交錯編隊"),
            .init(time: duration * 0.54, message: "FINAL WAVE・混合敵群"),
            .init(time: max(1, duration - 5), message: "補給抵達・旗艦即將出現"),
            .init(time: max(1, duration - 2), message: "WARNING・BOSS 接近")
        ]
    }

    func drainSpawns(upTo elapsed: TimeInterval) -> [WaveSpawn] {
        var due: [WaveSpawn] = []
        while nextSpawnIndex < spawns.count, spawns[nextSpawnIndex].time <= elapsed {
            due.append(spawns[nextSpawnIndex])
            nextSpawnIndex += 1
        }
        return due
    }

    func drainCues(upTo elapsed: TimeInterval) -> [WaveCue] {
        var due: [WaveCue] = []
        while nextCueIndex < cues.count, cues[nextCueIndex].time <= elapsed {
            due.append(cues[nextCueIndex])
            nextCueIndex += 1
        }
        return due
    }
}
