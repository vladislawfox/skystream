import AVKit
import Flutter
import UIKit

/// VLC schedules decoded frames against its audio clock. Stamp each arriving
/// frame at the VLC-aligned timebase time; AVKit uses that same clock for its UI.
@available(iOS 15.0, *)
final class VlcSampleBufferView: UIView, FlutterPlatformView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
  private var timebase: CMTimebase?
  private var disposed = false
  private var lastPosition: CMTime?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    clipsToBounds = true
    displayLayer.videoGravity = .resizeAspect
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                   sourceClock: CMClockGetHostTimeClock(),
                                   timebaseOut: &timebase)
    displayLayer.controlTimebase = timebase
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func view() -> UIView { self }

  func setFit(_ fit: String) {
    switch fit {
    case "cover": displayLayer.videoGravity = .resizeAspectFill
    case "fill": displayLayer.videoGravity = .resize
    default: displayLayer.videoGravity = .resizeAspect
    }
  }

  func synchronize(position: CMTime, playbackRate: Float) {
    guard !disposed, let timebase, position.isNumeric else { return }
    if lastPosition != position {
      CMTimebaseSetTime(timebase, time: position)
      lastPosition = position
    }
    CMTimebaseSetRate(timebase, rate: Double(max(0, playbackRate)))
  }

  func enqueue(_ pixelBuffer: CVPixelBuffer, position: CMTime,
               visibleSize: CGSize, playbackRate: Float,
               pixelAspectRatio: CGSize = CGSize(width: 1, height: 1)) {
    guard !disposed else { return }
    synchronize(position: position, playbackRate: playbackRate)
    if displayLayer.status == .failed { displayLayer.flush() }
    // Do not fill AVKit's queue when it is stalled. The next decoder callback
    // will fetch a newer frame; the bounded renderer pool stays bounded too.
    guard displayLayer.isReadyForMoreMediaData else { return }

    let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
    let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
    let visibleWidth = visibleSize.width > 0 ? min(width, visibleSize.width) : width
    let visibleHeight = visibleSize.height > 0 ? min(height, visibleSize.height) : height
    // Decoder padding is on the right/bottom. A clean aperture preserves both
    // the visible aspect ratio and the rows, including in AVKit's separate UI.
    CVBufferSetAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, [
      kCVImageBufferCleanApertureWidthKey: visibleWidth,
      kCVImageBufferCleanApertureHeightKey: visibleHeight,
      kCVImageBufferCleanApertureHorizontalOffsetKey: (visibleWidth - width) / 2,
      kCVImageBufferCleanApertureVerticalOffsetKey: (visibleHeight - height) / 2,
    ] as CFDictionary, .shouldPropagate)

    CVBufferSetAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey, [
      kCVImageBufferPixelAspectRatioHorizontalSpacingKey: pixelAspectRatio.width,
      kCVImageBufferPixelAspectRatioVerticalSpacingKey: pixelAspectRatio.height,
    ] as CFDictionary, .shouldPropagate)

    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
      let format else { return }
    let timestamp = timebase.map { CMTimebaseGetTime($0) } ?? position
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: timestamp,
                                   decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &sample) == noErr, let sample else { return }
    displayLayer.enqueue(sample)
  }

  func reset() {
    guard !disposed else { return }
    displayLayer.flushAndRemoveImage()
    synchronize(position: .zero, playbackRate: 0)
  }

  func dispose() {
    guard !disposed else { return }
    reset()
    disposed = true
    displayLayer.controlTimebase = nil
    timebase = nil
  }
}

/// The only transport boundary. Implementations operate the same VLC player
/// that supplied the inline frames; PiP never creates a second decoder.
protocol VlcPipPlayback: AnyObject {
  var pipIsPlaying: Bool { get }
  var pipHasMedia: Bool { get }
  var pipPosition: Int { get }
  var pipDuration: Int { get }
  var pipRate: Float { get }
  var pipIsSeekable: Bool { get }
  func pipApplyPlayback(_ playing: Bool)
  func pipSeek(to milliseconds: Int)
}

@available(iOS 15.0, *)
final class VlcPictureInPicture: NSObject, AVPictureInPictureControllerDelegate,
                                 AVPictureInPictureSampleBufferPlaybackDelegate {
  private let view: VlcSampleBufferView
  private weak var playback: VlcPipPlayback?
  private(set) var controller: AVPictureInPictureController?
  private var policy = VlcPictureInPicturePolicy()
  private var pendingStart: ((Bool) -> Void)?
  private var entryTimeout: DispatchWorkItem?
  private var backgroundTimeout: DispatchWorkItem?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var restoringInline = false
  private var selected = false
  private var disposed = false
  private var publishedActive = false
  var onModeChanged: ((Bool) -> Void)?
  var isActive: Bool { !disposed && controller?.isPictureInPictureActive == true }

  init(view: VlcSampleBufferView, playback: VlcPipPlayback) {
    self.view = view
    self.playback = playback
    super.init()
    if AVPictureInPictureController.isPictureInPictureSupported() {
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: view.displayLayer, playbackDelegate: self)
      controller = AVPictureInPictureController(contentSource: source)
      controller?.delegate = self
    }
    NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
    if UIApplication.shared.applicationState == .background {
      _ = policy.enterBackground(canAttemptPictureInPicture: false)
    }
  }

  func setSelected(_ selected: Bool) {
    self.selected = selected
    if !selected && (isActive || policy.isStarting) {
      controller?.stopPictureInPicture()
      apply(policy.pictureInPictureStopped(restoredInline: false))
      completeStart(false)
    }
    refreshPlaybackState()
  }

  func requestPlayback(_ playing: Bool) {
    guard !disposed else { return }
    apply(policy.requestPlayback(playing))
    refreshPlaybackState()
  }

  func sourceChanged(autoPlay: Bool) {
    guard !disposed else { return }
    view.reset()
    apply(policy.sourceChanged(autoPlay: autoPlay))
    refreshPlaybackState()
  }

  func interruptionBegan() {
    policy.interruptionBegan()
    apply(.pause)
    refreshPlaybackState()
  }

  func interruptionEnded(resumable: Bool) {
    apply(policy.interruptionEnded(resumable: resumable))
    refreshPlaybackState()
  }

  func playbackStateChanged(ended: Bool) {
    guard !disposed else { return }
    if ended {
      _ = policy.requestPlayback(false)
    } else if playback?.pipIsPlaying == true && !policy.allowsPlayback {
      // VLC can finish opening asynchronously after a lifecycle/user pause.
      apply(.pause)
    }
    refreshPlaybackState()
  }

  func refreshPlaybackState() {
    guard !disposed else { return }
    // The OS owns automatic initiation and its user preference. We do not call
    // startPictureInPicture from a lifecycle notification.
    controller?.canStartPictureInPictureAutomaticallyFromInline = selected && policy.allowsPlayback
    view.synchronize(position: mediaTime, playbackRate: playback?.pipIsPlaying == true ? playback?.pipRate ?? 1 : 0)
    controller?.requiresLinearPlayback = playback?.pipIsSeekable != true
    controller?.invalidatePlaybackState()
  }

  func start(completion: @escaping (Bool) -> Void) {
    guard !disposed, selected, playback?.pipHasMedia == true,
          view.window != nil, let controller else { completion(false); return }
    if controller.isPictureInPictureActive { completion(true); return }
    guard pendingStart == nil, !policy.isStarting,
          controller.isPictureInPicturePossible else { completion(false); return }
    pendingStart = completion
    policy.pictureInPictureWillStart()
    scheduleEntryTimeout()
    controller.startPictureInPicture()
  }

  private var mediaTime: CMTime {
    CMTime(value: Int64(playback?.pipPosition ?? 0), timescale: 1000)
  }

  private func apply(_ action: VlcPlaybackAction) {
    switch action {
    case .play: playback?.pipApplyPlayback(true)
    case .pause: playback?.pipApplyPlayback(false)
    case .wait, .none: break
    }
  }

  private func completeStart(_ success: Bool) {
    entryTimeout?.cancel()
    entryTimeout = nil
    let completion = pendingStart
    pendingStart = nil
    completion?(success)
  }

  private func scheduleEntryTimeout() {
    entryTimeout?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, !self.disposed else { return }
      self.controller?.stopPictureInPicture()
      self.apply(self.policy.entryFailedOrTimedOut())
      self.completeStart(false)
      self.refreshPlaybackState()
    }
    entryTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
  }

  @objc private func didEnterBackground() {
    guard !disposed else { return }
    let canAttempt = selected && view.window != nil && controller?.isPictureInPicturePossible == true
    let action = policy.enterBackground(canAttemptPictureInPicture: canAttempt)
    apply(action)
    if action == .wait {
      finishBackgroundGrace()
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "VLC PiP entry") { [weak self] in
        self?.backgroundGraceExpired()
      }
      let timeout = DispatchWorkItem { [weak self] in self?.backgroundGraceExpired() }
      backgroundTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
    }
    refreshPlaybackState()
  }

  private func backgroundGraceExpired() {
    guard !disposed else { return }
    apply(policy.entryFailedOrTimedOut())
    if !isActive { completeStart(false) }
    finishBackgroundGrace()
    refreshPlaybackState()
  }

  private func finishBackgroundGrace() {
    backgroundTimeout?.cancel()
    backgroundTimeout = nil
    if backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }

  @objc private func willEnterForeground() {
    guard !disposed else { return }
    finishBackgroundGrace()
    apply(policy.enterForeground())
    refreshPlaybackState()
  }

  private func publish(_ active: Bool) {
    guard publishedActive != active else { return }
    publishedActive = active
    onModeChanged?(active)
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    policy.dispose()
    NotificationCenter.default.removeObserver(self)
    finishBackgroundGrace()
    completeStart(false)
    controller?.canStartPictureInPictureAutomaticallyFromInline = false
    controller?.delegate = nil
    controller?.stopPictureInPicture()
    controller?.contentSource = nil
    controller = nil
    publish(false)
    onModeChanged = nil
    playback = nil
    view.dispose()
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard !disposed else { return }
    restoringInline = false
    policy.pictureInPictureWillStart()
    if entryTimeout == nil { scheduleEntryTimeout() }
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard !disposed, selected else { pictureInPictureController.stopPictureInPicture(); return }
    apply(policy.pictureInPictureStarted())
    finishBackgroundGrace()
    completeStart(true)
    publish(true)
    refreshPlaybackState()
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                 failedToStartPictureInPictureWithError error: Error) {
    guard !disposed else { return }
    apply(policy.entryFailedOrTimedOut())
    finishBackgroundGrace()
    completeStart(false)
    publish(false)
    refreshPlaybackState()
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard !disposed else { return }
    apply(policy.pictureInPictureStopped(restoredInline: restoringInline))
    restoringInline = false
    completeStart(false)
    finishBackgroundGrace()
    publish(false)
    refreshPlaybackState()
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    // Flutter retains the original route and this platform view during PiP.
    // Its window is still attached when the system requests inline return.
    let canRestore = !disposed && view.window != nil
    restoringInline = canRestore
    completionHandler(canRestore)
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    requestPlayback(playing)
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    guard !disposed, let playback, playback.pipHasMedia else { return .invalid }
    guard playback.pipDuration > 0 else {
      return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    // Include the timebase even at VLC's end position and during duration updates.
    let end = max(playback.pipDuration, playback.pipPosition + 1000)
    return CMTimeRange(start: .zero, duration: CMTime(value: Int64(end), timescale: 1000))
  }

  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
    disposed || playback?.pipIsPlaying != true
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                 didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                 skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
    defer { completion() }
    guard !disposed, let playback, playback.pipIsSeekable else { return }
    let delta = CMTimeGetSeconds(skipInterval) * 1000
    guard delta.isFinite else { return }
    let maxPosition = playback.pipDuration > 0 ? playback.pipDuration : Int(Int32.max)
    let target = min(Double(maxPosition), max(0, Double(playback.pipPosition) + delta))
    playback.pipSeek(to: Int(target))
    view.synchronize(position: CMTime(value: Int64(target), timescale: 1000),
                     playbackRate: playback.pipIsPlaying ? playback.pipRate : 0)
    controller?.invalidatePlaybackState()
  }
}
