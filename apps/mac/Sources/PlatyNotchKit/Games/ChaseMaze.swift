import Foundation

/// What a maze tile is.
public enum ChaseTile: Equatable, Sendable {
    case wall, dot, pellet, empty, door, house
}

/// Platy Chase's maze: 28 × 31 tiles, our own layout (not the arcade's), with the
/// classic's structure: 240 dots and 4 power pellets in the four corner regions, a ghost
/// house with a door in the middle, a wrap-around tunnel through row 14, and the classic
/// start positions (player under the house, the direct chaser above its door, the other
/// three inside). Positions are in tiles; a tile's centre is at +0.5.
public enum ChaseMaze {
    public static let width = 28
    public static let height = 31
    public static let tunnelRow = 14

    /// `#` wall, `.` dot, `o` power pellet, space empty corridor, `-` house door,
    /// `_` inside the house. Left–right symmetric; designed for PlatyNotch.
    public static let layout: [String] = [
        "############################",
        "#.....###..........###.....#",
        "#.###.###.########.###.###.#",
        "#o###.###.########.###.###o#",
        "#............##............#",
        "#.###.######.##.######.###.#",
        "#.###.######.##.######.###.#",
        "#.###.######.##.######.###.#",
        "#........ ##....## ........#",
        "#####.### ######## ###.#####",
        "#####.### ######## ###.#####",
        "#####.###          ###.#####",
        "#####.### ###--### ###.#####",
        "##### ### #______# ### #####",
        "          #______#          ",
        "##### ### #______# ### #####",
        "#####.### ######## ###.#####",
        "#####.###          ###.#####",
        "#####.### ######## ###.#####",
        "#####.### ######## ###.#####",
        "#............##............#",
        "#.###.######.##.######.###.#",
        "#.###.######.##.######.###.#",
        "#...#........  ........#...#",
        "#o#.#.######.##.######.#.#o#",
        "#.#.#.######.##.######.#.#.#",
        "#.....###..........###.....#",
        "#.###.###.##.##.##.###.###.#",
        "#.###.###.##.##.##.###.###.#",
        "#............##............#",
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

    /// The player's start: between columns 13 and 14 under the house, facing left.
    public static let playerStart = (x: 14.0, y: 23.5)
    /// Just above the door: the direct chaser's start and where every chaser leaves from.
    public static let doorTop = (x: 14.0, y: 11.5)
    /// Inside the house: the ambusher in the middle, the flanker left, the shy one right.
    public static let houseCentre = (x: 14.0, y: 14.5)
    public static let houseLeft = (x: 12.0, y: 14.5)
    public static let houseRight = (x: 16.0, y: 14.5)
    /// Where bonus items appear: under the house.
    public static let bonusSpot = (x: 14.0, y: 17.5)
    /// Tiles where chasers may not turn upwards in scatter or chase (the classic's four
    /// spots: either side of the corridor above the house and above the player's start).
    public static let noUpTiles: Set<Point> = [Point(x: 12, y: 11), Point(x: 15, y: 11),
                                               Point(x: 12, y: 23), Point(x: 15, y: 23)]

    public static func tile(_ x: Int, _ y: Int) -> ChaseTile {
        guard y >= 0, y < height else { return .wall }
        if x < 0 || x >= width { return y == tunnelRow ? .empty : .wall }
        return tiles[y][x]
    }

    /// The tunnel's slow stretch (chasers move at tunnel speed here).
    public static func isTunnel(_ x: Int, _ y: Int) -> Bool {
        y == tunnelRow && (x <= 5 || x >= width - 6)
    }

    public static var dotCount: Int { tiles.joined().filter { $0 == .dot }.count }
    public static var pelletCount: Int { tiles.joined().filter { $0 == .pellet }.count }
}
