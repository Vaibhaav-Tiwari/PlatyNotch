import Foundation

/// One unread message as the Mail widget shows it: sender and subject only (v0.2 R21).
/// Never saved: it lives in memory while the widget runs and Mail is open.
public struct MailMessage: Equatable, Sendable, Identifiable {
    /// The RFC 822 Message-ID, without angle brackets ("" when Mail gave none).
    public let messageID: String
    public let sender: String
    public let subject: String
    public let received: Date?

    public var id: String { messageID.isEmpty ? "\(sender)\u{1f}\(subject)\u{1f}\(received?.timeIntervalSince1970 ?? 0)" : messageID }

    public init(messageID: String, sender: String, subject: String, received: Date?) {
        self.messageID = messageID
        self.sender = sender
        self.subject = subject
        self.received = received
    }

    /// `message://%3C<id>%3E`: opens this message in Mail. Nil without a Message-ID.
    public var openURL: URL? { MailLink.url(messageID: messageID) }
}

/// The inbox's unread count and its newest unread messages, newest first.
public struct MailInbox: Equatable, Sendable {
    /// How many messages the tile lists.
    public static let shownCount = 5

    public let unread: Int
    public let latest: [MailMessage]

    public init(unread: Int, latest: [MailMessage]) {
        self.unread = unread
        self.latest = latest
    }
}

/// `message:` links (Mail's own URL scheme for one message).
public enum MailLink {
    /// Characters kept as they are inside the brackets; everything else is percent-encoded.
    private static let kept = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")

    public static func url(messageID raw: String) -> URL? {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: kept) else { return nil }
        return URL(string: "message://%3C\(encoded)%3E")
    }
}

/// What a sender looks like in the tile.
public enum MailSender {
    /// `"Jane Doe" <jane@example.com>` → `Jane Doe`; a bare or bracketed address → the address.
    public static func displayName(_ raw: String) -> String {
        let s = MailText.oneLine(raw)
        if let lt = s.lastIndex(of: "<"), s.hasSuffix(">") {
            let name = s[..<lt].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
            return String(s[s.index(after: lt)..<s.index(before: s.endIndex)])
        }
        return s
    }
}

enum MailText {
    static let maxLength = 200

    /// A Message-ID as given, trimmed; "" (no link) when it has control characters or is
    /// longer than `MailScript.idLimit`.
    static func messageID(_ raw: String) -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count <= MailScript.idLimit,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return "" }
        return id
    }

    /// Control characters and line breaks become spaces, runs of spaces collapse, and the
    /// text is cut at `maxLength` characters.
    static func oneLine(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        // Only the head can show: never walk a huge field.
        for u in s.prefix(maxLength * 4).unicodeScalars {
            let breaks = CharacterSet.controlCharacters.contains(u) || CharacterSet.newlines.contains(u)
            scalars.append(breaks ? " " : u)
        }
        let cleaned = String(scalars)
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.count > maxLength ? String(collapsed.prefix(maxLength - 1)) + "…" : collapsed
    }
}

/// The one script the Mail widget runs, through `/usr/bin/osascript` (JavaScript for
/// Automation, so the answer is JSON). The source is constant; its one argument is the
/// pid of the Mail process `NSWorkspace` reported, and the script addresses that process,
/// never the app by name: a Mail that quit meanwhile is gone (-600) and is never launched
/// again. It also asks `running()` first and returns at once when Mail is not.
///
/// It reads two bulk lists of the unread messages, received date and Mail's numeric id
/// (equal lengths, else the inbox changed under it and the answer says so), picks the
/// newest `MailInbox.shownCount` from those, and then reads Message-ID, sender, subject
/// and date of each of those few by its id (`byId`), so a row never mixes two messages and
/// a large unread inbox costs two bulk requests, not one per field. A message gone
/// meanwhile is skipped (at most `MailInbox.shownCount` more are tried). Sender and
/// subject are cut to `fieldLimit` and the id to `idLimit` characters so one huge message
/// cannot overflow the answer. It never activates, opens, changes or marks anything.
public enum MailScript {
    public static let executable = "/usr/bin/osascript"
    /// The caller stops waiting (and the runner kills osascript) after this.
    public static let timeout: Double = 5
    public static let fieldLimit = 400
    /// RFC 5322's line limit; longer ids are refused (`MailText.messageID`).
    public static let idLimit = 998

    public static let source = """
    function run(argv) {
      var pid = Number(argv[0]);
      if (!(pid > 0)) { return JSON.stringify({running: false}); }
      var mail = Application(pid);
      if (!mail.running()) { return JSON.stringify({running: false}); }
      var inbox = mail.inbox;
      var unread = inbox.unreadCount();
      var msgs = inbox.messages.whose({readStatus: false});
      var dates = msgs.dateReceived();
      var keys = msgs.id();
      var n = dates.length;
      if (keys.length !== n) { return JSON.stringify({running: true, changed: true}); }
      function cut(v, limit) { return (v === null || v === undefined) ? '' : String(v).slice(0, limit); }
      var order = [];
      for (var i = 0; i < n; i++) { order.push([dates[i] ? dates[i].getTime() : 0, i]); }
      order.sort(function (a, b) { return b[0] - a[0]; });
      var latest = [];
      for (var k = 0; k < order.length && k < \(MailInbox.shownCount * 2) && latest.length < \(MailInbox.shownCount); k++) {
        try {
          var m = inbox.messages.byId(keys[order[k][1]]);
          var d = m.dateReceived();
          latest.push({id: cut(m.messageId(), \(idLimit)), sender: cut(m.sender(), \(fieldLimit)),
                       subject: cut(m.subject(), \(fieldLimit)), received: d ? d.getTime() / 1000 : 0});
        } catch (e) {}
      }
      return JSON.stringify({running: true, unread: unread, latest: latest});
    }
    """

    /// osascript's argv (never a shell): the constant source, then Mail's pid.
    public static func arguments(pid: Int32) -> [String] { ["-l", "JavaScript", "-e", source, String(pid)] }
}

/// What one run of `MailScript` came to.
public enum MailScriptOutcome: Equatable, Sendable {
    case inbox(MailInbox)
    /// Mail was not running (the script returned without touching it).
    case notRunning
    /// Automation for Mail is off for PlatyNotch (-1743), or would need a prompt (-1744).
    case denied
    case timedOut
    case failed(String)

    private struct Payload: Decodable {
        struct Message: Decodable {
            var id: String?
            var sender: String?
            var subject: String?
            var received: Double?
        }
        var running: Bool
        var changed: Bool?
        var unread: Int?
        var latest: [Message]?
    }

    /// `truncated`: the runner cut the output (`ProcessRunner.Result.truncated`), so the
    /// JSON is incomplete.
    public static func classify(status: Int32, stdout: String, stderr: String, timedOut: Bool,
                                truncated: Bool = false) -> MailScriptOutcome {
        if timedOut { return .timedOut }
        if truncated { return .failed("Mail's answer was too long to read.") }
        guard status == 0 else {
            switch errorCode(stderr) {
            case -1743, -1744: return .denied
            // -600/-609: the process is gone; -2700: osascript could not reach it.
            case -600, -609, -2700: return .notRunning
            case -1712: return .timedOut
            case let code?: return .failed("Mail did not answer (\(code)).")
            case nil: return .failed("Mail did not answer.")
            }
        }
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8)) else {
            return .failed("Mail gave an answer PlatyNotch could not read.")
        }
        guard payload.running else { return .notRunning }
        if payload.changed == true { return .failed("Mail's inbox changed while it was read.") }
        let messages = (payload.latest ?? []).map { m in
            MailMessage(messageID: MailText.messageID(m.id ?? ""), sender: MailSender.displayName(m.sender ?? ""),
                        subject: MailText.oneLine(m.subject ?? ""),
                        received: m.received.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
        }
        let sorted = messages.sorted { ($0.received ?? .distantPast) > ($1.received ?? .distantPast) }
        return .inbox(MailInbox(unread: max(0, payload.unread ?? 0), latest: Array(sorted.prefix(MailInbox.shownCount))))
    }

    /// The `(-1743)` at the end of osascript's error line.
    static func errorCode(_ stderr: String) -> Int? {
        let s = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasSuffix(")"), let open = s.lastIndex(of: "(") else { return nil }
        return Int(s[s.index(after: open)..<s.index(before: s.endIndex)])
    }
}

/// When the Mail widget reads Mail: every `interval` while it is on and Mail is open, and
/// when the panel shows its tile, at most once per `openThrottle`.
public enum MailRefresh {
    public static let interval: TimeInterval = 300
    public static let openThrottle: TimeInterval = 30

    /// The tile appeared: read now unless the last read began under `openThrottle` ago.
    public static func dueOnOpen(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= openThrottle || now < last
    }
}
