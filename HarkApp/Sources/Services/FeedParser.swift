import Foundation

/// Minimal, forgiving RSS podcast feed parser (XMLParser, no dependency). Extracts exactly what
/// the P1 data model needs; Podcasting 2.0 extras (<podcast:transcript>) are read in P2.
struct ParsedFeed {
    var title: String = ""
    var author: String?
    var artworkURL: String?
    var summary: String?
    var items: [ParsedItem] = []
}

struct ParsedItem {
    var title: String = ""
    var guid: String?
    var enclosureURL: String?
    var pubDate: Date?
    var durationSeconds: Double?
    var summary: String?
}

enum FeedParserError: Error { case badXML, noChannel }

final class FeedParser: NSObject, XMLParserDelegate {
    static func parse(data: Data) throws -> ParsedFeed {
        let p = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() || !p.feed.items.isEmpty else { throw FeedParserError.badXML }
        guard !p.feed.title.isEmpty || !p.feed.items.isEmpty else { throw FeedParserError.noChannel }
        return p.feed
    }

    static func fetch(_ url: URL) async throws -> ParsedFeed {
        var request = URLRequest(url: url)
        request.setValue("Hark/0.1 (podcast app)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return try parse(data: data)
    }

    private var feed = ParsedFeed()
    private var currentItem: ParsedItem?
    private var text = ""
    private var inImage = false

    // RFC 822 date, the RSS standard — two variants cover practically every real feed.
    private static let rfc822: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"].map { fmt in
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "item":
            currentItem = ParsedItem()
        case "enclosure":
            currentItem?.enclosureURL = attributes["url"]
        case "itunes:image":
            if currentItem == nil, let href = attributes["href"] { feed.artworkURL = href }
        case "image":
            inImage = currentItem == nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "item":
            if let item = currentItem, item.enclosureURL != nil { feed.items.append(item) }
            currentItem = nil
        case "title":
            if var item = currentItem { if item.title.isEmpty { item.title = value }; currentItem = item }
            else if feed.title.isEmpty, !inImage { feed.title = value }
        case "guid":
            currentItem?.guid = value.isEmpty ? nil : value
        case "pubDate":
            currentItem?.pubDate = Self.rfc822.lazy.compactMap { $0.date(from: value) }.first
        case "itunes:duration":
            currentItem?.durationSeconds = Self.parseDuration(value)
        case "description", "itunes:summary":
            if var item = currentItem { if item.summary == nil { item.summary = value }; currentItem = item }
            else if feed.summary == nil { feed.summary = value }
        case "itunes:author":
            if currentItem == nil, feed.author == nil { feed.author = value }
        case "url":
            if inImage, feed.artworkURL == nil { feed.artworkURL = value }
        case "image":
            inImage = false
        default: break
        }
    }

    /// "3723", "1:02:03", "62:03" are all real-world formats.
    static func parseDuration(_ s: String) -> Double? {
        if let secs = Double(s) { return secs }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
}
