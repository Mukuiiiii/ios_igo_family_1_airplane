import AVFAudio
import Foundation

enum GameSoundEffect: Hashable {
    case playerNovaShot
    case playerTempestShot
    case playerAegisShot
    case enemyShot
    case bossBasic(level: Int)
    case bossSpecial(level: Int, alternate: Bool)
    case novaSkill
    case tempestSkill
    case aegisSkill
    case shieldBlock
    case playerHit
    case pickup
    case interfaceTap
    case victory

    var assetName: String {
        switch self {
        case .playerNovaShot: "player_nova_shot"
        case .playerTempestShot: "player_tempest_shot"
        case .playerAegisShot: "player_aegis_shot"
        case .enemyShot: "enemy_shot"
        case .bossBasic(let level): "boss_basic_\(level)"
        case .bossSpecial(let level, let alternate):
            alternate ? "boss_alternate_\(level)" : "boss_special_\(level)"
        case .novaSkill: "skill_nova"
        case .tempestSkill: "skill_tempest"
        case .aegisSkill: "skill_aegis"
        case .shieldBlock: "shield_block"
        case .playerHit: "player_hit"
        case .pickup: "pickup"
        case .interfaceTap: "interface_tap"
        case .victory: "victory"
        }
    }
}

@MainActor
final class GameAudioManager {
    private enum EffectCategory {
        case interface
        case combat
    }

    private let engine = AVAudioEngine()
    private let musicPlayer = AVAudioPlayerNode()
    private let shieldPlayer = AVAudioPlayerNode()
    private var effectPlayers: [AVAudioPlayerNode] = []
    private var nextEffectPlayer = 0
    private var effectBuffers: [GameSoundEffect: AVAudioPCMBuffer] = [:]
    private let sampleRate = 22_050.0
    private let format: AVAudioFormat

    private var interfaceVolume: Float = 0.8
    private var combatVolume: Float = 0.8
    private var backgroundVolume: Float = 0.65
    private var currentMusic: (level: Int, boss: Bool)?
    private var isPaused = false
    private var engineStarted = false

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        engine.attach(musicPlayer)
        engine.attach(shieldPlayer)
        engine.connect(musicPlayer, to: engine.mainMixerNode, format: format)
        engine.connect(shieldPlayer, to: engine.mainMixerNode, format: format)

        for _ in 0..<10 {
            let player = AVAudioPlayerNode()
            effectPlayers.append(player)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    func updateVolumes(interface: Double, combat: Double, background: Double) {
        interfaceVolume = Float(interface.clamped(to: 0...1))
        combatVolume = Float(combat.clamped(to: 0...1))
        backgroundVolume = Float(background.clamped(to: 0...1))
        musicPlayer.volume = backgroundVolume
        shieldPlayer.volume = combatVolume * 0.55

        if backgroundVolume == 0 {
            musicPlayer.pause()
        } else if currentMusic != nil, !isPaused, !musicPlayer.isPlaying {
            startEngineIfNeeded()
            musicPlayer.play()
        }
    }

    func playLevelMusic(level: Int) {
        playMusic(level: level, boss: false)
    }

    func playBossMusic(level: Int) {
        playMusic(level: level, boss: true)
    }

    func stopMusic() {
        musicPlayer.stop()
        currentMusic = nil
    }

    func pause() {
        isPaused = true
        musicPlayer.pause()
        shieldPlayer.pause()
    }

    func resume() {
        isPaused = false
        startEngineIfNeeded()
        if currentMusic != nil, !musicPlayer.isPlaying {
            musicPlayer.play()
        }
        if shieldPlayer.lastRenderTime != nil, !shieldPlayer.isPlaying {
            shieldPlayer.play()
        }
    }

    func play(_ effect: GameSoundEffect) {
        let category = category(for: effect)
        let volume = category == .interface ? interfaceVolume : combatVolume
        guard volume > 0 else { return }
        startEngineIfNeeded()

        let buffer = effectBuffers[effect]
            ?? loadAudioBuffer(named: effect.assetName)
            ?? makeEffectBuffer(effect)
        effectBuffers[effect] = buffer
        let player = availableEffectPlayer()
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !isPaused {
            player.play()
        }
    }

    func startShieldLoop() {
        guard combatVolume > 0 else { return }
        startEngineIfNeeded()
        shieldPlayer.stop()
        shieldPlayer.volume = combatVolume * 0.55
        let buffer = loadAudioBuffer(named: "shield_loop") ?? makeShieldLoop()
        shieldPlayer.scheduleBuffer(buffer, at: nil, options: .loops)
        if !isPaused {
            shieldPlayer.play()
        }
    }

    func stopShieldLoop() {
        shieldPlayer.stop()
    }

    func stopAll() {
        stopMusic()
        stopShieldLoop()
        effectPlayers.forEach { $0.stop() }
    }

    private func playMusic(level: Int, boss: Bool) {
        let track = (level: level, boss: boss)
        guard currentMusic?.level != track.level || currentMusic?.boss != track.boss else { return }
        currentMusic = track
        startEngineIfNeeded()
        musicPlayer.stop()
        musicPlayer.volume = backgroundVolume
        let assetName = boss ? "boss_\(level)" : "level_\(level)"
        let buffer = loadAudioBuffer(named: assetName) ?? makeMusicBuffer(level: level, boss: boss)
        musicPlayer.scheduleBuffer(buffer, at: nil, options: .loops)
        if !isPaused, backgroundVolume > 0 {
            musicPlayer.play()
        }
    }

    private func startEngineIfNeeded() {
        guard !engineStarted else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
        engine.prepare()
        do {
            try engine.start()
            engineStarted = true
        } catch {
            engineStarted = false
        }
    }

    private func availableEffectPlayer() -> AVAudioPlayerNode {
        if let idle = effectPlayers.first(where: { !$0.isPlaying }) {
            return idle
        }
        let player = effectPlayers[nextEffectPlayer]
        nextEffectPlayer = (nextEffectPlayer + 1) % effectPlayers.count
        player.stop()
        return player
    }

    private func category(for effect: GameSoundEffect) -> EffectCategory {
        switch effect {
        case .interfaceTap, .victory:
            .interface
        default:
            .combat
        }
    }

    private func loadAudioBuffer(named name: String) -> AVAudioPCMBuffer? {
        let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Audio")
            ?? Bundle.main.url(forResource: name, withExtension: "wav")
        guard let url,
              let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(file.length)
              ) else {
            return nil
        }

        do {
            try file.read(into: buffer)
            return buffer
        } catch {
            return nil
        }
    }

    private func makeMusicBuffer(level: Int, boss: Bool) -> AVAudioPCMBuffer {
        let duration = 8.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let roots = [48, 50, 53, 46, 55]
        let scales = [
            [0, 3, 7, 10, 7, 3, 12, 10],
            [0, 5, 7, 8, 12, 8, 7, 5],
            [0, 2, 5, 9, 12, 9, 5, 2],
            [0, 3, 6, 9, 11, 9, 6, 3],
            [0, 4, 7, 11, 14, 11, 7, 4]
        ]
        let safeLevel = min(5, max(1, level))
        let root = roots[safeLevel - 1] + (boss ? -5 : 0)
        let melody = scales[safeLevel - 1]
        let stepDuration = boss ? 0.25 : 0.5
        let twoPi = Double.pi * 2
        let channels = buffer.floatChannelData!

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
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
            let pad = (
                sin(twoPi * leadFrequency / 2 * time)
                + sin(twoPi * leadFrequency * 0.75 * time)
            ) * 0.035
            let beatTime = time.truncatingRemainder(dividingBy: boss ? 0.5 : 1.0)
            let kickEnvelope = exp(-beatTime * 18)
            let kick = sin(twoPi * (55 + 65 * kickEnvelope) * beatTime) * kickEnvelope * (boss ? 0.2 : 0.12)
            let shimmer = sin(Double(frame * (safeLevel * 17 + 31))) * exp(-localTime * 28) * 0.025
            let sample = Float(max(-0.9, min(0.9, lead + bass + pad + kick + shimmer)))

            channels[0][frame] = sample
            channels[1][frame] = sample * Float(0.92 + 0.08 * sin(twoPi * 0.125 * time))
        }
        return buffer
    }

    private func makeEffectBuffer(_ effect: GameSoundEffect) -> AVAudioPCMBuffer {
        let profile = effectProfile(effect)
        let frameCount = AVAudioFrameCount(sampleRate * profile.duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        let twoPi = Double.pi * 2

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let progress = time / profile.duration
            let frequency = profile.startFrequency + (profile.endFrequency - profile.startFrequency) * progress
            let envelope = sin(Double.pi * min(1, progress)) * exp(-progress * profile.decay)
            let phase = (time * frequency).truncatingRemainder(dividingBy: 1)
            let tone: Double
            switch profile.waveform {
            case 0:
                tone = sin(twoPi * frequency * time)
            case 1:
                tone = phase * 2 - 1
            default:
                tone = phase < 0.5 ? 1 : -1
            }
            let noise = sin(Double(frame * 73 + profile.seed * 19)) * profile.noise
            let sample = Float(max(-0.95, min(0.95, (tone * (1 - profile.noise) + noise) * envelope * profile.gain)))
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        return buffer
    }

    private func makeShieldLoop() -> AVAudioPCMBuffer {
        let duration = 1.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        let twoPi = Double.pi * 2

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / sampleRate
            let pulse = 0.65 + 0.35 * sin(twoPi * 2 * time)
            let sample = Float(
                (sin(twoPi * 110 * time) * 0.09
                 + sin(twoPi * 220 * time) * 0.045
                 + sin(twoPi * 660 * time) * 0.018) * pulse
            )
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        return buffer
    }

    private func effectProfile(_ effect: GameSoundEffect) -> (
        startFrequency: Double,
        endFrequency: Double,
        duration: Double,
        decay: Double,
        noise: Double,
        gain: Double,
        waveform: Int,
        seed: Int
    ) {
        switch effect {
        case .playerNovaShot: (920, 520, 0.09, 2.8, 0.03, 0.38, 0, 1)
        case .playerTempestShot: (680, 330, 0.075, 3.2, 0.12, 0.30, 1, 2)
        case .playerAegisShot: (1_150, 740, 0.14, 2.2, 0.01, 0.34, 2, 3)
        case .enemyShot: (260, 150, 0.12, 2.4, 0.16, 0.32, 1, 4)
        case .bossBasic(let level): (310 + Double(level * 35), 105, 0.2, 1.8, 0.12, 0.42, 2, level + 10)
        case .bossSpecial(let level, let alternate):
            (alternate ? 980 : 180, alternate ? 120 : 1_050, 0.55, 1.1, 0.18, 0.48, alternate ? 1 : 2, level + 20)
        case .novaSkill: (130, 1_400, 0.7, 0.8, 0.12, 0.55, 0, 31)
        case .tempestSkill: (420, 1_080, 0.45, 1.1, 0.08, 0.5, 1, 32)
        case .aegisSkill: (160, 720, 0.65, 0.7, 0.02, 0.48, 0, 33)
        case .shieldBlock: (1_250, 380, 0.24, 2.1, 0.08, 0.45, 0, 34)
        case .playerHit: (180, 65, 0.32, 1.5, 0.38, 0.48, 1, 35)
        case .pickup: (520, 1_150, 0.28, 0.8, 0, 0.38, 0, 36)
        case .interfaceTap: (760, 620, 0.055, 3.5, 0, 0.24, 0, 37)
        case .victory: (440, 1_320, 1.25, 0.35, 0, 0.48, 0, 38)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
