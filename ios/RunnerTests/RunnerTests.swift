import AVFoundation
import AVKit
import CoreVideo
import Flutter
import UIKit
import XCTest
@testable import vlc_player

@MainActor
class RunnerTests: XCTestCase {

  func testBackgroundAudioIsEnabledForPictureInPicture() {
    let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
    XCTAssertTrue(modes?.contains("audio") == true)
  }

  func testSampleBufferUsesTheVisibleNativeLayer() throws {
    guard #available(iOS 15.0, *) else { throw XCTSkip("Sample-buffer PiP requires iOS 15") }
    let view = VlcSampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    defer { view.dispose() }
    XCTAssertTrue(view.layer === view.displayLayer)
    view.setFit("cover")
    XCTAssertEqual(view.displayLayer.videoGravity, .resizeAspectFill)
    view.setFit("contain")
    XCTAssertEqual(view.displayLayer.videoGravity, .resizeAspect)
  }

  func testPausedFrameKeepsItsPlaybackTimebase() async throws {
    guard #available(iOS 15.0, *) else { throw XCTSkip("Sample-buffer PiP requires iOS 15") }
    let view = VlcSampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    defer { view.dispose() }
    let buffer = try makeFrame(width: 320, height: 192)
    view.enqueue(buffer, position: CMTime(seconds: 42, preferredTimescale: 1000),
                 visibleSize: CGSize(width: 320, height: 180), playbackRate: 0)
    // Allow the bounded main-queue delivery to present the latest frame.
    let delivered = expectation(description: "frame delivered")
    DispatchQueue.main.async { delivered.fulfill() }
    await fulfillment(of: [delivered], timeout: 2)
    let timebase = try XCTUnwrap(view.displayLayer.controlTimebase)
    XCTAssertEqual(CMTimeGetSeconds(CMTimebaseGetTime(timebase)), 42, accuracy: 0.05)
    XCTAssertEqual(CMTimebaseGetRate(timebase), 0)
    XCTAssertNotEqual(view.displayLayer.status, .failed, "\(String(describing: view.displayLayer.error))")
    var description: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: buffer, formatDescriptionOut: &description), noErr)
    let format = try XCTUnwrap(description)
    XCTAssertEqual(CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true),
                   CGRect(x: 0, y: 0, width: 320, height: 180))
  }

  func testPictureInPictureUsesSameLayerAndRejectsOffscreenStart() async throws {
    guard #available(iOS 15.0, *) else { throw XCTSkip("Sample-buffer PiP requires iOS 15") }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw XCTSkip("PiP unavailable on this device")
    }
    let view = VlcSampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    let transport = TestPlayback()
    let pip = VlcPictureInPicture(view: view, playback: transport)
    defer { pip.dispose(); view.dispose() }
    pip.setSelected(true)
    pip.requestPlayback(true)
    XCTAssertTrue(pip.controller?.contentSource?.sampleBufferDisplayLayer === view.displayLayer)
    XCTAssertTrue(pip.controller?.canStartPictureInPictureAutomaticallyFromInline == true)
    let rejected = expectation(description: "offscreen entry refused")
    pip.start { success in XCTAssertFalse(success); rejected.fulfill() }
    await fulfillment(of: [rejected], timeout: 1)
    pip.dispose()
    let disposed = expectation(description: "disposed entry refused")
    pip.start { success in XCTAssertFalse(success); disposed.fulfill() }
    await fulfillment(of: [disposed], timeout: 1)
  }

  func testVlcDecodedVideoStartsAndStopsPictureInPicture() async throws {
    guard #available(iOS 17.4, *) else { throw XCTSkip("Readiness inspection requires iOS 17.4") }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw XCTSkip("PiP unavailable on this device")
    }
    let movie = try XCTUnwrap(Bundle(for: RunnerTests.self).url(forResource: "video", withExtension: "mp4"))
    let view = VlcSampleBufferView(frame: UIScreen.main.bounds)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let host = UIViewController()
    host.view = view
    window.rootViewController = host
    window.makeKeyAndVisible()
    let player = VlcPlayerPlatformView(viewId: 9001, messenger: TestMessenger(), options: [],
                                      target: .sampleBuffer(view, fit: "contain"))
    defer {
      player.dispose()
      window.isHidden = true
      previousWindow?.makeKeyAndVisible()
    }
    let pip = try XCTUnwrap(player.pictureInPicture)
    let controller = try XCTUnwrap(pip.controller)
    pip.setSelected(true)
    let opened = expectation(description: "VLC source accepted")
    player.setSource(movie.absoluteString, httpHeaders: [:], mediaOptions: [":input-repeat=100"],
                     startPosition: 0, autoPlay: true) { result in
      XCTAssertFalse(result is FlutterError)
      opened.fulfill()
    }
    await fulfillment(of: [opened], timeout: 2)
    let deadline = Date().addingTimeInterval(8)
    while !view.displayLayer.isReadyForDisplay && Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(view.displayLayer.isReadyForDisplay, "VLC must decode into the real AVKit layer")
    XCTAssertNotEqual(view.displayLayer.status, .failed)
    let possibleDeadline = Date().addingTimeInterval(5)
    while !controller.isPictureInPicturePossible && Date() < possibleDeadline {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTAssertTrue(controller.isPictureInPicturePossible)
    let started = expectation(description: "AVKit reports actual PiP entry")
    pip.start { success in
      XCTAssertTrue(success)
      started.fulfill()
    }
    await fulfillment(of: [started], timeout: 5)
    XCTAssertTrue(controller.isPictureInPictureActive)
    XCTAssertTrue(player.pipIsPlaying)
    XCTAssertTrue(controller.contentSource?.sampleBufferDisplayLayer === view.displayLayer)
    let stopped = expectation(description: "AVKit reports PiP exit")
    pip.onModeChanged = { active in if !active { stopped.fulfill() } }
    controller.stopPictureInPicture()
    await fulfillment(of: [stopped], timeout: 5)
    XCTAssertFalse(controller.isPictureInPictureActive)
    XCTAssertTrue(view.window === window)
  }

  private func makeFrame(width: Int, height: Int) throws -> CVPixelBuffer {
    var frame: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey: [:],
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                    kCVPixelFormatType_32BGRA,
                                    attributes as CFDictionary, &frame)
    XCTAssertEqual(status, kCVReturnSuccess)
    let buffer = try XCTUnwrap(frame)
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
      memset(base, 255, CVPixelBufferGetDataSize(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
  }
}

private final class TestPlayback: VlcPipPlayback {
  var pipIsPlaying = false
  var pipHasMedia = true
  var pipPosition = 42_000
  var pipDuration = 120_000
  var pipRate: Float = 1
  var pipIsSeekable = true
  func pipApplyPlayback(_ playing: Bool) { pipIsPlaying = playing }
  func pipSeek(to milliseconds: Int) { pipPosition = milliseconds }
}

private final class TestMessenger: NSObject, FlutterBinaryMessenger {
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
    callback?(nil)
  }
  func setMessageHandlerOnChannel(_ channel: String,
                                 binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { 1 }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}
