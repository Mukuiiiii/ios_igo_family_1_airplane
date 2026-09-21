import SpriteKit
import SwiftUI

private enum BossAttackMode {
    case basic
    case specialOne
    case specialTwo
}

private enum PhysicsCategory {
    static let player: UInt32 = 1 << 0
    static let enemy: UInt32 = 1 << 1
    static let playerShot: UInt32 = 1 << 2
    static let enemyShot: UInt32 = 1 << 3
    static let pickup: UInt32 = 1 << 4
}

@MainActor
final class GameScene: SKScene, SKPhysicsContactDelegate {
    private let level: LevelDefinition
    private let ship: ShipID
    private let upgradeLevel: Int
    private let session: GameSession
    private let waveDirector: WaveDirector

    private let world = SKNode()
    private let player = SKShapeNode()
    private var backgroundTiles: [SKSpriteNode] = []
    private var lastUpdateTime = 0.0
    private var spawnAccumulator = 0.0
    private var shotAccumulator = 0.0
    private var bossAttackAccumulator = 0.0
    private var bossAttackMode: BossAttackMode = .basic
    private var bossModeElapsed = 0.0
    private var bossModeDuration = 7.0
    private var bossWarningUntil = 0.0
    private var boss: SKShapeNode?
    private var bossHP = 0
    private var bossPhase = 1
    private var bossInvulnerableUntil = 0.0
    private var didFinish = false
    private var invulnerableUntil = 0.0
    private var tempestSpecialUntil = 0.0
    private var aegisBarrierUntil = 0.0
    private var aegisBarrierBlockedDamage = false
    private var previousDragTranslation: CGSize?

    init(size: CGSize, level: LevelDefinition, ship: ShipID, upgradeLevel: Int, session: GameSession) {
        self.level = level
        self.ship = ship
        self.upgradeLevel = upgradeLevel
        self.session = session
        self.waveDirector = WaveDirector(level: level)
        super.init(size: size)
        anchorPoint = .zero
        backgroundColor = SKColor(red: 0.01, green: 0.015, blue: 0.07, alpha: 1)
        physicsWorld.gravity = .zero
        physicsWorld.contactDelegate = self
        addChild(world)
        createScrollingBackground()
        createStarfield()
        createPlayer()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func movePlayer(
        relativeViewTranslation translation: CGSize,
        viewSize: CGSize,
        sensitivity: Double,
        fingerOffset: Double
    ) {
        guard session.state == .playing else { return }
        guard let previous = previousDragTranslation else {
            previousDragTranslation = translation
            return
        }

        let displayScale = min(viewSize.width / size.width, viewSize.height / size.height)
        guard displayScale > 0 else { return }
        let multiplier = CGFloat(sensitivity) / displayScale
        let deltaX = (translation.width - previous.width) * multiplier
        let deltaY = (translation.height - previous.height) * multiplier
        previousDragTranslation = translation

        let lowerLimit = max(80, CGFloat(fingerOffset))
        let x = max(28, min(size.width - 28, player.position.x + deltaX))
        let y = max(lowerLimit, min(size.height - 80, player.position.y - deltaY))
        player.position = CGPoint(x: x, y: y)
    }

    func endPlayerDrag() {
        previousDragTranslation = nil
    }

    func togglePause() {
        if session.state == .playing {
            session.state = .paused
            isPaused = true
        } else if session.state == .paused {
            session.state = .playing
            isPaused = false
        }
    }

    func activateSpecial() {
        let requirement = Double(ship.specialDamageRequirement)
        guard !didFinish, session.state == .playing, session.energy >= requirement else { return }
        session.energy = 0

        switch ship {
        case .nova:
            activateNovaSpecial()
        case .tempest:
            tempestSpecialUntil = session.elapsed + 5
            showBossCallout("集束射擊・5 秒")
        case .aegis:
            activateAegisBarrier()
        }
    }

    private func activateNovaSpecial() {
        clearEnemyProjectiles()
        world.children.filter { $0.name == "enemy" || $0.name == "boss" }.forEach { node in
            self.damage(node: node, amount: 18 + self.upgradeLevel * 4, chargesSpecial: false)
        }
        let flash = SKShapeNode(circleOfRadius: size.width * 0.7)
        flash.fillColor = .cyan.withAlphaComponent(0.22)
        flash.strokeColor = .white
        flash.position = player.position
        flash.zPosition = 20
        addChild(flash)
        flash.run(.sequence([.scale(to: 1.5, duration: 0.25), .fadeOut(withDuration: 0.25), .removeFromParent()]))
    }

    private func activateAegisBarrier() {
        aegisBarrierUntil = session.elapsed + 3
        aegisBarrierBlockedDamage = false

        let barrier = SKShapeNode(circleOfRadius: 42)
        barrier.name = "playerEnergyBarrier"
        barrier.fillColor = .systemCyan.withAlphaComponent(0.16)
        barrier.strokeColor = .white
        barrier.lineWidth = 4
        barrier.glowWidth = 14
        barrier.zPosition = -1
        player.addChild(barrier)
        barrier.run(.sequence([
            .repeat(.sequence([
                .scale(to: 1.08, duration: 0.25),
                .scale(to: 0.96, duration: 0.25)
            ]), count: 6),
            .removeFromParent()
        ]))

        run(.sequence([
            .wait(forDuration: 3),
            .run { [weak self] in
                guard let self, !self.didFinish else { return }
                self.aegisBarrierUntil = 0
                if self.aegisBarrierBlockedDamage {
                    self.session.shieldCharges = min(3, self.session.shieldCharges + 1)
                    self.showBossCallout("能量護盾轉化・護盾 +1")
                }
                self.aegisBarrierBlockedDamage = false
            }
        ]))
    }

    override func update(_ currentTime: TimeInterval) {
        guard session.state == .playing, !didFinish else { return }
        let delta = lastUpdateTime == 0 ? 0 : min(1.0 / 20.0, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime
        session.elapsed += delta
        spawnAccumulator += delta
        shotAccumulator += delta

        scrollBackground(delta: delta)
        scrollStars(delta: delta)

        if boss == nil {
            for cue in waveDirector.drainCues(upTo: session.elapsed) {
                showWaveCue(cue.message)
                if cue.message.contains("補給") {
                    spawnSupplyDrop()
                }
            }
            for spawn in waveDirector.drainSpawns(upTo: session.elapsed) {
                spawnEnemy(archetype: spawn.archetype, normalizedX: spawn.normalizedX)
            }
            if session.elapsed >= level.duration {
                spawnBoss()
            }
        }

        let weapon = WeaponConfiguration.configuration(for: ship, power: session.power, upgrade: upgradeLevel)
        if shotAccumulator >= weapon.fireInterval {
            shotAccumulator = 0
            firePlayerShots(configuration: weapon)
        }

        if boss != nil {
            let isTransitioning = session.elapsed < bossInvulnerableUntil
            session.bossInvulnerable = isTransitioning

            if !isTransitioning {
                updateBossAttackMode(delta: delta)
            }
        }

        if player.position.y < 0 || session.health <= 0 {
            endBattle(victory: false)
        }
    }

    func didBegin(_ contact: SKPhysicsContact) {
        guard !didFinish, session.state == .playing else { return }
        let pair = contact.bodyA.categoryBitMask | contact.bodyB.categoryBitMask
        let nodes = [contact.bodyA.node, contact.bodyB.node].compactMap { $0 }

        if pair == PhysicsCategory.enemy | PhysicsCategory.playerShot {
            guard let enemy = nodes.first(where: { $0.physicsBody?.categoryBitMask == PhysicsCategory.enemy }),
                  let shot = nodes.first(where: { $0.physicsBody?.categoryBitMask == PhysicsCategory.playerShot }) else { return }
            let enemyID = enemy.userData?["hitID"] as? String ?? UUID().uuidString
            let hitIDs = shot.userData?["hitIDs"] as? NSMutableSet
            guard hitIDs?.contains(enemyID) != true else { return }
            hitIDs?.add(enemyID)

            let isPiercing = shot.userData?["piercing"] as? Bool ?? false
            if !isPiercing {
                shot.removeFromParent()
            }
            let damageAmount = shot.userData?["damage"] as? Int ?? (2 + upgradeLevel)
            damage(node: enemy, amount: damageAmount)
        } else if pair == PhysicsCategory.player | PhysicsCategory.enemyShot {
            let hostileShot = nodes.first(where: { $0.physicsBody?.categoryBitMask == PhysicsCategory.enemyShot })
            if absorbProjectileWithAegisBarrier(hostileShot) {
                return
            }
            let isPersistent = hostileShot?.userData?["persistent"] as? Bool ?? false
            if !isPersistent {
                hostileShot?.removeFromParent()
            }
            hitPlayer()
        } else if pair == PhysicsCategory.player | PhysicsCategory.enemy {
            let enemy = nodes.first(where: { $0.physicsBody?.categoryBitMask == PhysicsCategory.enemy })
            if enemy !== boss {
                enemy?.removeFromParent()
            }
            hitPlayer()
        } else if pair == PhysicsCategory.player | PhysicsCategory.pickup {
            guard let pickup = nodes.first(where: { $0.physicsBody?.categoryBitMask == PhysicsCategory.pickup }) else { return }
            let kind = pickup.userData?["kind"] as? String ?? "power"
            pickup.removeFromParent()
            switch kind {
            case "repair":
                session.health = min(session.maxHealth, session.health + 2)
                showWaveCue("修復完成・生命 +2")
            case "shield":
                session.shieldCharges = min(3, session.shieldCharges + 1)
                showWaveCue("護盾充能・目前 \(session.shieldCharges)/3")
            default:
                let previousPower = session.power
                session.power = min(3, session.power + 1)
                if session.power > previousPower {
                    showWaveCue("POWER UP・火力 P\(session.power)")
                }
            }
        }
    }

    private func createStarfield() {
        for index in 0..<28 {
            let star = SKShapeNode(circleOfRadius: CGFloat.random(in: 0.7...1.8))
            star.fillColor = index.isMultiple(of: 6) ? level.accent.skColor : .white
            star.strokeColor = .clear
            star.alpha = CGFloat.random(in: 0.25...0.9)
            star.position = CGPoint(x: .random(in: 0...size.width), y: .random(in: 0...size.height))
            star.name = "star"
            star.userData = ["speed": CGFloat.random(in: 28...100)]
            world.addChild(star)
        }
    }

    private func createScrollingBackground() {
        let texture = SKTexture(imageNamed: "Level\(level.id)Background")
        texture.filteringMode = .linear
        for index in 0..<2 {
            let tile = SKSpriteNode(texture: texture)
            tile.anchorPoint = .zero
            tile.position = CGPoint(x: 0, y: CGFloat(index) * size.height)
            tile.size = size
            tile.zPosition = -20
            tile.alpha = 0.82
            tile.name = "background"
            world.addChild(tile)
            backgroundTiles.append(tile)
        }
    }

    private func scrollBackground(delta: TimeInterval) {
        let speed = CGFloat(34 + level.id * 5)
        for tile in backgroundTiles {
            tile.position.y -= speed * delta
            if tile.position.y <= -size.height {
                tile.position.y += size.height * 2
            }
        }
    }

    private func scrollStars(delta: TimeInterval) {
        world.children.filter { $0.name == "star" }.forEach { star in
            let speed = star.userData?["speed"] as? CGFloat ?? 50
            star.position.y -= speed * delta
            if star.position.y < -4 {
                star.position = CGPoint(x: .random(in: 0...size.width), y: size.height + 4)
            }
        }
    }

    private func createPlayer() {
        player.path = playerPath()
        player.fillColor = ship.color.skColor
        player.strokeColor = .white
        player.lineWidth = 2
        player.glowWidth = 7
        player.position = CGPoint(x: size.width / 2, y: 110)
        player.zPosition = 8
        player.physicsBody = SKPhysicsBody(circleOfRadius: 12)
        player.physicsBody?.isDynamic = true
        player.physicsBody?.categoryBitMask = PhysicsCategory.player
        player.physicsBody?.contactTestBitMask = PhysicsCategory.enemy | PhysicsCategory.enemyShot | PhysicsCategory.pickup
        player.physicsBody?.collisionBitMask = 0
        world.addChild(player)

        let cockpit = SKShapeNode(ellipseOf: CGSize(width: 9, height: 18))
        cockpit.fillColor = .white.withAlphaComponent(0.9)
        cockpit.strokeColor = ship.color.skColor
        cockpit.position = CGPoint(x: 0, y: 4)
        player.addChild(cockpit)
    }

    private func playerPath() -> CGPath {
        switch ship {
        case .nova:
            polygon([.init(x: 0, y: 30), .init(x: -10, y: 8), .init(x: -25, y: -18), .init(x: -7, y: -12), .init(x: 0, y: -22), .init(x: 7, y: -12), .init(x: 25, y: -18), .init(x: 10, y: 8)])
        case .tempest:
            polygon([.init(x: 0, y: 32), .init(x: -7, y: 12), .init(x: -29, y: -5), .init(x: -18, y: -20), .init(x: 0, y: -12), .init(x: 18, y: -20), .init(x: 29, y: -5), .init(x: 7, y: 12)])
        case .aegis:
            polygon([.init(x: 0, y: 29), .init(x: -16, y: 14), .init(x: -25, y: -15), .init(x: -11, y: -24), .init(x: 0, y: -17), .init(x: 11, y: -24), .init(x: 25, y: -15), .init(x: 16, y: 14)])
        }
    }

    private func firePlayerShots(configuration: WeaponConfiguration) {
        let count = configuration.baseProjectileCount
        for index in 0..<count {
            let isLaser = configuration.isPiercing
            let shotSize = CGSize(width: isLaser ? 7 : 4, height: isLaser ? 34 : 18)
            let shot = SKShapeNode(rectOf: shotSize, cornerRadius: 2)
            shot.fillColor = ship.color.skColor
            shot.strokeColor = .white
            shot.glowWidth = isLaser ? 7 : 4
            let spacing: CGFloat = ship == .nova ? 12 : 9
            let centeredIndex = CGFloat(index) - CGFloat(count - 1) / 2
            shot.position = CGPoint(x: player.position.x + centeredIndex * spacing, y: player.position.y + 30)
            shot.zPosition = 5
            shot.userData = [
                "damage": configuration.baseDamage,
                "piercing": configuration.isPiercing,
                "hitIDs": NSMutableSet()
            ]
            shot.physicsBody = SKPhysicsBody(rectangleOf: shotSize)
            shot.physicsBody?.categoryBitMask = PhysicsCategory.playerShot
            shot.physicsBody?.contactTestBitMask = PhysicsCategory.enemy
            shot.physicsBody?.collisionBitMask = 0
            world.addChild(shot)

            let isTempestFocused = ship == .tempest && session.elapsed < tempestSpecialUntil
            let angle = ship == .tempest && !isTempestFocused
                ? centeredIndex * configuration.spreadAngle
                : 0
            let travelDistance = size.height + 100
            let movement = CGVector(dx: sin(angle) * travelDistance, dy: cos(angle) * travelDistance)
            let duration = TimeInterval(travelDistance / configuration.projectileSpeed)
            shot.run(.sequence([.move(by: movement, duration: duration), .removeFromParent()]))
        }
    }

    private func spawnEnemy(archetype: EnemyArchetype, normalizedX: CGFloat) {
        let variant: Int
        switch archetype {
        case .rammer: variant = 0
        case .strafer: variant = 1
        case .turret: variant = 2
        }

        let enemy = SKShapeNode(path: enemyPath(variant: variant))
        enemy.name = "enemy"
        enemy.fillColor = archetype == .rammer ? .systemRed : (archetype == .strafer ? level.accent.skColor : .systemOrange)
        enemy.strokeColor = .white
        enemy.glowWidth = 4
        enemy.position = CGPoint(x: max(35, min(size.width - 35, normalizedX * size.width)), y: size.height + 35)
        enemy.zPosition = 6
        let hpBonus = archetype == .turret ? 5 : 0
        enemy.userData = ["hp": 4 + level.id * 2 + hpBonus, "hitID": UUID().uuidString]
        enemy.physicsBody = SKPhysicsBody(circleOfRadius: 18)
        enemy.physicsBody?.categoryBitMask = PhysicsCategory.enemy
        enemy.physicsBody?.contactTestBitMask = PhysicsCategory.player | PhysicsCategory.playerShot
        enemy.physicsBody?.collisionBitMask = 0
        world.addChild(enemy)

        let fire = SKAction.run { [weak self, weak enemy] in
            guard let self, let enemy, enemy.parent != nil, !self.didFinish else { return }
            self.fireEnemyShot(from: enemy.position, toward: self.player.position)
        }

        switch archetype {
        case .rammer:
            enemy.run(.sequence([
                .move(to: player.position, duration: max(1.4, 2.5 - Double(level.id) * 0.12)),
                .moveBy(x: 0, y: -180, duration: 0.5),
                .removeFromParent()
            ]))
        case .strafer:
            let sideX: CGFloat = normalizedX < 0.5 ? size.width - 45 : 45
            enemy.run(.sequence([
                .move(to: CGPoint(x: sideX, y: size.height * 0.72), duration: 1.0),
                .group([
                    .move(to: CGPoint(x: normalizedX * size.width, y: size.height * 0.48), duration: 2.2),
                    .repeat(.sequence([.wait(forDuration: 0.55), fire]), count: 4)
                ]),
                .moveBy(x: 0, y: -size.height, duration: 2.0),
                .removeFromParent()
            ]))
        case .turret:
            enemy.run(.sequence([
                .move(to: CGPoint(x: normalizedX * size.width, y: size.height * 0.72), duration: 1.1),
                .repeat(.sequence([.wait(forDuration: 0.65), fire]), count: 6),
                .moveBy(x: 0, y: -size.height, duration: 2.5),
                .removeFromParent()
            ]))
        }
    }

    private func enemyPath(variant: Int) -> CGPath {
        let designs: [[[CGPoint]]] = [
            [[.init(x: 0, y: -22), .init(x: -22, y: 16), .init(x: -7, y: 10), .init(x: 0, y: 18), .init(x: 7, y: 10), .init(x: 22, y: 16)], [.init(x: 0, y: -23), .init(x: -25, y: 2), .init(x: -12, y: 18), .init(x: 0, y: 9), .init(x: 12, y: 18), .init(x: 25, y: 2)], [.init(x: 0, y: -25), .init(x: -14, y: -5), .init(x: -24, y: 15), .init(x: 0, y: 10), .init(x: 24, y: 15), .init(x: 14, y: -5)]],
            [[.init(x: 0, y: -24), .init(x: -24, y: -2), .init(x: -18, y: 18), .init(x: 0, y: 8), .init(x: 18, y: 18), .init(x: 24, y: -2)], [.init(x: 0, y: -20), .init(x: -27, y: 12), .init(x: -8, y: 7), .init(x: 0, y: 22), .init(x: 8, y: 7), .init(x: 27, y: 12)], [.init(x: 0, y: -26), .init(x: -18, y: -12), .init(x: -22, y: 16), .init(x: 0, y: 6), .init(x: 22, y: 16), .init(x: 18, y: -12)]],
            [[.init(x: 0, y: -26), .init(x: -9, y: -7), .init(x: -25, y: 4), .init(x: -14, y: 21), .init(x: 0, y: 10), .init(x: 14, y: 21), .init(x: 25, y: 4), .init(x: 9, y: -7)], [.init(x: 0, y: -23), .init(x: -24, y: -10), .init(x: -17, y: 18), .init(x: 0, y: 13), .init(x: 17, y: 18), .init(x: 24, y: -10)], [.init(x: 0, y: -27), .init(x: -14, y: -12), .init(x: -27, y: 15), .init(x: -6, y: 9), .init(x: 0, y: 21), .init(x: 6, y: 9), .init(x: 27, y: 15), .init(x: 14, y: -12)]],
            [[.init(x: 0, y: -24), .init(x: -20, y: -8), .init(x: -27, y: 13), .init(x: -8, y: 8), .init(x: 0, y: 20), .init(x: 8, y: 8), .init(x: 27, y: 13), .init(x: 20, y: -8)], [.init(x: 0, y: -27), .init(x: -12, y: -4), .init(x: -24, y: 8), .init(x: -15, y: 22), .init(x: 0, y: 12), .init(x: 15, y: 22), .init(x: 24, y: 8), .init(x: 12, y: -4)], [.init(x: 0, y: -23), .init(x: -25, y: -14), .init(x: -19, y: 16), .init(x: 0, y: 7), .init(x: 19, y: 16), .init(x: 25, y: -14)]],
            [[.init(x: 0, y: -28), .init(x: -10, y: -8), .init(x: -28, y: 3), .init(x: -17, y: 20), .init(x: 0, y: 11), .init(x: 17, y: 20), .init(x: 28, y: 3), .init(x: 10, y: -8)], [.init(x: 0, y: -25), .init(x: -27, y: -3), .init(x: -20, y: 20), .init(x: 0, y: 8), .init(x: 20, y: 20), .init(x: 27, y: -3)], [.init(x: 0, y: -29), .init(x: -16, y: -12), .init(x: -30, y: 14), .init(x: -7, y: 8), .init(x: 0, y: 23), .init(x: 7, y: 8), .init(x: 30, y: 14), .init(x: 16, y: -12)]]
        ]
        return polygon(designs[level.id - 1][variant])
    }

    private func fireEnemyShot(from start: CGPoint, toward target: CGPoint) {
        let shot = SKShapeNode(circleOfRadius: 5)
        shot.name = "enemyShot"
        shot.fillColor = .systemPink
        shot.strokeColor = .white
        shot.glowWidth = 5
        shot.position = start
        shot.zPosition = 7
        shot.physicsBody = SKPhysicsBody(circleOfRadius: 5)
        shot.physicsBody?.categoryBitMask = PhysicsCategory.enemyShot
        shot.physicsBody?.contactTestBitMask = PhysicsCategory.player
        shot.physicsBody?.collisionBitMask = 0
        world.addChild(shot)

        let vector = CGVector(dx: target.x - start.x, dy: target.y - start.y)
        let length = max(1, hypot(vector.dx, vector.dy))
        let distance = size.height * 1.4
        let end = CGPoint(x: start.x + vector.dx / length * distance, y: start.y + vector.dy / length * distance)
        shot.run(.sequence([.move(to: end, duration: 3.0), .removeFromParent()]))
    }

    private func spawnBoss() {
        let shape = SKShapeNode(path: bossPath())
        shape.name = "boss"
        shape.fillColor = level.accent.skColor
        shape.strokeColor = .white
        shape.lineWidth = 3
        shape.glowWidth = 12
        shape.position = CGPoint(x: size.width / 2, y: size.height + 70)
        shape.zPosition = 9
        bossHP = level.bossHealth
        bossPhase = 1
        bossAttackMode = .basic
        bossAttackAccumulator = 0
        bossModeElapsed = 0
        bossModeDuration = Double.random(in: 5...10)
        bossWarningUntil = 0
        bossInvulnerableUntil = 0
        session.bossPhase = 1
        session.bossInvulnerable = false
        shape.userData = ["hp": bossHP, "hitID": UUID().uuidString]
        shape.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 116, height: 60))
        shape.physicsBody?.categoryBitMask = PhysicsCategory.enemy
        shape.physicsBody?.contactTestBitMask = PhysicsCategory.player | PhysicsCategory.playerShot
        shape.physicsBody?.collisionBitMask = 0
        world.addChild(shape)
        boss = shape
        session.bossMaxHealth = bossHP
        session.bossHealth = bossHP
        session.bossVisible = true
        shape.run(.move(to: CGPoint(x: size.width / 2, y: size.height - 130), duration: 1.2))
    }

    private func bossPath() -> CGPath {
        let designs: [[CGPoint]] = [
            [.init(x: 0, y: -42), .init(x: -28, y: -20), .init(x: -70, y: -30), .init(x: -58, y: 18), .init(x: -25, y: 34), .init(x: 0, y: 25), .init(x: 25, y: 34), .init(x: 58, y: 18), .init(x: 70, y: -30), .init(x: 28, y: -20)],
            [.init(x: 0, y: -45), .init(x: -18, y: -22), .init(x: -72, y: -12), .init(x: -55, y: 34), .init(x: -20, y: 22), .init(x: 0, y: 40), .init(x: 20, y: 22), .init(x: 55, y: 34), .init(x: 72, y: -12), .init(x: 18, y: -22)],
            [.init(x: 0, y: -48), .init(x: -22, y: -20), .init(x: -68, y: -34), .init(x: -62, y: 20), .init(x: -32, y: 38), .init(x: 0, y: 27), .init(x: 32, y: 38), .init(x: 62, y: 20), .init(x: 68, y: -34), .init(x: 22, y: -20)],
            [.init(x: 0, y: -44), .init(x: -35, y: -28), .init(x: -74, y: 0), .init(x: -48, y: 42), .init(x: 0, y: 29), .init(x: 48, y: 42), .init(x: 74, y: 0), .init(x: 35, y: -28)],
            [.init(x: 0, y: -50), .init(x: -20, y: -25), .init(x: -76, y: -20), .init(x: -66, y: 28), .init(x: -30, y: 44), .init(x: 0, y: 31), .init(x: 30, y: 44), .init(x: 66, y: 28), .init(x: 76, y: -20), .init(x: 20, y: -25)]
        ]
        return polygon(designs[level.id - 1])
    }

    private func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        return path
    }

    private func fireBossPattern() {
        guard let boss else { return }
        let standardBulletCount = 5 + level.id * 2
        let bulletCount: Int
        switch level.id {
        case 4:
            bulletCount = (standardBulletCount + 1) / 2
        case 5:
            bulletCount = standardBulletCount - 2
        default:
            bulletCount = standardBulletCount
        }
        for index in 0..<bulletCount {
            let angle = CGFloat.pi * 0.22 + CGFloat(index) / CGFloat(bulletCount - 1) * CGFloat.pi * 0.56
            let target = CGPoint(x: boss.position.x + cos(angle) * 500, y: boss.position.y - sin(angle) * 800)
            fireEnemyShot(from: boss.position, toward: target)
        }
        let movement = SKAction.moveTo(x: .random(in: 80...(size.width - 80)), duration: 0.7)
        boss.run(movement)
    }

    private func updateBossAttackMode(delta: TimeInterval) {
        bossModeElapsed += delta

        if bossModeElapsed >= bossModeDuration {
            switchBossAttackMode()
            return
        }

        guard session.elapsed >= bossWarningUntil else { return }
        bossAttackAccumulator += delta

        let interval: TimeInterval
        switch bossAttackMode {
        case .basic:
            interval = max(0.38, 0.86 - Double(level.id) * 0.06 - Double(bossPhase - 1) * 0.05)
        case .specialOne where level.id == 3:
            // 0.22 秒警示、0.9 秒照射與淡出完成後，至少保留 0.2 秒空檔。
            interval = 1.55
        case .specialTwo where level.id == 3:
            interval = max(1.8, 2.5 - Double(bossPhase - 1) * 0.2)
        case .specialOne where level.id == 5:
            interval = 2.4
        case .specialTwo where level.id == 5:
            interval = 4.8
        case .specialOne, .specialTwo:
            interval = max(1.8, 2.8 - Double(bossPhase - 1) * 0.25)
        }

        guard bossAttackAccumulator >= interval else { return }
        bossAttackAccumulator = 0

        switch bossAttackMode {
        case .basic:
            fireBossPattern()
        case .specialOne:
            fireBossSpecial()
        case .specialTwo:
            fireBossAlternateSpecial()
        }
    }

    private func switchBossAttackMode() {
        bossModeElapsed = 0
        bossModeDuration = Double.random(in: 5...10)
        bossAttackAccumulator = 0

        switch bossAttackMode {
        case .basic:
            bossAttackMode = Bool.random() ? .specialOne : .specialTwo
            let warningDuration: TimeInterval
            if level.id == 3 {
                warningDuration = bossAttackMode == .specialOne ? 0.55 : 1.4
            } else {
                warningDuration = 1.0
            }
            bossWarningUntil = session.elapsed + warningDuration
            showBossWarning(bossAttackMode == .specialOne ? specialName : alternateSpecialName)
        case .specialOne, .specialTwo:
            bossAttackMode = .basic
            bossWarningUntil = session.elapsed
        }
    }

    private func fireBossSpecial() {
        guard let boss else { return }

        switch level.id {
        case 1:
            fireSpiralNova(from: boss.position)
        case 2:
            fireCrimsonLanes(from: boss.position)
        case 3:
            fireRapidTrackingLaser(from: boss.position)
        case 4:
            deployVoidMines(from: boss.position)
        default:
            firePerimeterTrackingBarrage()
        }
    }

    private var specialName: String {
        switch level.id {
        case 1: "星旋爆發"
        case 2: "緋紅封鎖"
        case 3: "追跡脈衝雷射"
        case 4: "虛空追獵"
        default: "外環追跡陣"
        }
    }

    private var alternateSpecialName: String {
        switch level.id {
        case 1: "彗星追擊"
        case 2: "赤焰交叉"
        case 3: "廣域殲滅雷射"
        case 4: "暗影飛彈"
        default: "量子波動"
        }
    }

    private func fireBossAlternateSpecial() {
        guard let boss else { return }

        switch level.id {
        case 1:
            fireAimedBurst(from: boss.position, color: .systemTeal, count: 7)
        case 2:
            fireCrimsonCrossfire(from: boss.position)
        case 3:
            fireWideAreaLaser(from: boss.position)
        case 4:
            fireShadowFogMissiles(from: boss.position)
        default:
            fireQuantumWave(from: boss.position)
        }
    }

    private func fireAimedBurst(from origin: CGPoint, color: SKColor, count: Int) {
        let baseAngle = atan2(player.position.y - origin.y, player.position.x - origin.x)
        for index in 0..<count {
            let spread = (CGFloat(index) - CGFloat(count - 1) / 2) * 0.09
            let angle = baseAngle + spread
            let target = CGPoint(x: origin.x + cos(angle) * 700, y: origin.y + sin(angle) * 700)
            spawnHostileProjectile(from: origin, toward: target, duration: 2.3, radius: 6, color: color)
        }
    }

    private func fireCrimsonCrossfire(from origin: CGPoint) {
        let rowCount = 5 + bossPhase
        for index in 0..<rowCount {
            let y = 130 + CGFloat(index) * 82
            let leftTarget = CGPoint(x: size.width + 40, y: y + 100)
            let rightTarget = CGPoint(x: -40, y: y - 100)
            spawnHostileProjectile(
                from: CGPoint(x: -20, y: y),
                toward: leftTarget,
                duration: 3.0,
                radius: 7,
                color: .systemRed
            )
            spawnHostileProjectile(
                from: CGPoint(x: size.width + 20, y: y),
                toward: rightTarget,
                duration: 3.0,
                radius: 7,
                color: .systemOrange
            )
        }
        fireAimedBurst(from: origin, color: .systemRed, count: 3 + bossPhase)
    }

    private func fireLightningRain() {
        let columns = 6 + bossPhase
        let safeColumn = Int.random(in: 0..<columns)
        for column in 0..<columns where column != safeColumn {
            let x = (CGFloat(column) + 0.5) * size.width / CGFloat(columns)
            spawnHostileProjectile(
                from: CGPoint(x: x, y: size.height + 20),
                toward: CGPoint(x: x + CGFloat.random(in: -35...35), y: -40),
                duration: 1.8,
                radius: 7,
                color: .systemBlue
            )
        }
    }

    private func fireRapidTrackingLaser(from origin: CGPoint) {
        telegraphLaser(
            from: origin,
            toward: player.position,
            width: 10,
            warningDuration: 0.22,
            beamDuration: 0.9,
            color: .systemCyan
        )
    }

    private func fireWideAreaLaser(from origin: CGPoint) {
        telegraphLaser(
            from: origin,
            toward: player.position,
            width: 105 + CGFloat(bossPhase) * 14,
            warningDuration: 0.75,
            beamDuration: 1.7,
            color: .systemPurple
        )
    }

    private func telegraphLaser(
        from origin: CGPoint,
        toward target: CGPoint,
        width: CGFloat,
        warningDuration: TimeInterval,
        beamDuration: TimeInterval,
        color: SKColor
    ) {
        let geometry = laserGeometry(from: origin, toward: target)
        let warning = SKShapeNode(rectOf: CGSize(width: width, height: geometry.length), cornerRadius: width / 2)
        warning.name = "bossLaserWarning"
        warning.position = geometry.center
        warning.zRotation = geometry.angle - .pi / 2
        warning.fillColor = color.withAlphaComponent(0.13)
        warning.strokeColor = color.withAlphaComponent(0.9)
        warning.lineWidth = max(2, min(6, width * 0.08))
        warning.zPosition = 11
        world.addChild(warning)

        warning.run(.sequence([
            .repeat(.sequence([
                .fadeAlpha(to: 0.35, duration: 0.08),
                .fadeAlpha(to: 1, duration: 0.08)
            ]), count: max(1, Int(warningDuration / 0.16))),
            .run { [weak self, weak warning] in
                guard let self, !self.didFinish else { return }
                warning?.removeFromParent()
                self.spawnLaserBeam(
                    from: origin,
                    toward: target,
                    width: width,
                    duration: beamDuration,
                    color: color
                )
            }
        ]))
    }

    private func spawnLaserBeam(
        from origin: CGPoint,
        toward target: CGPoint,
        width: CGFloat,
        duration: TimeInterval,
        color: SKColor
    ) {
        let geometry = laserGeometry(from: origin, toward: target)
        let beam = SKShapeNode(rectOf: CGSize(width: width, height: geometry.length), cornerRadius: width / 2)
        beam.name = "enemyShot"
        beam.position = geometry.center
        beam.zRotation = geometry.angle - .pi / 2
        beam.fillColor = color.withAlphaComponent(width > 40 ? 0.72 : 0.9)
        beam.strokeColor = .white
        beam.lineWidth = width > 40 ? 5 : 2
        beam.glowWidth = width > 40 ? 24 : 12
        beam.zPosition = 12
        beam.userData = ["persistent": true]
        beam.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: width, height: geometry.length))
        beam.physicsBody?.categoryBitMask = PhysicsCategory.enemyShot
        beam.physicsBody?.contactTestBitMask = PhysicsCategory.player
        beam.physicsBody?.collisionBitMask = 0
        world.addChild(beam)
        beam.run(.sequence([
            .fadeIn(withDuration: 0.06),
            .wait(forDuration: duration),
            .fadeOut(withDuration: 0.18),
            .removeFromParent()
        ]))
    }

    private func laserGeometry(from origin: CGPoint, toward target: CGPoint) -> (center: CGPoint, angle: CGFloat, length: CGFloat) {
        let vector = CGVector(dx: target.x - origin.x, dy: target.y - origin.y)
        let magnitude = max(1, hypot(vector.dx, vector.dy))
        let length = size.height * 1.55
        let end = CGPoint(
            x: origin.x + vector.dx / magnitude * length,
            y: origin.y + vector.dy / magnitude * length
        )
        return (
            CGPoint(x: (origin.x + end.x) / 2, y: (origin.y + end.y) / 2),
            atan2(vector.dy, vector.dx),
            length
        )
    }

    private func fireShadowFogMissiles(from origin: CGPoint) {
        let count = 4 + bossPhase * 2
        let baseAngle = atan2(player.position.y - origin.y, player.position.x - origin.x)
        let spread: CGFloat = 1.15

        for index in 0..<count {
            let progress = count == 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
            let angle = baseAngle - spread / 2 + spread * progress
            let missile = makeHostileProjectile(radius: 9, color: .systemPurple)
            missile.position = origin
            missile.strokeColor = .systemIndigo
            missile.glowWidth = 9
            missile.zPosition = 8
            world.addChild(missile)

            let bounceCount = Int.random(in: 1...3)
            let movement = shadowMissileMovement(
                from: origin,
                direction: CGVector(dx: cos(angle), dy: sin(angle)),
                bounceCount: bounceCount
            )
            let becomeFog = SKAction.sequence([
                .wait(forDuration: 0.7),
                .group([
                    .fadeAlpha(to: 0.3, duration: 1.0),
                    .scale(to: 1.9, duration: 1.0),
                    .colorize(with: .darkGray, colorBlendFactor: 0.72, duration: 1.0)
                ])
            ])
            missile.run(.group([movement, becomeFog]))
        }
    }

    private func shadowMissileMovement(
        from origin: CGPoint,
        direction initialDirection: CGVector,
        bounceCount: Int
    ) -> SKAction {
        var position = origin
        var direction = initialDirection
        var actions: [SKAction] = []
        let speed: CGFloat = 105

        for _ in 0..<bounceCount {
            let impact = nextBoundaryImpact(from: position, direction: direction, inset: 12)
            let distance = hypot(impact.point.x - position.x, impact.point.y - position.y)
            actions.append(.move(to: impact.point, duration: TimeInterval(distance / speed)))
            actions.append(.scale(to: 2.05, duration: 0.08))
            actions.append(.scale(to: 1.9, duration: 0.08))
            position = impact.point
            direction = impact.reflectedDirection
        }

        let exitDistance = size.height * 1.7
        let exitPoint = CGPoint(
            x: position.x + direction.dx * exitDistance,
            y: position.y + direction.dy * exitDistance
        )
        actions.append(.move(to: exitPoint, duration: TimeInterval(exitDistance / speed)))
        actions.append(.removeFromParent())
        return .sequence(actions)
    }

    private func nextBoundaryImpact(
        from position: CGPoint,
        direction: CGVector,
        inset: CGFloat
    ) -> (point: CGPoint, reflectedDirection: CGVector) {
        let minX = inset
        let maxX = size.width - inset
        let minY = inset
        let maxY = size.height - inset
        var candidates: [(time: CGFloat, verticalWall: Bool)] = []

        if direction.dx > 0 {
            candidates.append(((maxX - position.x) / direction.dx, true))
        } else if direction.dx < 0 {
            candidates.append(((minX - position.x) / direction.dx, true))
        }
        if direction.dy > 0 {
            candidates.append(((maxY - position.y) / direction.dy, false))
        } else if direction.dy < 0 {
            candidates.append(((minY - position.y) / direction.dy, false))
        }

        let impact = candidates
            .filter { $0.time > 0.01 }
            .min { $0.time < $1.time } ?? (1, false)
        let point = CGPoint(
            x: position.x + direction.dx * impact.time,
            y: position.y + direction.dy * impact.time
        )
        let reflected = impact.verticalWall
            ? CGVector(dx: -direction.dx, dy: direction.dy)
            : CGVector(dx: direction.dx, dy: -direction.dy)
        return (point, reflected)
    }

    private func firePerimeterTrackingBarrage() {
        let shotCount = 15
        for index in 0..<shotCount {
            run(.sequence([
                .wait(forDuration: Double(index) * 0.1),
                .run { [weak self] in
                    guard let self, !self.didFinish else { return }
                    let origin = self.randomPerimeterPoint(offset: 24)
                    let target = self.player.position
                    self.telegraphPerimeterShot(from: origin, toward: target)
                }
            ]))
        }
    }

    private func randomPerimeterPoint(offset: CGFloat) -> CGPoint {
        switch Int.random(in: 0..<4) {
        case 0:
            return CGPoint(x: CGFloat.random(in: 0...size.width), y: size.height + offset)
        case 1:
            return CGPoint(x: size.width + offset, y: CGFloat.random(in: 0...size.height))
        case 2:
            return CGPoint(x: CGFloat.random(in: 0...size.width), y: -offset)
        default:
            return CGPoint(x: -offset, y: CGFloat.random(in: 0...size.height))
        }
    }

    private func telegraphPerimeterShot(from origin: CGPoint, toward target: CGPoint) {
        let vector = CGVector(dx: target.x - origin.x, dy: target.y - origin.y)
        let magnitude = max(1, hypot(vector.dx, vector.dy))
        let direction = CGVector(dx: vector.dx / magnitude, dy: vector.dy / magnitude)
        let end = CGPoint(
            x: origin.x + direction.dx * size.height * 1.7,
            y: origin.y + direction.dy * size.height * 1.7
        )
        let path = CGMutablePath()
        path.move(to: origin)
        path.addLine(to: end)

        let warning = SKShapeNode(path: path)
        warning.name = "bossProjectileWarning"
        warning.strokeColor = .systemYellow
        warning.lineWidth = 2
        warning.glowWidth = 7
        warning.alpha = 0.85
        warning.zPosition = 10
        world.addChild(warning)
        warning.run(.sequence([
            .repeat(.sequence([
                .fadeAlpha(to: 0.25, duration: 0.05),
                .fadeAlpha(to: 0.9, duration: 0.05)
            ]), count: 3),
            .run { [weak self] in
                self?.spawnHostileProjectile(
                    from: origin,
                    toward: target,
                    duration: 2.25,
                    radius: 6,
                    color: .systemYellow
                )
            },
            .fadeOut(withDuration: 0.08),
            .removeFromParent()
        ]))
    }

    private func fireQuantumWave(from origin: CGPoint) {
        let minimumCount = 32 + bossPhase * 3
        let maximumCount = 40 + bossPhase * 4
        let count = Int.random(in: minimumCount...maximumCount)
        let emissionDuration = TimeInterval.random(in: 1.05...1.4)
        let decelerationDuration = TimeInterval.random(in: 0.14...0.22)
        let cruiseDuration = emissionDuration - decelerationDuration
        let baseSpeed = CGFloat.random(in: 105...130)
        let speedAmplitude = CGFloat.random(in: 35...52)
        let angularFrequency = CGFloat(Int.random(in: 4...7))
        let waveSpeed = CGFloat.random(in: 130...165)
        let waveDistance = hypot(size.width, size.height) * CGFloat.random(in: 1.65...1.8)
        let phaseOffset = CGFloat.random(in: 0...(CGFloat.pi * 2))

        for index in 0..<count {
            let theta = CGFloat(index) / CGFloat(count) * .pi * 2 + phaseOffset
            let direction = CGVector(dx: cos(theta), dy: sin(theta))
            let initialSpeed = baseSpeed + speedAmplitude * cos(angularFrequency * theta)
            let cruise = SKAction.moveBy(
                x: direction.dx * initialSpeed * cruiseDuration,
                y: direction.dy * initialSpeed * cruiseDuration,
                duration: cruiseDuration
            )
            cruise.timingMode = .linear
            let decelerate = SKAction.moveBy(
                x: direction.dx * initialSpeed * CGFloat(decelerationDuration) / 2,
                y: direction.dy * initialSpeed * CGFloat(decelerationDuration) / 2,
                duration: decelerationDuration
            )
            decelerate.timingMode = .easeOut

            let particle = makeHostileProjectile(radius: 5, color: .systemPink)
            particle.position = origin
            particle.strokeColor = .systemYellow
            particle.glowWidth = 7
            world.addChild(particle)

            let waveMovement = SKAction.moveBy(
                x: direction.dx * waveDistance,
                y: direction.dy * waveDistance,
                duration: TimeInterval(waveDistance / waveSpeed)
            )
            waveMovement.timingMode = .linear
            particle.run(.sequence([
                cruise,
                decelerate,
                .wait(forDuration: 1.0),
                waveMovement,
                .removeFromParent()
            ]))
        }
    }

    private func fireDoomsdayRing(from origin: CGPoint) {
        let count = 20 + bossPhase * 4
        let openingAngle = atan2(player.position.y - origin.y, player.position.x - origin.x)
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            let difference = abs(atan2(sin(angle - openingAngle), cos(angle - openingAngle)))
            guard difference > 0.22 else { continue }
            let target = CGPoint(x: origin.x + cos(angle) * 720, y: origin.y + sin(angle) * 720)
            spawnHostileProjectile(from: origin, toward: target, duration: 3.2, radius: 7, color: .systemYellow)
        }
    }

    private func fireSpiralNova(from origin: CGPoint) {
        let count = 18 + bossPhase * 4
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2 + CGFloat(bossPhase) * 0.2
            let target = CGPoint(x: origin.x + cos(angle) * 700, y: origin.y + sin(angle) * 700)
            spawnHostileProjectile(from: origin, toward: target, duration: 3.8, radius: 5, color: .cyan)
        }
    }

    private func fireCrimsonLanes(from origin: CGPoint) {
        let laneCount = 3 + bossPhase
        let gap = Int.random(in: 0..<laneCount)
        for lane in 0..<laneCount where lane != gap {
            let x = (CGFloat(lane) + 0.5) * size.width / CGFloat(laneCount)
            let warning = SKShapeNode(rectOf: CGSize(width: 22, height: size.height))
            warning.fillColor = .systemRed.withAlphaComponent(0.16)
            warning.strokeColor = .systemRed
            warning.position = CGPoint(x: x, y: size.height / 2)
            warning.zPosition = 10
            world.addChild(warning)
            warning.run(.sequence([
                .wait(forDuration: 0.65),
                .run { [weak self] in
                    guard let self else { return }
                    for offset in 0..<9 {
                        let start = CGPoint(x: x, y: self.size.height + CGFloat(offset) * 32)
                        self.spawnHostileProjectile(
                            from: start,
                            toward: CGPoint(x: x, y: -40),
                            duration: 2.0,
                            radius: 8,
                            color: .systemRed
                        )
                    }
                },
                .fadeOut(withDuration: 0.15),
                .removeFromParent()
            ]))
        }
        fireEnemyShot(from: origin, toward: player.position)
    }

    private func fireThunderCage(from origin: CGPoint) {
        let rows = 4 + bossPhase
        for index in 0..<rows {
            let y = 145 + CGFloat(index) * 72
            spawnHostileProjectile(
                from: CGPoint(x: -20, y: y),
                toward: CGPoint(x: size.width + 30, y: y + CGFloat.random(in: -30...30)),
                duration: 3.3,
                radius: 6,
                color: .systemPurple
            )
            spawnHostileProjectile(
                from: CGPoint(x: size.width + 20, y: y + 34),
                toward: CGPoint(x: -30, y: y + CGFloat.random(in: -30...30)),
                duration: 3.3,
                radius: 6,
                color: .systemBlue
            )
        }
        for delayIndex in 0..<(2 + bossPhase) {
            run(.sequence([
                .wait(forDuration: Double(delayIndex) * 0.32),
                .run { [weak self] in
                    guard let self else { return }
                    self.fireEnemyShot(from: origin, toward: self.player.position)
                }
            ]))
        }
    }

    private func deployVoidMines(from origin: CGPoint) {
        let mineCount = 4 + bossPhase
        for index in 0..<mineCount {
            let mine = makeHostileProjectile(radius: 11, color: .systemGreen)
            mine.position = origin
            mine.setScale(0.35)
            world.addChild(mine)
            let destination = CGPoint(
                x: (CGFloat(index) + 0.5) * size.width / CGFloat(mineCount),
                y: CGFloat.random(in: 260...620)
            )
            mine.run(.sequence([
                .group([
                    .move(to: destination, duration: 0.7),
                    .scale(to: 1, duration: 0.7)
                ]),
                .wait(forDuration: 0.65 + Double(index) * 0.32),
                .run { [weak self, weak mine] in
                    guard let self, let mine, mine.parent != nil else { return }
                    let target = self.player.position
                    let vector = CGVector(dx: target.x - mine.position.x, dy: target.y - mine.position.y)
                    let length = max(1, hypot(vector.dx, vector.dy))
                    let end = CGPoint(
                        x: mine.position.x + vector.dx / length * self.size.height,
                        y: mine.position.y + vector.dy / length * self.size.height
                    )
                    mine.run(.sequence([
                        .move(to: end, duration: 2.0),
                        .removeFromParent()
                    ]))
                }
            ]))
        }
    }

    private func fireDoomsdayBarrage(from origin: CGPoint) {
        let waves = 3 + bossPhase
        for wave in 0..<waves {
            run(.sequence([
                .wait(forDuration: Double(wave) * 0.24),
                .run { [weak self] in
                    guard let self else { return }
                    let count = 13
                    let sweepOffset = CGFloat(wave % 2) * 0.16
                    for index in 0..<count {
                        let angle = .pi * (0.18 + sweepOffset + CGFloat(index) / CGFloat(count - 1) * 0.64)
                        let target = CGPoint(x: origin.x + cos(angle) * 650, y: origin.y - sin(angle) * 850)
                        self.spawnHostileProjectile(
                            from: origin,
                            toward: target,
                            duration: 2.7,
                            radius: 6,
                            color: wave.isMultiple(of: 2) ? .systemYellow : .systemPink
                        )
                    }
                }
            ]))
        }
    }

    private func spawnHostileProjectile(
        from start: CGPoint,
        toward target: CGPoint,
        duration: TimeInterval,
        radius: CGFloat,
        color: SKColor
    ) {
        let shot = makeHostileProjectile(radius: radius, color: color)
        shot.position = start
        world.addChild(shot)
        let vector = CGVector(dx: target.x - start.x, dy: target.y - start.y)
        let length = max(1, hypot(vector.dx, vector.dy))
        let distance = size.height * 1.5
        let end = CGPoint(x: start.x + vector.dx / length * distance, y: start.y + vector.dy / length * distance)
        shot.run(.sequence([.move(to: end, duration: duration), .removeFromParent()]))
    }

    private func makeHostileProjectile(radius: CGFloat, color: SKColor) -> SKShapeNode {
        let shot = SKShapeNode(circleOfRadius: radius)
        shot.name = "enemyShot"
        shot.fillColor = color
        shot.strokeColor = .white
        shot.glowWidth = radius
        shot.zPosition = 7
        shot.physicsBody = SKPhysicsBody(circleOfRadius: radius)
        shot.physicsBody?.categoryBitMask = PhysicsCategory.enemyShot
        shot.physicsBody?.contactTestBitMask = PhysicsCategory.player
        shot.physicsBody?.collisionBitMask = 0
        return shot
    }

    private func beginBossPhaseTransition(to phase: Int, at threshold: Int) {
        guard let boss else { return }
        bossPhase = phase
        bossHP = threshold
        boss.userData?["hp"] = threshold
        session.bossHealth = threshold
        session.bossPhase = phase
        session.bossInvulnerable = true
        bossInvulnerableUntil = session.elapsed + 2.2
        bossAttackMode = .basic
        bossAttackAccumulator = 0
        bossModeElapsed = 0
        bossModeDuration = Double.random(in: 5...10)
        bossWarningUntil = bossInvulnerableUntil

        clearEnemyProjectiles()
        spawnBossPhasePickups(at: boss.position)
        boss.removeAllActions()
        boss.run(.sequence([
            .group([
                .scale(to: 1.18, duration: 0.18),
                .colorize(with: .white, colorBlendFactor: 0.8, duration: 0.18)
            ]),
            .repeat(.sequence([
                .fadeAlpha(to: 0.35, duration: 0.12),
                .fadeAlpha(to: 1, duration: 0.12)
            ]), count: 6),
            .group([
                .scale(to: 1, duration: 0.18),
                .colorize(withColorBlendFactor: 0, duration: 0.18)
            ])
        ]))

        let shield = SKShapeNode(circleOfRadius: 92)
        shield.strokeColor = .white
        shield.lineWidth = 5
        shield.glowWidth = 14
        shield.fillColor = level.accent.skColor.withAlphaComponent(0.14)
        shield.position = boss.position
        shield.zPosition = 13
        world.addChild(shield)
        shield.run(.sequence([
            .repeat(.sequence([
                .scale(to: 1.12, duration: 0.18),
                .scale(to: 0.95, duration: 0.18)
            ]), count: 5),
            .fadeOut(withDuration: 0.15),
            .removeFromParent()
        ]))

        showBossCallout("PHASE \(phase)・\(ultimateName) 發動")
        run(.sequence([
            .wait(forDuration: 0.65),
            .run { [weak self] in self?.fireBossUltimate() }
        ]))
    }

    private var ultimateName: String {
        switch level.id {
        case 1: "星核超新星"
        case 2: "血色天幕"
        case 3: "五重殲滅雷射"
        case 4: "虛空吞噬"
        default: "終焉審判"
        }
    }

    private func fireBossUltimate() {
        if level.id == 3 {
            fireLevelThreeLaserUltimate()
            return
        }

        fireBossSpecial()
        run(.sequence([
            .wait(forDuration: 0.55),
            .run { [weak self] in self?.fireBossAlternateSpecial() }
        ]))
    }

    private func fireLevelThreeLaserUltimate() {
        guard let boss else { return }
        let origin = boss.position
        let bottomCenter = CGPoint(x: size.width / 2, y: -80)
        let warningDuration: TimeInterval = 0.85

        telegraphLaser(
            from: origin,
            toward: bottomCenter,
            width: 125 + CGFloat(bossPhase) * 16,
            warningDuration: warningDuration,
            beamDuration: 1.9,
            color: .systemPurple
        )

        // 以中央廣域雷射為軸，左右各兩束脈衝雷射同步、對稱展開。
        for offset in [-300.0, -150.0, 150.0, 300.0] {
            telegraphLaser(
                from: origin,
                toward: CGPoint(x: bottomCenter.x + CGFloat(offset), y: bottomCenter.y),
                width: 12,
                warningDuration: warningDuration,
                beamDuration: 1.15,
                color: .systemCyan
            )
        }
    }

    private func showBossWarning(_ attackName: String) {
        let panel = SKShapeNode(rectOf: CGSize(width: 230, height: 38), cornerRadius: 12)
        panel.fillColor = .black.withAlphaComponent(0.72)
        panel.strokeColor = .systemOrange
        panel.lineWidth = 2
        panel.position = CGPoint(x: size.width / 2, y: size.height * 0.67)
        panel.zPosition = 28

        let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        label.text = "⚠ 即將發動：\(attackName)"
        label.fontSize = 15
        label.fontColor = .systemYellow
        label.verticalAlignmentMode = .center
        panel.addChild(label)
        world.addChild(panel)
        panel.run(.sequence([
            .repeat(.sequence([
                .fadeAlpha(to: 0.35, duration: 0.12),
                .fadeAlpha(to: 1, duration: 0.12)
            ]), count: 3),
            .wait(forDuration: 0.15),
            .fadeOut(withDuration: 0.15),
            .removeFromParent()
        ]))
    }

    private func showBossCallout(_ text: String) {
        let label = SKLabelNode(fontNamed: "AvenirNext-Bold")
        label.text = text
        label.fontSize = 22
        label.fontColor = .white
        label.position = CGPoint(x: size.width / 2, y: size.height * 0.58)
        label.zPosition = 30
        world.addChild(label)
        label.run(.sequence([
            .group([.fadeIn(withDuration: 0.15), .scale(to: 1.08, duration: 0.15)]),
            .wait(forDuration: 0.9),
            .fadeOut(withDuration: 0.25),
            .removeFromParent()
        ]))
    }

    private func damage(node: SKNode, amount: Int, chargesSpecial: Bool = true) {
        guard !didFinish, session.state == .playing else { return }
        guard var hp = node.userData?["hp"] as? Int else { return }
        let isBoss = node === boss

        if isBoss, session.elapsed < bossInvulnerableUntil {
            return
        }

        let originalHP = hp
        hp -= amount

        if isBoss {
            let phaseTwoThreshold = level.bossHealth * 2 / 3
            let phaseThreeThreshold = level.bossHealth / 3

            if bossPhase == 1, hp <= phaseTwoThreshold {
                chargeSpecial(by: originalHP - phaseTwoThreshold, enabled: chargesSpecial)
                beginBossPhaseTransition(to: 2, at: phaseTwoThreshold)
                return
            }

            if bossPhase == 2, hp <= phaseThreeThreshold {
                chargeSpecial(by: originalHP - phaseThreeThreshold, enabled: chargesSpecial)
                beginBossPhaseTransition(to: 3, at: phaseThreeThreshold)
                return
            }
        }

        chargeSpecial(by: min(originalHP, amount), enabled: chargesSpecial)
        node.userData?["hp"] = hp
        node.run(.sequence([.fadeAlpha(to: 0.35, duration: 0.04), .fadeAlpha(to: 1, duration: 0.06)]))

        if isBoss {
            bossHP = hp
            session.bossHealth = max(0, hp)
        }

        if hp <= 0 {
            explode(at: node.position, color: (node as? SKShapeNode)?.fillColor ?? .white)
            node.removeFromParent()
            session.score += isBoss ? level.id * 2_000 : 100 * level.id
            if isBoss {
                boss = nil
                session.bossInvulnerable = false
                endBattle(victory: true)
            } else if Int.random(in: 0..<5) == 0 {
                spawnPickup(at: node.position)
            }
        }
    }

    private func chargeSpecial(by damage: Int, enabled: Bool) {
        guard enabled, damage > 0 else { return }
        let maximum = Double(ship.specialDamageRequirement)
        session.energy = min(maximum, session.energy + Double(damage))
    }

    private func spawnPickup(at point: CGPoint, kind requestedKind: String? = nil) {
        let kind = requestedKind ?? ["power", "power", "repair", "shield"].randomElement() ?? "power"
        let pickup = SKShapeNode(circleOfRadius: 12)
        pickup.name = "pickup"
        pickup.userData = ["kind": kind]
        switch kind {
        case "repair": pickup.fillColor = .systemPink
        case "shield": pickup.fillColor = .systemBlue
        default: pickup.fillColor = .systemGreen
        }
        pickup.strokeColor = .white
        pickup.glowWidth = 7
        pickup.position = point
        pickup.zPosition = 7
        pickup.physicsBody = SKPhysicsBody(circleOfRadius: 12)
        pickup.physicsBody?.categoryBitMask = PhysicsCategory.pickup
        pickup.physicsBody?.contactTestBitMask = PhysicsCategory.player
        pickup.physicsBody?.collisionBitMask = 0
        world.addChild(pickup)
        pickup.run(.sequence([.moveBy(x: 0, y: -size.height, duration: 5), .removeFromParent()]))
    }

    private func spawnSupplyDrop() {
        spawnPickup(at: CGPoint(x: size.width * 0.35, y: size.height + 20), kind: "repair")
        spawnPickup(at: CGPoint(x: size.width * 0.65, y: size.height + 60), kind: "shield")
    }

    private func spawnBossPhasePickups(at point: CGPoint) {
        for index in 0..<3 {
            let offset = CGFloat(index - 1) * 46
            let dropPoint = CGPoint(
                x: max(20, min(size.width - 20, point.x + offset)),
                y: point.y - CGFloat(index) * 12
            )
            spawnPickup(at: dropPoint)
        }
    }

    private func showWaveCue(_ text: String) {
        let label = SKLabelNode(fontNamed: "AvenirNext-Bold")
        label.text = text
        label.fontSize = 18
        label.fontColor = .white
        label.position = CGPoint(x: size.width / 2, y: size.height * 0.62)
        label.zPosition = 29
        label.alpha = 0
        world.addChild(label)
        label.run(.sequence([
            .fadeIn(withDuration: 0.18),
            .wait(forDuration: 1.15),
            .fadeOut(withDuration: 0.25),
            .removeFromParent()
        ]))
    }

    private func clearEnemyProjectiles() {
        world.enumerateChildNodes(withName: "//enemyShot") { node, _ in
            node.physicsBody = nil
            node.removeAllActions()
            node.removeFromParent()
        }
    }

    private func absorbProjectileWithAegisBarrier(_ projectile: SKNode?) -> Bool {
        guard ship == .aegis, session.elapsed < aegisBarrierUntil else { return false }

        aegisBarrierBlockedDamage = true
        projectile?.physicsBody = nil
        projectile?.removeAllActions()
        projectile?.removeFromParent()
        player.childNode(withName: "playerEnergyBarrier")?.run(.sequence([
            .fadeAlpha(to: 0.35, duration: 0.04),
            .fadeAlpha(to: 1, duration: 0.08)
        ]))
        return true
    }

    private func hitPlayer() {
        guard !didFinish, session.state == .playing else { return }

        if ship == .aegis, session.elapsed < aegisBarrierUntil {
            aegisBarrierBlockedDamage = true
            return
        }

        guard session.elapsed >= invulnerableUntil else { return }
        invulnerableUntil = session.elapsed + 1.1

        if session.shieldCharges > 0 {
            session.shieldCharges -= 1
            showBossCallout("護盾抵擋傷害")
            return
        }

        session.health -= 1
        session.hitsTaken += 1
        player.run(.sequence([
            .fadeAlpha(to: 0.15, duration: 0.1),
            .fadeAlpha(to: 1, duration: 0.1),
            .fadeAlpha(to: 0.15, duration: 0.1),
            .fadeAlpha(to: 1, duration: 0.1)
        ]))
        if session.health <= 0 {
            endBattle(victory: false)
        }
    }

    private func explode(at point: CGPoint, color: SKColor) {
        for index in 0..<10 {
            let spark = SKShapeNode(circleOfRadius: 2.5)
            spark.fillColor = color
            spark.strokeColor = .clear
            spark.position = point
            spark.zPosition = 12
            world.addChild(spark)
            let angle = CGFloat(index) / 10 * CGFloat.pi * 2
            spark.run(.sequence([
                .group([
                    .moveBy(x: cos(angle) * 42, y: sin(angle) * 42, duration: 0.28),
                    .fadeOut(withDuration: 0.28)
                ]),
                .removeFromParent()
            ]))
        }
    }

    private func endBattle(victory: Bool) {
        guard !didFinish else { return }
        didFinish = true
        removeAllActions()
        clearEnemyProjectiles()

        world.enumerateChildNodes(withName: "//*") { node, _ in
            node.physicsBody = nil
            if ["enemy", "boss", "playerShot", "pickup"].contains(node.name ?? "") {
                node.removeAllActions()
            }
        }
        player.removeAllActions()
        session.bossVisible = false
        session.bossInvulnerable = false
        _ = session.finalize(victory: victory, level: level.id)
    }

    // Internal hooks keep SpriteKit behavior testable without exposing it to the app UI.
    func testingSpawnBoss() -> SKNode {
        if boss == nil { spawnBoss() }
        return boss ?? SKNode()
    }

    func testingShouldRemoveEnemyOnPlayerContact(_ node: SKNode) -> Bool {
        node !== boss
    }

    func testingEndBattle(victory: Bool) {
        endBattle(victory: victory)
    }

    func testingApplyPlayerHit() {
        hitPlayer()
    }

    func testingAddEnemyProjectile() {
        let projectile = makeHostileProjectile(radius: 5, color: .red)
        world.addChild(projectile)
    }

    var testingEnemyProjectileCount: Int {
        var count = 0
        world.enumerateChildNodes(withName: "//enemyShot") { _, _ in count += 1 }
        return count
    }

    func testingClearEnemyProjectiles() {
        clearEnemyProjectiles()
    }
}

private extension Color {
    var skColor: SKColor {
        SKColor(cgColor: resolve(in: EnvironmentValues()).cgColor)
    }
}
