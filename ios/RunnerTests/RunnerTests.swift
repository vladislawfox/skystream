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

  func testSampleBufferExtendsNV12PaddingWithoutCroppingVisiblePixels() throws {
    guard #available(iOS 15.0, *) else { throw XCTSkip("Sample-buffer PiP requires iOS 15") }
    var frame: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 192,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frame), kCVReturnSuccess)
    let buffer = try XCTUnwrap(frame)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
    for plane in 0..<2 {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
      memset(base, 0, stride * rows) // Green padding outside a white frame.
      let visibleRows = plane == 0 ? 180 : 90
      for row in 0..<visibleRows {
        memset(base.advanced(by: row * stride), plane == 0 ? 235 : 128, 320)
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let view = VlcSampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    defer { view.dispose() }
    view.enqueue(buffer, position: .zero,
                 visibleSize: CGSize(width: 320, height: 180), playbackRate: 0)
    XCTAssertNotEqual(view.displayLayer.status, .failed)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    for plane in 0..<2 {
      let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
      let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
        .assumingMemoryBound(to: UInt8.self)
      for row in 0..<rows {
        let pixels = UnsafeBufferPointer(start: base.advanced(by: row * stride), count: 320)
        XCTAssertTrue(pixels.allSatisfy { $0 == (plane == 0 ? 235 : 128) },
                      "Visible pixels and padded row \(row) in plane \(plane) must stay white")
      }
    }
    var description: CMVideoFormatDescription?
    XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: buffer, formatDescriptionOut: &description), noErr)
    XCTAssertEqual(CMVideoFormatDescriptionGetCleanAperture(try XCTUnwrap(description), originIsAtTopLeft: true),
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

  func testCoarseProgressCannotJumpThePresentationClock() throws {
    guard #available(iOS 15.0, *) else { throw XCTSkip("Sample-buffer PiP requires iOS 15") }
    let view = VlcSampleBufferView(frame: .zero)
    defer { view.dispose() }
    view.synchronize(position: CMTime(seconds: 42, preferredTimescale: 1000), playbackRate: 1)
    let timebase = try XCTUnwrap(view.displayLayer.controlTimebase)
    // Advance the real CoreMedia clock as if frames had been presented while
    // VLC's less frequent progress event was still in flight.
    CMTimebaseSetTime(timebase, time: CMTime(seconds: 42.4, preferredTimescale: 1000))
    view.synchronize(position: CMTime(seconds: 42.25, preferredTimescale: 1000), playbackRate: 1)
    XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(CMTimebaseGetTime(timebase)), 42.4)
    view.synchronize(position: CMTime(seconds: 42.75, preferredTimescale: 1000), playbackRate: 1)
    XCTAssertLessThan(CMTimeGetSeconds(CMTimebaseGetTime(timebase)), 42.5)
    view.synchronize(position: CMTime(seconds: 42.3, preferredTimescale: 1000), playbackRate: 0)
    XCTAssertEqual(CMTimebaseGetRate(timebase), 0)
    XCTAssertEqual(CMTimeGetSeconds(CMTimebaseGetTime(timebase)), 42.4, accuracy: 0.05)
  }

  func testResetReanchorsOnlyAfterDiscardingOldFrames() throws {
    guard #available(iOS 15.0, *) else { throw XCTSkip("Sample-buffer PiP requires iOS 15") }
    let view = VlcSampleBufferView(frame: .zero)
    defer { view.dispose() }
    view.synchronize(position: CMTime(seconds: 42, preferredTimescale: 1000), playbackRate: 0)
    view.reset()
    view.synchronize(position: CMTime(seconds: 7, preferredTimescale: 1000), playbackRate: 0)
    let timebase = try XCTUnwrap(view.displayLayer.controlTimebase)
    XCTAssertEqual(CMTimeGetSeconds(CMTimebaseGetTime(timebase)), 7, accuracy: 0.001)
  }

  func testPipTimelineMapsStableClockToVlcPositionAndSeek() throws {
    guard #available(iOS 15.0, *) else { throw XCTSkip("Sample-buffer PiP requires iOS 15") }
    let view = VlcSampleBufferView(frame: .zero)
    let transport = TestPlayback()
    let pip = VlcPictureInPicture(view: view, playback: transport)
    defer { pip.dispose(); view.dispose() }
    let controller = try XCTUnwrap(pip.controller)
    pip.setSelected(true)
    let timebase = try XCTUnwrap(view.displayLayer.controlTimebase)
    CMTimebaseSetTime(timebase, time: CMTime(seconds: 600, preferredTimescale: 1000))
    var range = pip.pictureInPictureControllerTimeRangeForPlayback(controller)
    XCTAssertEqual(CMTimeGetSeconds(range.start), 558, accuracy: 0.001)
    XCTAssertEqual(CMTimeGetSeconds(range.duration), 120, accuracy: 0.001)
    pip.pictureInPictureController(controller,
      skipByInterval: CMTime(seconds: 15, preferredTimescale: 1000), completion: {})
    range = pip.pictureInPictureControllerTimeRangeForPlayback(controller)
    XCTAssertEqual(CMTimeGetSeconds(CMTimebaseGetTime(timebase)), 600, accuracy: 0.001)
    XCTAssertEqual(CMTimeGetSeconds(CMTimeSubtract(CMTimebaseGetTime(timebase), range.start)),
                   57, accuracy: 0.001)
  }

  func testVlcDecodedVideoUsesContinuousPresentationAndPictureInPicture() async throws {
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
    // VLC progress arrives less often than decoded frames. Updating its UI
    // position must not rewind AVKit's clock while forward playback continues.
    let timebase = try XCTUnwrap(view.displayLayer.controlTimebase)
    var previousTime = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
    var minimumStep = 0.0
    var backwardsSteps = 0
    let playbackDeadline = Date().addingTimeInterval(1.2)
    while Date() < playbackDeadline {
      try await Task.sleep(nanoseconds: 5_000_000)
      let currentTime = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
      let step = currentTime - previousTime
      minimumStep = min(minimumStep, step)
      if step < -0.001 { backwardsSteps += 1 }
      previousTime = currentTime
    }
    print("PiP presentation clock: backwards=\(backwardsSteps), minimumStep=\(minimumStep)")
    XCTAssertEqual(backwardsSteps, 0, "Forward playback must not rewind the presentation clock")
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
