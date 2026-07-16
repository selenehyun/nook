import Foundation
import Testing
@testable import NookKit

@Suite("Favicon service")
struct FaviconServiceTests {
    // A 1×1 PNG.
    private let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!

    @Test("A decodable image passes through unchanged")
    func passthrough() {
        #expect(FaviconService.decodableIconData(pngData) == pngData)
    }

    @Test("Non-image data is rejected")
    func rejectsGarbage() {
        #expect(FaviconService.decodableIconData(Data("not an image".utf8)) == nil)
    }

    @Test("apple-touch-icon is preferred over a plain icon")
    func prefersAppleTouchIcon() {
        let html = """
        <link rel="icon" href="/favicon.ico">
        <link rel="apple-touch-icon" href="/touch.png">
        """
        #expect(FaviconService.iconHrefs(in: html) == ["/touch.png", "/favicon.ico"])
    }
}
