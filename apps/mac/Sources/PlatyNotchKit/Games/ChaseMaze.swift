import Foundation

/// What a maze tile is.
public enum ChaseTile: Equatable, Sendable {
    case wall, dot, pellet, empty, door, house
}

/// Platy Chase's maze: 28 × 31 tiles, our own creek layout (not the arcade's). The rules
/// fix only a few things: 240 dots and 4 power pellets (one in each corner region), a
/// house with a door in the middle, a wrap-around tunnel through the house's row (14),
/// and the player starting below the house. Everything else (the lanes, the side
/// pockets, the long banks along the bottom) is PlatyNotch's own. Positions are in
/// tiles; a tile's centre is at +0.5.
public enum ChaseMaze {
    public static let width = 28
    public static let height = 31
    public static let tunnelRow = 14

    /// `#` bank (wall), `.` dot, `o` power pellet, space empty channel, `-` house door,
    /// `_` inside the house. Left–right symmetric; designed for PlatyNotch.
    public static let layout: [String] = [
        "############################",
        "#....###............###....#",
        "#o##.###.##.####.##.###.##o#",
        "#.##.###....####....###.##.#",
        "#........##.####.##........#",
        "#.##.######.####.######.##.#",
        "#.##.#####........#####.##.#",
        "#..........######..........#",
        "#.#####.##.######.##.#####.#",
        "#.#####.##.######.##.#####.#",
        "#...........####...........#",
        "#### ## ###      ### ## ####",
        "#### ## #####--##### ## ####",
        "#### ## ###______### ## ####",
        "     ## ###______### ##     ",
        "#### ## ###______### ## ####",
        "#    ## ############ ##    #",
        "# ## ## ############ ## ## #",
        "# ## ##              ## ## #",
        "#    ## ############ ##    #",
        "# ##### ############ ##### #",
        "#..........................#",
        "#.###.####.######.####.###.#",
        "#.###.####.######.####.###.#",
        "#............  ............#",
        "#.###.##.##########.##.###.#",
        "#o###.##.##########.##.###o#",
        "#..........................#",
        "#.###.################.###.#",
        "#.....################.....#",
        "############################",
    ]

    /// The parsed layout, rows top first.
    public static let tiles: [[ChaseTile]] = layout.map { row in
        row.map { ch -> ChaseTile in
            switch ch {
            case "#": .wall
            case ".": .dot
            case "o": .pellet
            case "-": .door
            case "_": .house
            default: .empty
            }
        }
    }

    /// The player's start: between columns 13 and 14 on the channel below the house,
    /// facing left.
    public static let playerStart = (x: 14.0, y: 24.5)
    /// Just above the door: the direct chaser's start and where every chaser leaves from.
    public static let doorTop = (x: 14.0, y: 11.5)
    /// Inside the house: the ambusher in the middle, the flanker left, the shy one right.
    public static let houseCentre = (x: 14.0, y: 14.5)
    public static let houseLeft = (x: 12.0, y: 14.5)
    public static let houseRight = (x: 16.0, y: 14.5)
    /// Where bonus items appear: on the channel just under the house.
    public static let bonusSpot = (x: 14.0, y: 18.5)

    /// Each chaser's scatter corner: a tile outside the maze beyond its home corner
    /// (direct chaser top right, ambusher top left, flanker bottom right, shy bottom left).
    public static func scatterCorner(_ kind: ChaserKind) -> Point {
        switch kind {
        case .chaser: Point(x: width - 3, y: -3)
        case .ambusher: Point(x: 2, y: -3)
        case .flanker: Point(x: width - 1, y: height + 1)
        case .shy: Point(x: 0, y: height + 1)
        }
    }

    /// Tiles where chasers may not turn upwards in scatter or chase (the classic rule's
    /// two pairs, placed for this maze): on the lane just above the house, the junctions
    /// with a way up nearest the house's channel; on the player's channel, the junctions
    /// with a way up nearest the start.
    public static let noUpTiles: Set<Point> = [Point(x: 10, y: 10), Point(x: width - 11, y: 10),
                                               Point(x: 10, y: 24), Point(x: width - 11, y: 24)]

    public static func tile(_ x: Int, _ y: Int) -> ChaseTile {
        guard y >= 0, y < height else { return .wall }
        if x < 0 || x >= width { return y == tunnelRow ? .empty : .wall }
        return tiles[y][x]
    }

    /// The tunnel's slow stretch: the tunnel row from the edge up to, not including, the
    /// first tile where a side channel crosses it (chasers move at tunnel speed here; at
    /// the junction they are back at full speed). Off-maze tiles count too.
    public static func isTunnel(_ x: Int, _ y: Int) -> Bool {
        y == tunnelRow && (x < tunnelEnd || x >= width - tunnelEnd)
    }

    /// Columns 0 ..< `tunnelEnd` (and their mirror) are the slow stretch.
    public static let tunnelEnd: Int = {
        var x = 0
        while x < width / 2 {
            let crossed = tiles[tunnelRow - 1][x] != .wall || tiles[tunnelRow + 1][x] != .wall
            if crossed { return x }
            x += 1
        }
        return x
    }()

    public static var dotCount: Int { tiles.joined().filter { $0 == .dot }.count }
    public static var pelletCount: Int { tiles.joined().filter { $0 == .pellet }.count }
}
