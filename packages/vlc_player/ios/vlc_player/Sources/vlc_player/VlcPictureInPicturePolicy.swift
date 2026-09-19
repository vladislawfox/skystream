import Foundation
import CoreGraphics

/// Pure transport decisions. AVKit and VLC are called by the owner on the main
/// queue; this type keeps user pauses distinct from lifecycle fallback pauses.
enum VlcPlaybackAction: Equatable { case none, play, pause, wait }

struct VlcPictureInPicturePolicy {
  private(set) var isBackgrounded = false
  private(set) var wantsPlayback = false
  private(set) var isActive = false
  private(set) var isStarting = false
  private(set) var isDisposed = false
  private var pausedForBackground = false
  private var interrupted = false
  private var awaitingAutomaticEntry = false

  var allowsPlayback: Bool {
    !isDisposed && wantsPlayback && !interrupted &&
      (!isBackgrounded || isActive || isStarting || awaitingAutomaticEntry)
  }

  mutating func requestPlayback(_ playing: Bool) -> VlcPlaybackAction {
    guard !isDisposed else { return .none }
    wantsPlayback = playing
    if !playing {
      pausedForBackground = false
      awaitingAutomaticEntry = false
      return .pause
    }
    if isBackgrounded && !isActive && !isStarting && !awaitingAutomaticEntry {
      pausedForBackground = true
      return .pause
    }
    return interrupted ? .pause : .play
  }

  mutating func sourceChanged(autoPlay: Bool) -> VlcPlaybackAction {
    pausedForBackground = false
    // A different source must not inherit an automatic-entry grace period.
    awaitingAutomaticEntry = false
    return requestPlayback(autoPlay)
  }

  mutating func enterBackground(canAttemptPictureInPicture: Bool) -> VlcPlaybackAction {
    guard !isDisposed else { return .none }
    isBackgrounded = true
    guard wantsPlayback else { return .none }
    if isActive { return .none }
    if isStarting || canAttemptPictureInPicture {
      awaitingAutomaticEntry = true
      return .wait
    }
    pausedForBackground = true
    return .pause
  }

  mutating func enterForeground() -> VlcPlaybackAction {
    guard !isDisposed else { return .none }
    isBackgrounded = false
    awaitingAutomaticEntry = false
    let resume = pausedForBackground && wantsPlayback && !interrupted
    pausedForBackground = false
    return resume ? .play : .none
  }

  mutating func pictureInPictureWillStart() {
    guard !isDisposed else { return }
    isStarting = true
  }

  mutating func pictureInPictureStarted() -> VlcPlaybackAction {
    guard !isDisposed else { return .none }
    isStarting = false
    isActive = true
    awaitingAutomaticEntry = false
    // AVKit may finish entering just after the bounded fallback paused VLC.
    let resume = pausedForBackground && wantsPlayback && !interrupted
    pausedForBackground = false
    return resume ? .play : .none
  }

  mutating func entryFailedOrTimedOut() -> VlcPlaybackAction {
    guard !isDisposed && !isActive else { return .none }
    isStarting = false
    awaitingAutomaticEntry = false
    guard isBackgrounded && wantsPlayback else { return .none }
    pausedForBackground = true
    return .pause
  }

  mutating func pictureInPictureStopped(restoredInline: Bool) -> VlcPlaybackAction {
    guard !isDisposed else { return .none }
    isActive = false
    isStarting = false
    awaitingAutomaticEntry = false
    if restoredInline {
      // Restoration can arrive before UIKit's foreground notification.
      if isBackgrounded && wantsPlayback {
        pausedForBackground = true
        return .pause
      }
      return .none
    }
    wantsPlayback = false
    pausedForBackground = false
    return .pause
  }

  mutating func interruptionBegan() { interrupted = true }
  @discardableResult
  mutating func interruptionEnded(resumable: Bool = true) -> VlcPlaybackAction {
    guard !isDisposed else { return .none }
    let wasInterrupted = interrupted
    interrupted = false
    guard wasInterrupted else { return .none }
    if !resumable { return requestPlayback(false) }
    return wantsPlayback ? requestPlayback(true) : .none
  }

  mutating func dispose() {
    isDisposed = true
    wantsPlayback = false
    pausedForBackground = false
    isStarting = false
    isActive = false
    awaitingAutomaticEntry = false
  }
}

/// Coalesces decoder notifications, not retained pixel buffers. The main queue
/// reads the renderer's latest frame once; bursts can queue only one such read.
final class VlcFrameDeliveryGate {
  private let lock = NSLock()
  private var pending = false
  private var disposed = false

  func requestDelivery() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !disposed && !pending else { return false }
    pending = true
    return true
  }

  func beginDelivery() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    pending = false
    return !disposed
  }

  func dispose() {
    lock.lock()
    disposed = true
    pending = false
    lock.unlock()
  }
}

struct VlcVideoGeometry {
  let visibleSize: CGSize
  let pixelAspectRatio: CGSize
  init(size: CGSize, orientation: Int = 0, sampleAspectRatio: CGSize = CGSize(width: 1, height: 1)) {
    // VLC3 vmem calls video_format_ApplyRotation before configuring our
    // buffer. VLCKit's track metadata remains in source orientation; values
    // 4...7 transpose its axes and invert SAR (VLCMediaOrientation).
    let swapsAxes = (4...7).contains(orientation)
    visibleSize = swapsAxes ? CGSize(width: size.height, height: size.width) : size
    let validSAR = sampleAspectRatio.width.isFinite && sampleAspectRatio.height.isFinite &&
      sampleAspectRatio.width > 0 && sampleAspectRatio.height > 0
    let sar = validSAR ? sampleAspectRatio : CGSize(width: 1, height: 1)
    pixelAspectRatio = swapsAxes ? CGSize(width: sar.height, height: sar.width) : sar
  }
}
