import SpriteKit
import SwiftUI

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

    private let world = SKNode()
    private let player = SKShapeNode()
    private var lastUpdateTime = 0.0
    private var spawnAccumulator = 0.0
    private var shotAccumulator = 0.0
    private var bossShotAccumulator = 0.0
    private var boss: SKShapeNode?
    private var bossHP = 0
    private var didFinish = false
    private var invulnerableUntil = 0.0

    init(size: CGSize, level: LevelDefinition, ship: ShipID, upgradeLevel: Int, session: GameSession) {
        self.level = level
        self.ship = ship
        self.upgradeLevel = upgradeLevel
        self.session = session
        super.init(size: size)
        anchorPoint = .zero
        backgroundColor = SKColor(red: 0.01, green: 0.015, blue: 0.07, alpha: 1)
        physicsWorld.gravity = .zero
        physicsWorld.contactDelegate = self
        addChild(world)
        createStarfield()
        createPlayer()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func movePlayer(normalizedX: CGFloat, normalizedY: CGFloat) {
        guard session.state == .playing else { return }
        let x = max(28, min(size.width - 28, normalizedX * size.width))
        let y = max(80, min(size.height - 80, (1 - normalizedY) * size.height))
        player.run(.move(to: CGPoint(x: x, y: y), duration: 0.06))
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
        guard session.state == .playing, session.energy >= 1 else { return }
        session.energy = 0
        enumerateChildNodes(withName: "enemyShot") { node, _ in node.removeFromParent() }
        world.children.filter { $0.name == "enemy" || $0.name == "boss" }.forEach { node in
            self.damage(node: node, amount: 18 + self.upgradeLevel * 4)
        }
        let flash = SKShapeNode(circleOfRadius: size.width * 0.7)
        flash.fillColor = .cyan.withAlphaComponent(0.22)
        flash.strokeColor = .white
        flash.position = player.position
        flash.zPosition = 20
        addChild(flash)
        flash.run(.sequence([.scale(to: 1.5, duration: 0.25), .fadeOut(withDuration: 0.25), .removeFromParent()]))
    }

    override func update(_ currentTime: TimeInterval) {
        guard session.state == .playing, !didFinish else { return }
        let delta = lastUpdateTime == 0 ? 0 : min(1.0 / 20.0, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime
        session.elapsed += delta
        spawnAccumulator += delta
        shotAccumulator += delta

        scrollStars(delta: delta)

        if boss == nil && session.elapsed >= level.duration {
            spawnBoss()
        } else if boss == nil && spawnAccumulator >= level.enemyRate {
            spawnAccumulator = 0
            spawnEnemy()
        }

        let fireRate = ship == .tempest ? 0.14 : (ship == .aegis ? 0.24 : 0.18)
        if shotAccumulator >= fireRate {
            shotAccumulator = 0
            firePlayerShots()
        }

        if boss != nil {
            bossShotAccumulator += delta
            if bossShotAccumulator >= max(0.38, 0.85 - Double(level.id) * 0.07) {
                bossShotAccumulator = 0
                fireBossPattern()
            }
        }

        if player.position.y < 0 || session.health <= 0 {
            endBattle(victory: false)
        }
    }

    func didBegin(_ contact: SKPhysicsContact) {
        let pair = contact.bodyA.categoryBitMask | contact.bodyB.categoryBitMask
        let nodes = [contact.bodyA.node, contact.bodyB.node].compactMap { $0 }

        if pair == PhysicsCategory.enemy | PhysicsCategory.playerShot {
            guard let enemy = nodes.first(where: { $0.physicsBody?.categoryBitMask == PhysicsCategory.enemy }),
                  let shot = nodes.first(where: { $0.physicsBody?.categoryBitMask == PhysicsCategory.playerShot }) else { return }
            shot.removeFromParent()
            damage(node: enemy, amount: 2 + upgradeLevel)
        } else if pair == PhysicsCategory.player | PhysicsCategory.enemyShot ||
                    pair == PhysicsCategory.player | PhysicsCategory.enemy {
            nodes.first(where: { $0.physicsBody?.categoryBitMask != PhysicsCategory.player })?.removeFromParent()
            hitPlayer()
        } else if pair == PhysicsCategory.player | PhysicsCategory.pickup {
            nodes.first(where: { $0.physicsBody?.categoryBitMask == PhysicsCategory.pickup })?.removeFromParent()
            session.power = min(3, session.power + 1)
            session.energy = min(1, session.energy + 0.22)
        }
    }

    private func createStarfield() {
        for index in 0..<80 {
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
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 27))
        path.addLine(to: CGPoint(x: -22, y: -20))
        path.addLine(to: CGPoint(x: 0, y: -10))
        path.addLine(to: CGPoint(x: 22, y: -20))
        path.closeSubpath()
        player.path = path
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
    }

    private func firePlayerShots() {
        let count = session.power == 1 ? 1 : (session.power == 2 ? 2 : 3)
        for index in 0..<count {
            let shot = SKShapeNode(rectOf: CGSize(width: ship == .aegis ? 5 : 3, height: 18), cornerRadius: 2)
            shot.fillColor = ship.color.skColor
            shot.strokeColor = .white
            shot.glowWidth = 4
            let spacing: CGFloat = 13
            shot.position = CGPoint(x: player.position.x + (CGFloat(index) - CGFloat(count - 1) / 2) * spacing, y: player.position.y + 30)
            shot.zPosition = 5
            shot.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 5, height: 18))
            shot.physicsBody?.categoryBitMask = PhysicsCategory.playerShot
            shot.physicsBody?.contactTestBitMask = PhysicsCategory.enemy
            shot.physicsBody?.collisionBitMask = 0
            world.addChild(shot)
            shot.run(.sequence([.moveBy(x: 0, y: size.height + 40, duration: 1.0), .removeFromParent()]))
        }
    }

    private func spawnEnemy() {
        let enemy = SKShapeNode(path: enemyPath())
        enemy.name = "enemy"
        enemy.fillColor = level.accent.skColor
        enemy.strokeColor = .white
        enemy.glowWidth = 4
        enemy.position = CGPoint(x: .random(in: 35...(size.width - 35)), y: size.height + 35)
        enemy.zPosition = 6
        enemy.userData = ["hp": 4 + level.id * 2]
        enemy.physicsBody = SKPhysicsBody(circleOfRadius: 18)
        enemy.physicsBody?.categoryBitMask = PhysicsCategory.enemy
        enemy.physicsBody?.contactTestBitMask = PhysicsCategory.player | PhysicsCategory.playerShot
        enemy.physicsBody?.collisionBitMask = 0
        world.addChild(enemy)

        let targetX = CGFloat.random(in: 30...(size.width - 30))
        let duration = max(2.2, 5.0 - Double(level.id) * 0.35)
        enemy.run(.sequence([
            .move(to: CGPoint(x: targetX, y: -40), duration: duration),
            .removeFromParent()
        ]))

        let wait = SKAction.wait(forDuration: 0.8)
        let fire = SKAction.run { [weak self, weak enemy] in
            guard let self, let enemy, enemy.parent != nil else { return }
            self.fireEnemyShot(from: enemy.position, toward: self.player.position)
        }
        enemy.run(.repeat(.sequence([wait, fire]), count: 4))
    }

    private func enemyPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -20))
        path.addLine(to: CGPoint(x: -20, y: 15))
        path.addLine(to: CGPoint(x: 0, y: 8))
        path.addLine(to: CGPoint(x: 20, y: 15))
        path.closeSubpath()
        return path
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
        let shape = SKShapeNode(rectOf: CGSize(width: 126, height: 70), cornerRadius: 24)
        shape.name = "boss"
        shape.fillColor = level.accent.skColor
        shape.strokeColor = .white
        shape.lineWidth = 3
        shape.glowWidth = 12
        shape.position = CGPoint(x: size.width / 2, y: size.height + 70)
        shape.zPosition = 9
        bossHP = level.bossHealth
        shape.userData = ["hp": bossHP]
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

    private func fireBossPattern() {
        guard let boss else { return }
        let bulletCount = 5 + level.id * 2
        for index in 0..<bulletCount {
            let angle = CGFloat.pi * 0.22 + CGFloat(index) / CGFloat(bulletCount - 1) * CGFloat.pi * 0.56
            let target = CGPoint(x: boss.position.x + cos(angle) * 500, y: boss.position.y - sin(angle) * 800)
            fireEnemyShot(from: boss.position, toward: target)
        }
        let movement = SKAction.moveTo(x: .random(in: 80...(size.width - 80)), duration: 0.7)
        boss.run(movement)
    }

    private func damage(node: SKNode, amount: Int) {
        guard var hp = node.userData?["hp"] as? Int else { return }
        hp -= amount
        node.userData?["hp"] = hp
        node.run(.sequence([.fadeAlpha(to: 0.35, duration: 0.04), .fadeAlpha(to: 1, duration: 0.06)]))

        if node === boss {
            bossHP = hp
            session.bossHealth = max(0, hp)
        }

        if hp <= 0 {
            explode(at: node.position, color: (node as? SKShapeNode)?.fillColor ?? .white)
            node.removeFromParent()
            session.score += node === boss ? level.id * 2_000 : 100 * level.id
            session.energy = min(1, session.energy + (node === boss ? 0.3 : 0.06))
            if node === boss {
                boss = nil
                endBattle(victory: true)
            } else if Int.random(in: 0..<5) == 0 {
                spawnPickup(at: node.position)
            }
        }
    }

    private func spawnPickup(at point: CGPoint) {
        let pickup = SKShapeNode(circleOfRadius: 11)
        pickup.name = "pickup"
        pickup.fillColor = .systemGreen
        pickup.strokeColor = .white
        pickup.glowWidth = 7
        pickup.position = point
        pickup.zPosition = 7
        pickup.physicsBody = SKPhysicsBody(circleOfRadius: 11)
        pickup.physicsBody?.categoryBitMask = PhysicsCategory.pickup
        pickup.physicsBody?.contactTestBitMask = PhysicsCategory.player
        pickup.physicsBody?.collisionBitMask = 0
        world.addChild(pickup)
        pickup.run(.sequence([.moveBy(x: 0, y: -size.height, duration: 5), .removeFromParent()]))
    }

    private func hitPlayer() {
        guard session.elapsed >= invulnerableUntil else { return }
        invulnerableUntil = session.elapsed + 1.1
        session.health -= 1
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
        session.state = victory ? .victory : .defeat
        session.bossVisible = false
    }
}

private extension Color {
    var skColor: SKColor {
        SKColor(cgColor: resolve(in: EnvironmentValues()).cgColor) ?? .white
    }
}
