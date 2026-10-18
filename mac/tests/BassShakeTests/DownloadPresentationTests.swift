import Foundation
import Testing
@testable import BassShake

struct DownloadPresentationTests {
  @Test func sourceNamesUseExactDomains() {
    #expect(DownloadSource.name("https://m.youtube.com/watch?v=abcdefghijk") == "YouTube")
    #expect(DownloadSource.name("https://soundcloud.com/artist/song") == "SoundCloud")
    #expect(DownloadSource.name("https://x.com/artist/status/123") == "X")
    #expect(DownloadSource.name("https://twitter.com/artist/status/123") == "X")
    #expect(DownloadSource.name("https://youtube.com.example.org/video") == "youtube.com.example.org")
    #expect(DownloadSource.legacyThumbnail("https://youtu.be/abcdefghijk")?.host == "i.ytimg.com")
    #expect(DownloadSource.legacyThumbnail("https://youtube.com.example.org/watch?v=abcdefghijk") == nil)
    #expect(DownloadSource.legacyThumbnail("https://youtu.be/../../bad") == nil)
  }

  @Test func artworkOnlyUsesRemoteHTTPSImages() {
    for raw in ["file:///tmp/a", "http://example.com/a", "https://127.0.0.1/a", "https://[::1]/a", "https://host.local/a", "https://user:pass@example.com/a"] {
      #expect(!DownloadArtwork.isRemoteImageURL(URL(string: raw)!))
    }
    #expect(DownloadArtwork.isRemoteImageURL(URL(string: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg")!))
  }

  @Test func metadataIsOptionalAndNotMistakenForAnOutputFile() {
    if case .artwork(let url) = DownloadOutput.parse(#"BS_ART:"https://cdn.example.org/cover.jpg?token=short-lived""#) {
      #expect(url.contains("cover.jpg"))
    } else { Issue.record("Thumbnail metadata was not parsed") }
    if case .ignore = DownloadOutput.parse("BS_ART:null") {} else { Issue.record("Null thumbnail should be ignored") }
    if case .ignore = DownloadOutput.parse(#"BS_ART:"NA""#) {} else { Issue.record("Missing thumbnail should be ignored") }
    if case .file(let path) = DownloadOutput.parse(#"BS_FILE:"/tmp/audio.mp3""#) {
      #expect(path == "/tmp/audio.mp3")
    } else { Issue.record("Audio output parsing changed") }
  }

  @Test func audioConversionSupportsVideoPostsAcrossSites() throws {
    for source in ["https://x.com/artist/status/123", "https://soundcloud.com/artist/song", "https://www.youtube.com/watch?v=abcdefghijk"] {
      #expect(try DownloadCommand.validatedURL(source).absoluteString == source)
      for format in DownloadFormat.allCases {
        let job = DownloadJob(id: UUID(), url: source, title: "", format: format, destination: "/tmp", createdAt: Date())
        let args = DownloadCommand.arguments(job: job, dependencies: DownloadDependencies())
        let index = try #require(args.firstIndex(of: "--format"))
        #expect(args[index + 1] == (format == .originalAudio ? "bestaudio" : "bestaudio/best"))
        #expect(args.contains("--no-playlist"))
        #expect(args.contains("!is_live & !is_upcoming"))
        #expect(args.suffix(2) == ["--", source])
      }
    }
  }
}
