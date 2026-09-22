import Foundation

let sampleRate = 22_050
let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("igo3/Audio", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

struct EffectProfile {
    let name: String
    let startFrequency: Double
    let endFrequency: Double
    let duration: Double
    let decay: Double
    let noise: Double
    let gain: Double
    let waveform: Int
    let seed: Int
}

func writeWAV(name: String, samples: [(Float, Float)]) throws {
    var data = Data()
    let channels: UInt16 = 2
    let bitsPerSample: UInt16 = 16
    let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
    let blockAlign = channels * bitsPerSample / 8
    let payloadSize = UInt32(samples.count) * UInt32(blockAlign)

    func appendASCII(_ value: String) {
        data.append(value.data(using: .ascii)!)
    }
    func append<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    appendASCII("RIFF")
    append(UInt32(36) + payloadSize)
    appendASCII("WAVEfmt ")
    append(UInt32(16))
    append(UInt16(1))
    append(channels)
    append(UInt32(sampleRate))
    append(byteRate)
    append(blockAlign)
    append(bitsPerSample)
    appendASCII("data")
    append(payloadSize)

    for (left, right) in samples {
        append(Int16(max(-1, min(1, left)) * Float(Int16.max)))
        append(Int16(max(-1, min(1, right)) * Float(Int16.max)))
    }
    try data.write(to: outputDirectory.appendingPathComponent("\(name).wav"), options: .atomic)
}

func music(level: Int, boss: Bool) -> [(Float, Float)] {
    let duration = 8.0
    let frameCount = Int(Double(sampleRate) * duration)
    let roots = [48, 50, 53, 46, 55]
    let scales = [
        [0, 3, 7, 10, 7, 3, 12, 10],
        [0, 5, 7, 8, 12, 8, 7, 5],
        [0, 2, 5, 9, 12, 9, 5, 2],
        [0, 3, 6, 9, 11, 9, 6, 3],
        [0, 4, 7, 11, 14, 11, 7, 4]
    ]
    let root = roots[level - 1] + (boss ? -5 : 0)
    let melody = scales[level - 1]
    let stepDuration = boss ? 0.25 : 0.5
    let twoPi = Double.pi * 2

    return (0..<frameCount).map { frame in
        let time = Double(frame) / Double(sampleRate)
        let step = Int(time / stepDuration)
        let localTime = time.truncatingRemainder(dividingBy: stepDuration)
        let envelope = min(1, localTime / 0.018, (stepDuration - localTime) / 0.045)
        let note = root + melody[step % melody.count] + (boss && step.isMultiple(of: 3) ? 12 : 0)
        let leadFrequency = 440 * pow(2, Double(note - 69) / 12)
        let bassNote = root - 12 + melody[(step / 2) % 4]
        let bassFrequency = 440 * pow(2, Double(bassNote - 69) / 12)
        let leadPhase = (time * leadFrequency).truncatingRemainder(dividingBy: 1)
        let lead = boss
            ? (leadPhase * 2 - 1) * envelope * 0.13
            : sin(twoPi * leadFrequency * time) * envelope * 0.15
        let bass = sin(twoPi * bassFrequency * time) * 0.12
        let pad = (sin(twoPi * leadFrequency / 2 * time) + sin(twoPi * leadFrequency * 0.75 * time)) * 0.035
        let beatTime = time.truncatingRemainder(dividingBy: boss ? 0.5 : 1.0)
        let kickEnvelope = exp(-beatTime * 18)
        let kick = sin(twoPi * (55 + 65 * kickEnvelope) * beatTime) * kickEnvelope * (boss ? 0.2 : 0.12)
        let shimmer = sin(Double(frame * (level * 17 + 31))) * exp(-localTime * 28) * 0.025
        let sample = Float(max(-0.9, min(0.9, lead + bass + pad + kick + shimmer)))
        return (sample, sample * Float(0.92 + 0.08 * sin(twoPi * 0.125 * time)))
    }
}

func effect(_ profile: EffectProfile) -> [(Float, Float)] {
    let frameCount = Int(Double(sampleRate) * profile.duration)
    let twoPi = Double.pi * 2
    return (0..<frameCount).map { frame in
        let time = Double(frame) / Double(sampleRate)
        let progress = time / profile.duration
        let frequency = profile.startFrequency + (profile.endFrequency - profile.startFrequency) * progress
        let envelope = sin(Double.pi * min(1, progress)) * exp(-progress * profile.decay)
        let phase = (time * frequency).truncatingRemainder(dividingBy: 1)
        let tone: Double
        switch profile.waveform {
        case 0: tone = sin(twoPi * frequency * time)
        case 1: tone = phase * 2 - 1
        default: tone = phase < 0.5 ? 1 : -1
        }
        let noise = sin(Double(frame * 73 + profile.seed * 19)) * profile.noise
        let sample = Float(max(-0.95, min(0.95, (tone * (1 - profile.noise) + noise) * envelope * profile.gain)))
        return (sample, sample)
    }
}

func shieldLoop() -> [(Float, Float)] {
    let frameCount = sampleRate
    let twoPi = Double.pi * 2
    return (0..<frameCount).map { frame in
        let time = Double(frame) / Double(sampleRate)
        let pulse = 0.65 + 0.35 * sin(twoPi * 2 * time)
        let sample = Float((sin(twoPi * 110 * time) * 0.09 + sin(twoPi * 220 * time) * 0.045 + sin(twoPi * 660 * time) * 0.018) * pulse)
        return (sample, sample)
    }
}

for level in 1...5 {
    try writeWAV(name: "level_\(level)", samples: music(level: level, boss: false))
    try writeWAV(name: "boss_\(level)", samples: music(level: level, boss: true))
}

var profiles: [EffectProfile] = [
    .init(name: "player_nova_shot", startFrequency: 920, endFrequency: 520, duration: 0.09, decay: 2.8, noise: 0.03, gain: 0.38, waveform: 0, seed: 1),
    .init(name: "player_tempest_shot", startFrequency: 680, endFrequency: 330, duration: 0.075, decay: 3.2, noise: 0.12, gain: 0.30, waveform: 1, seed: 2),
    .init(name: "player_aegis_shot", startFrequency: 1150, endFrequency: 740, duration: 0.14, decay: 2.2, noise: 0.01, gain: 0.34, waveform: 2, seed: 3),
    .init(name: "enemy_shot", startFrequency: 260, endFrequency: 150, duration: 0.12, decay: 2.4, noise: 0.16, gain: 0.32, waveform: 1, seed: 4),
    .init(name: "skill_nova", startFrequency: 130, endFrequency: 1400, duration: 0.7, decay: 0.8, noise: 0.12, gain: 0.55, waveform: 0, seed: 31),
    .init(name: "skill_tempest", startFrequency: 420, endFrequency: 1080, duration: 0.45, decay: 1.1, noise: 0.08, gain: 0.5, waveform: 1, seed: 32),
    .init(name: "skill_aegis", startFrequency: 160, endFrequency: 720, duration: 0.65, decay: 0.7, noise: 0.02, gain: 0.48, waveform: 0, seed: 33),
    .init(name: "shield_block", startFrequency: 1250, endFrequency: 380, duration: 0.24, decay: 2.1, noise: 0.08, gain: 0.45, waveform: 0, seed: 34),
    .init(name: "player_hit", startFrequency: 180, endFrequency: 65, duration: 0.32, decay: 1.5, noise: 0.38, gain: 0.48, waveform: 1, seed: 35),
    .init(name: "pickup", startFrequency: 520, endFrequency: 1150, duration: 0.28, decay: 0.8, noise: 0, gain: 0.38, waveform: 0, seed: 36),
    .init(name: "interface_tap", startFrequency: 760, endFrequency: 620, duration: 0.055, decay: 3.5, noise: 0, gain: 0.24, waveform: 0, seed: 37),
    .init(name: "victory", startFrequency: 440, endFrequency: 1320, duration: 1.25, decay: 0.35, noise: 0, gain: 0.48, waveform: 0, seed: 38)
]

for level in 1...5 {
    profiles.append(.init(name: "boss_basic_\(level)", startFrequency: 310 + Double(level * 35), endFrequency: 105, duration: 0.2, decay: 1.8, noise: 0.12, gain: 0.42, waveform: 2, seed: level + 10))
    profiles.append(.init(name: "boss_special_\(level)", startFrequency: 180, endFrequency: 1050, duration: 0.55, decay: 1.1, noise: 0.18, gain: 0.48, waveform: 2, seed: level + 20))
    profiles.append(.init(name: "boss_alternate_\(level)", startFrequency: 980, endFrequency: 120, duration: 0.55, decay: 1.1, noise: 0.18, gain: 0.48, waveform: 1, seed: level + 20))
}

for profile in profiles {
    try writeWAV(name: profile.name, samples: effect(profile))
}
try writeWAV(name: "shield_loop", samples: shieldLoop())
print("Generated \(10 + profiles.count + 1) audio assets in \(outputDirectory.path)")
