import SwiftUI
import SpriteKit

struct ContentView: View {
    @State private var model = GameAppModel()

    var body: some View {
        ZStack {
            SpaceBackdrop()

            switch model.screen {
            case .menu:
                MainMenuView(model: model)
            case .hangar:
                HangarView(model: model)
            case .levels:
                LevelSelectView(model: model)
            case .game:
                GameContainerView(model: model)
            case .settings:
                SettingsView(model: model)
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct SpaceBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.01, green: 0.02, blue: 0.10), .black, Color(red: 0.08, green: 0.01, blue: 0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [.cyan.opacity(0.18), .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 420
            )
            StarField()
        }
        .ignoresSafeArea()
    }
}

struct StarField: View {
    private struct Star {
        let id: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
    }

    private let stars: [Star] = (0..<72).map { index in
        Star(
            id: index,
            x: CGFloat((index * 47) % 101) / 100,
            y: CGFloat((index * 83) % 97) / 96,
            size: CGFloat(index % 3 + 1)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                for star in stars {
                    let point = CGPoint(x: star.x * size.width, y: star.y * size.height)
                    context.opacity = 0.25 + Double(star.id % 5) * 0.12
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x, y: point.y, width: star.size, height: star.size)),
                        with: .color(star.id.isMultiple(of: 9) ? .cyan : .white)
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityHidden(true)
    }
}

struct MainMenuView: View {
    let model: GameAppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            GameLogo()
            ShipEmblem(color: model.selectedShip.color)
                .frame(width: 190, height: 190)
                .shadow(color: model.selectedShip.color.opacity(0.75), radius: 28)

            VStack(spacing: 14) {
                PrimaryButton(title: "出擊", systemImage: "paperplane.fill") {
                    model.screen = .levels
                }
                SecondaryButton(title: "機體庫", systemImage: "wrench.and.screwdriver.fill") {
                    model.screen = .hangar
                }
                SecondaryButton(title: "設定", systemImage: "gearshape.fill") {
                    model.screen = .settings
                }
            }
            .frame(maxWidth: 430)

            HStack {
                Label("\(model.progress.coins)", systemImage: "sparkles")
                    .foregroundStyle(.yellow)
                Spacer()
                Text(model.selectedShip.name)
                    .foregroundStyle(.secondary)
            }
            .font(.headline)
            .padding(.horizontal, 8)
            .frame(maxWidth: 430)
            Spacer()
        }
        .padding()
    }
}

struct GameLogo: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("星際雷霆")
                .font(.largeTitle.weight(.black))
                .foregroundStyle(
                    LinearGradient(colors: [.white, .cyan], startPoint: .top, endPoint: .bottom)
                )
            Text("STELLAR STRIKE")
                .font(.caption.weight(.bold))
                .tracking(5)
                .foregroundStyle(.cyan)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ShipEmblem: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: 1)
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 12]))
                .foregroundStyle(color.opacity(0.6))
                .padding(18)
            Image(systemName: "airplane")
                .font(.system(size: 76, weight: .light))
                .rotationEffect(.degrees(-90))
                .foregroundStyle(.white, color)
                .symbolRenderingMode(.palette)
        }
        .accessibilityHidden(true)
    }
}

struct PrimaryButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.cyan.opacity(0.35))
                }
        }
        .buttonStyle(.plain)
    }
}

struct ScreenHeader: View {
    let title: LocalizedStringResource
    let coins: Int
    let backAction: () -> Void

    var body: some View {
        HStack {
            Button(action: backAction) {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("返回")
            Spacer()
            Text(title)
                .font(.title2.weight(.bold))
            Spacer()
            Label("\(coins)", systemImage: "sparkles")
                .foregroundStyle(.yellow)
                .frame(minWidth: 72)
        }
    }
}

struct HangarView: View {
    let model: GameAppModel

    var body: some View {
        VStack(spacing: 18) {
            ScreenHeader(title: "機體庫", coins: model.progress.coins) {
                model.screen = .menu
            }

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(ShipID.allCases) { ship in
                        ShipCard(
                            ship: ship,
                            isUnlocked: model.progress.unlockedShips.contains(ship),
                            isSelected: model.selectedShip == ship,
                            upgradeLevel: model.progress.upgrades[ship, default: 1],
                            onSelect: { model.selectShip(ship) },
                            onUnlock: { model.unlockShip(ship) }
                        )
                    }
                }
            }

            let currentLevel = model.progress.upgrades[model.selectedShip, default: 1]
            Button {
                model.upgradeSelectedShip()
            } label: {
                let cost = model.upgradeCost(for: currentLevel)
                Label(
                    currentLevel >= 5 ? "已達最高等級" : "強化機體・\(cost) 金幣",
                    systemImage: "arrow.up.circle.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            .disabled(currentLevel >= 5 || model.progress.coins < model.upgradeCost(for: currentLevel))
        }
        .padding()
        .frame(maxWidth: 700)
    }
}

struct ShipCard: View {
    let ship: ShipID
    let isUnlocked: Bool
    let isSelected: Bool
    let upgradeLevel: Int
    let onSelect: () -> Void
    let onUnlock: () -> Void

    var body: some View {
        HStack(spacing: 18) {
            ShipEmblem(color: ship.color)
                .frame(width: 88, height: 88)
                .opacity(isUnlocked ? 1 : 0.35)

            VStack(alignment: .leading, spacing: 5) {
                Text(ship.name)
                    .font(.headline)
                Text(ship.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("強化等級 \(upgradeLevel)／5")
                    .font(.caption)
                    .foregroundStyle(ship.color)
            }

            Spacer()

            if isUnlocked {
                Button(isSelected ? "使用中" : "選擇", action: onSelect)
                    .buttonStyle(.borderedProminent)
                    .tint(ship.color)
                    .disabled(isSelected)
            } else {
                Button("\(ship.unlockCost)", action: onUnlock)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.white.opacity(isSelected ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(isSelected ? ship.color : .white.opacity(0.12), lineWidth: isSelected ? 2 : 1)
        }
    }
}

struct LevelSelectView: View {
    let model: GameAppModel

    var body: some View {
        VStack(spacing: 18) {
            ScreenHeader(title: "選擇作戰區域", coins: model.progress.coins) {
                model.screen = .menu
            }

            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(LevelDefinition.all) { level in
                        LevelCard(
                            level: level,
                            isUnlocked: level.id <= model.progress.highestUnlockedLevel,
                            highScore: model.progress.highScores[level.id, default: 0],
                            stars: model.progress.bestStars[level.id, default: 0]
                        ) {
                            model.start(level: level.id)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: 700)
    }
}

struct LevelCard: View {
    let level: LevelDefinition
    let isUnlocked: Bool
    let highScore: Int
    let stars: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15)
                        .fill(level.accent.opacity(0.2))
                    Image(systemName: isUnlocked ? "scope" : "lock.fill")
                        .font(.title)
                        .foregroundStyle(level.accent)
                }
                .frame(width: 70, height: 70)

                VStack(alignment: .leading, spacing: 5) {
                    Text("第 \(level.id) 關")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(level.accent)
                    Text(level.title)
                        .font(.title3.weight(.bold))
                    Text(level.sector)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Image(systemName: "chevron.right")
                    if highScore > 0 {
                        Text("最高 \(highScore)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 2) {
                        ForEach(1...3, id: \.self) { value in
                            Image(systemName: value <= stars ? "star.fill" : "star")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                }
            }
            .padding()
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(level.accent.opacity(isUnlocked ? 0.45 : 0.12))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isUnlocked)
        .opacity(isUnlocked ? 1 : 0.5)
    }
}

struct SettingsView: View {
    let model: GameAppModel

    var body: some View {
        VStack(spacing: 18) {
            ScreenHeader(title: "設定", coins: model.progress.coins) {
                model.screen = .menu
            }

            VStack(spacing: 0) {
                SettingToggle(title: "背景音樂", systemImage: "music.note", isOn: Binding(
                    get: { model.progress.musicEnabled },
                    set: model.setMusic
                ))
                Divider()
                SettingToggle(title: "遊戲音效", systemImage: "speaker.wave.2.fill", isOn: Binding(
                    get: { model.progress.soundEnabled },
                    set: model.setSound
                ))
                Divider()
                SettingToggle(title: "震動回饋", systemImage: "waveform.path", isOn: Binding(
                    get: { model.progress.hapticsEnabled },
                    set: model.setHaptics
                ))
            }
            .padding(.horizontal)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

            ControlSettingsCard(model: model)

            VStack(alignment: .leading, spacing: 12) {
                Label("操作方式", systemImage: "hand.draw.fill")
                    .font(.headline)
                Text("在戰鬥畫面拖曳手指控制戰機。武器會自動射擊；能量充滿後可啟動雷霆爆發。")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            Spacer()
        }
        .padding()
        .frame(maxWidth: 700)
    }
}

struct ControlSettingsCard: View {
    let model: GameAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("相對拖曳控制", systemImage: "hand.point.up.left.fill")
                .font(.headline)

            VStack(alignment: .leading) {
                Text("靈敏度 \(model.progress.controlSensitivity, format: .number.precision(.fractionLength(1)))")
                    .font(.subheadline)
                Slider(
                    value: Binding(
                        get: { model.progress.controlSensitivity },
                        set: model.setControlSensitivity
                    ),
                    in: 0.6...1.8,
                    step: 0.1
                )
            }

            VStack(alignment: .leading) {
                Text("底部手指偏移 \(Int(model.progress.fingerOffset))")
                    .font(.subheadline)
                Slider(
                    value: Binding(
                        get: { model.progress.fingerOffset },
                        set: model.setFingerOffset
                    ),
                    in: 50...140,
                    step: 5
                )
            }
        }
        .padding()
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct SettingToggle: View {
    let title: LocalizedStringResource
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(title, systemImage: systemImage)
        }
        .padding(.vertical, 15)
        .tint(.cyan)
    }
}

struct GameContainerView: View {
    let model: GameAppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let scene = model.activeScene, let session = model.session {
            GeometryReader { proxy in
                ZStack {
                    SpriteView(scene: scene, options: [.ignoresSiblingOrder])
                        .background(.black)
                        .ignoresSafeArea()
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    scene.movePlayer(
                                        relativeViewTranslation: value.translation,
                                        viewSize: proxy.size,
                                        sensitivity: model.progress.controlSensitivity,
                                        fingerOffset: model.progress.fingerOffset
                                    )
                                }
                                .onEnded { _ in
                                    scene.endPlayerDrag()
                                }
                        )

                    VStack {
                        BattleHUD(session: session, pauseAction: scene.togglePause)
                        Spacer()
                        SpecialButton(energy: session.energy, action: scene.activateSpecial)
                    }
                    .padding()

                    if session.state == .paused {
                        PauseOverlay(
                            resumeAction: scene.togglePause,
                            leaveAction: model.leaveBattle
                        )
                    }

                    if let settlement = session.settlement {
                        ResultOverlay(
                            settlement: settlement,
                            canAdvance: settlement.outcome.victory && model.selectedLevel < 5,
                            retryAction: { model.start(level: model.selectedLevel) },
                            nextAction: model.startNextLevel,
                            leaveAction: model.leaveBattle
                        )
                    }
                }
            }
            .onChange(of: session.state) { _, newState in
                guard newState == .victory || newState == .defeat else { return }
                model.settleCurrentBattle()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active && session.state == .playing {
                    scene.togglePause()
                }
            }
        }
    }
}

struct BattleHUD: View {
    let session: GameSession
    let pauseAction: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("\(session.health)/\(session.maxHealth)", systemImage: "heart.fill")
                    .foregroundStyle(.pink)
                Text("P\(session.power)")
                    .font(.caption.weight(.black))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.18), in: Capsule())
                if session.shieldCharges > 0 {
                    Image(systemName: "shield.fill")
                        .foregroundStyle(.cyan)
                        .accessibilityLabel("護盾已啟用")
                }
                Spacer()
                Text(session.score, format: .number)
                    .font(.headline.monospacedDigit())
                Spacer()
                Button(action: pauseAction) {
                    Image(systemName: "pause.fill")
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("暫停")
            }

            if session.bossVisible {
                VStack(spacing: 4) {
                    HStack {
                        Text("警告・敵方旗艦")
                        Spacer()
                        Text("PHASE \(session.bossPhase)")
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(session.bossInvulnerable ? .cyan : .red)

                    ProgressView(value: Double(session.bossHealth), total: Double(max(1, session.bossMaxHealth)))
                        .tint(session.bossInvulnerable ? .cyan : .red)

                    if session.bossInvulnerable {
                        Label("階段轉換・無敵護盾", systemImage: "shield.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.cyan)
                    }
                }
            }
        }
        .padding(12)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SpecialButton: View {
    let energy: Double
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: energy)
                        .stroke(.cyan, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "bolt.fill")
                        .font(.title2)
                        .foregroundStyle(energy >= 1 ? .yellow : .secondary)
                }
                .frame(width: 66, height: 66)
                .background(.black.opacity(0.45), in: Circle())
            }
            .disabled(energy < 1)
            .accessibilityLabel("雷霆爆發")
            .accessibilityValue(energy >= 1 ? "可以使用" : "能量尚未充滿")
        }
    }
}

struct PauseOverlay: View {
    let resumeAction: () -> Void
    let leaveAction: () -> Void

    var body: some View {
        OverlayPanel {
            Text("作戰暫停")
                .font(.largeTitle.bold())
            PrimaryButton(title: "繼續作戰", systemImage: "play.fill", action: resumeAction)
            SecondaryButton(title: "撤離關卡", systemImage: "rectangle.portrait.and.arrow.right", action: leaveAction)
        }
    }
}

struct ResultOverlay: View {
    let settlement: BattleSettlement
    let canAdvance: Bool
    let retryAction: () -> Void
    let nextAction: () -> Void
    let leaveAction: () -> Void

    var body: some View {
        OverlayPanel {
            Image(systemName: settlement.outcome.victory ? "trophy.fill" : "shield.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(settlement.outcome.victory ? .yellow : .red)
            Text(settlement.outcome.victory ? "作戰勝利" : "任務失敗")
                .font(.largeTitle.bold())

            HStack(spacing: 8) {
                ForEach(1...3, id: \.self) { star in
                    Image(systemName: star <= settlement.stars ? "star.fill" : "star")
                        .font(.title2)
                        .foregroundStyle(star <= settlement.stars ? .yellow : .secondary)
                }
            }

            HStack {
                StatPill(title: "分數", value: settlement.outcome.score)
                StatPill(title: "金幣", value: settlement.earnedCoins)
            }

            if settlement.isFirstClear {
                Label("首次通關獎勵已取得", systemImage: "gift.fill")
                    .foregroundStyle(.yellow)
            }
            if settlement.isPersonalBest {
                Label("個人最佳紀錄！", systemImage: "crown.fill")
                    .foregroundStyle(.cyan)
            }

            if canAdvance {
                PrimaryButton(title: "下一關", systemImage: "arrow.right.circle.fill", action: nextAction)
            }
            SecondaryButton(title: "再次出擊", systemImage: "arrow.clockwise", action: retryAction)
            SecondaryButton(title: "返回關卡", systemImage: "map.fill", action: leaveAction)
        }
    }
}

struct StatPill: View {
    let title: LocalizedStringResource
    let value: Int

    var body: some View {
        VStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.title2.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct OverlayPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                content
            }
            .padding(26)
            .frame(maxWidth: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
            .overlay {
                RoundedRectangle(cornerRadius: 26)
                    .stroke(.cyan.opacity(0.4))
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
