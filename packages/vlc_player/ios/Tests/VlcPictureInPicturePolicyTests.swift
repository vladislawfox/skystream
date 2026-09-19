import Foundation
import CoreGraphics

@main
struct PolicyTests {
  static func main() {
    var checks = 0
    func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
      precondition(actual == expected, "\(name): expected \(expected), got \(actual)")
      checks += 1
    }

    var p = VlcPictureInPicturePolicy()
    expect(p.requestPlayback(true), .play, "inline user play")
    expect(p.enterBackground(canAttemptPictureInPicture: false), .pause, "unsupported PiP pauses")
    expect(p.enterForeground(), .play, "policy pause resumes")
    expect(p.enterForeground(), .none, "resume only once")

    p = VlcPictureInPicturePolicy()
    expect(p.enterBackground(canAttemptPictureInPicture: true), .none, "paused background does not start")
    expect(p.enterForeground(), .none, "paused foreground stays paused")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    expect(p.enterBackground(canAttemptPictureInPicture: true), .wait, "AVKit gets bounded entry grace")
    p.pictureInPictureWillStart()
    expect(p.pictureInPictureStarted(), .none, "start keeps same transport")
    expect(p.entryFailedOrTimedOut(), .none, "late timeout cannot pause active PiP")
    expect(p.enterForeground(), .none, "foreground does not restart active PiP")
    expect(p.pictureInPictureStopped(restoredInline: true), .none, "inline restoration keeps playback")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    _ = p.enterBackground(canAttemptPictureInPicture: true)
    expect(p.entryFailedOrTimedOut(), .pause, "failed entry pauses")
    expect(p.requestPlayback(true), .pause, "late Dart interruption resume stays silent without PiP")
    expect(p.enterForeground(), .play, "fallback resumes on return")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    _ = p.enterBackground(canAttemptPictureInPicture: true)
    _ = p.requestPlayback(false)
    expect(p.entryFailedOrTimedOut(), .none, "manual pause cancels pending resume")
    expect(p.enterForeground(), .none, "manual pause survives foreground")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    p.pictureInPictureWillStart()
    _ = p.pictureInPictureStarted()
    _ = p.enterBackground(canAttemptPictureInPicture: true)
    expect(p.pictureInPictureStopped(restoredInline: false), .pause, "closing PiP pauses")
    expect(p.enterForeground(), .none, "closing PiP does not restart")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    _ = p.enterBackground(canAttemptPictureInPicture: false)
    expect(p.sourceChanged(autoPlay: false), .pause, "paused source replaces pending resume")
    expect(p.enterForeground(), .none, "old source resume cannot play new paused source")
    _ = p.enterBackground(canAttemptPictureInPicture: false)
    expect(p.sourceChanged(autoPlay: true), .pause, "background source autoplay blocked")
    expect(p.enterForeground(), .play, "new autoplay source can start on return")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    _ = p.enterBackground(canAttemptPictureInPicture: false)
    p.interruptionBegan()
    expect(p.enterForeground(), .none, "foreground cannot resume during interruption")
    p.interruptionEnded()
    expect(p.requestPlayback(true), .play, "resumable interruption can resume inline")
    p.interruptionBegan()
    expect(p.requestPlayback(true), .pause, "explicit play cannot defeat active interruption")
    p.interruptionEnded()
    _ = p.requestPlayback(false)
    expect(p.enterForeground(), .none, "interruption does not invent resume")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    _ = p.enterBackground(canAttemptPictureInPicture: true)
    p.dispose()
    expect(p.pictureInPictureStarted(), .none, "late start after disposal ignored")
    expect(p.requestPlayback(true), .none, "play after disposal ignored")
    expect(p.enterForeground(), .none, "dispose clears pending resume")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    p.interruptionBegan()
    _ = p.requestPlayback(false)
    expect(p.interruptionEnded(resumable: true), .none, "PiP pause during call prevents call-end resume")
    _ = p.requestPlayback(true)
    p.interruptionBegan()
    _ = p.enterBackground(canAttemptPictureInPicture: false)
    expect(p.interruptionEnded(resumable: true), .pause, "call-end resume obeys background fallback")
    expect(p.enterForeground(), .play, "call-end policy pause resumes inline")
    p.interruptionBegan()
    expect(p.interruptionEnded(resumable: false), .pause, "nonresumable call stops playback intent")
    expect(p.enterForeground(), .none, "nonresumable call does not restart")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    expect(p.allowsPlayback, true, "inline asynchronous start allowed")
    _ = p.enterBackground(canAttemptPictureInPicture: false)
    expect(p.allowsPlayback, false, "late decoder start cannot bypass fallback")
    _ = p.enterForeground()
    p.interruptionBegan()
    expect(p.allowsPlayback, false, "late decoder start cannot bypass interruption")
    _ = p.interruptionEnded()
    _ = p.requestPlayback(false)
    expect(p.allowsPlayback, false, "late decoder start cannot bypass user pause")

    p = VlcPictureInPicturePolicy()
    _ = p.requestPlayback(true)
    _ = p.enterBackground(canAttemptPictureInPicture: true)
    _ = p.entryFailedOrTimedOut()
    expect(p.pictureInPictureStarted(), .play, "late actual PiP start can recover policy pause")
    expect(p.sourceChanged(autoPlay: true), .play, "source switch inside active PiP keeps playback")
    expect(p.pictureInPictureStopped(restoredInline: true), .pause, "restoration before foreground stays silent briefly")
    expect(p.enterForeground(), .play, "restoration resumes when app foregrounds")
    _ = p.enterBackground(canAttemptPictureInPicture: true)
    _ = p.entryFailedOrTimedOut()
    _ = p.requestPlayback(false)
    expect(p.pictureInPictureStarted(), .none, "late PiP start cannot override later user pause")

    let rotated = VlcVideoGeometry(size: CGSize(width: 1920, height: 1080), orientation: 6,
                                   sampleAspectRatio: CGSize(width: 4, height: 3))
    expect(rotated.visibleSize, CGSize(width: 1080, height: 1920), "rotated video retains full visible height")
    expect(rotated.pixelAspectRatio, CGSize(width: 3, height: 4), "quarter turn inverts pixel aspect")
    let anamorphic = VlcVideoGeometry(size: CGSize(width: 720, height: 576), orientation: 0,
                                     sampleAspectRatio: CGSize(width: 16, height: 15))
    expect(anamorphic.visibleSize, CGSize(width: 720, height: 576), "SAR does not crop source pixels")
    expect(anamorphic.pixelAspectRatio, CGSize(width: 16, height: 15), "anamorphic aspect reaches renderer")
    let invalidSAR = VlcVideoGeometry(size: CGSize(width: 320, height: 180), orientation: 0,
                                    sampleAspectRatio: .zero)
    expect(invalidSAR.pixelAspectRatio, CGSize(width: 1, height: 1), "missing SAR defaults square")

    let gate = VlcFrameDeliveryGate()
    expect(gate.requestDelivery(), true, "first frame schedules")
    let burst = (0..<1000).map { _ in gate.requestDelivery() }
    expect(burst.contains(true), false, "1000-frame burst coalesces into one latest-frame read")
    expect(gate.beginDelivery(), true, "pending read executes")
    expect(gate.requestDelivery(), true, "new frame after drain schedules")
    gate.dispose()
    expect(gate.beginDelivery(), false, "queued delivery after disposal cancelled")
    expect(gate.requestDelivery(), false, "disposed gate does not queue")
    print("Passed \(checks) native PiP policy/frame checks")
  }
}
