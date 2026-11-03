import Foundation

/// 1.2.2 low-light assist: is the scene too dim for a clean shot (suggest the flashlight)? Pure, unit-tested; the
/// camera feeds it one sample per analysed frame (≈ 8×/s).
///
/// Scene brightness comes from the frame's EXIF BrightnessValue (APEX Bv) when the camera attaches it; else it is
/// estimated from ISO and exposure time (Bv ≈ log2(1/t) − log2(ISO/100) − 3.5 for an f/1.5–1.8 phone lens).
/// Rough scale: daylight 7–10, bright room 2–4, dim restaurant / warm home lamp −2…0. Auto exposure keeps the picture
/// itself looking normal, so the mean luma only matters when the camera cannot brighten it any further.
struct LowLightSample: Sendable, Equatable {
    /// EXIF BrightnessValue (APEX).
    var brightnessValue: Double?
    var iso: Double?
    var exposureSeconds: Double?
    /// ISO / the active format's maximum ISO (0…1).
    var isoRatio: Double?
    /// Mean luma of the frame, 0…255.
    var meanLuma: Double?
}

struct LowLightClassifier: Sendable, Equatable {
    /// Turns dim below this brightness value…
    static let enterBrightness = 0.0
    /// …and bright again above this one (hysteresis, so it doesn't flicker around one value).
    static let leaveBrightness = 1.0
    /// A frame this dark is dim whatever the exposure says (the camera has run out of gain).
    static let darkLuma = 55.0
    /// How long a reading must hold before the state flips (seconds).
    static let enterHold = 1.0
    static let leaveHold = 1.5

    private(set) var isDim = false
    private var pendingSince: Double?

    /// Bv of a sample (measured, else estimated), nil when nothing usable is known.
    static func brightness(_ s: LowLightSample) -> Double? {
        if let bv = s.brightnessValue, bv.isFinite { return bv }
        if let iso = s.iso, let t = s.exposureSeconds, iso > 0, t > 0 {
            return log2(1 / t) - log2(iso / 100) - 3.5
        }
        return nil
    }

    /// What one sample says on its own: true = dim, false = bright, nil = in between (keep the current state).
    static func verdict(_ s: LowLightSample) -> Bool? {
        if let l = s.meanLuma, l < darkLuma { return true }
        if let r = s.isoRatio, r >= 0.85 { return true }          // gain almost maxed out
        guard let bv = brightness(s) else { return nil }
        if bv < enterBrightness { return true }
        if bv > leaveBrightness { return false }
        return nil
    }

    /// Feeds one sample at time `now` (seconds); returns the (possibly new) state.
    @discardableResult
    mutating func update(_ s: LowLightSample, now: Double) -> Bool {
        guard let v = Self.verdict(s), v != isDim else {
            pendingSince = nil
            return isDim
        }
        if let since = pendingSince {
            if now - since >= (v ? Self.enterHold : Self.leaveHold) {
                isDim = v
                pendingSince = nil
            }
        } else {
            pendingSince = now
        }
        return isDim
    }

    mutating func reset() {
        isDim = false
        pendingSince = nil
    }
}

/// The flashlight (torch) as the user wants it, reconciled with what the device reports. Pure, unit-tested.
/// Rules: only the user turns it on; leaving the camera or the app turns it off; when the system turns it off
/// (overheating, another app, an interruption) we accept that and do not turn it back on.
struct TorchState: Sendable, Equatable {
    /// Seconds after we change the torch before a device report that disagrees counts (the hardware lags a frame).
    static let settleTime = 1.0

    private(set) var wanted = false
    private var changedAt: Double = -.infinity

    /// The user tapped the button. Returns what to ask the device for.
    mutating func toggle(available: Bool, now: Double) -> Bool {
        wanted = available ? !wanted : false
        changedAt = now
        return wanted
    }

    /// The device answered a request: keep what it really did.
    mutating func applied(_ on: Bool, now: Double) {
        wanted = on
        changedAt = now
    }

    /// The device's state as seen on a frame. Returns true when the torch went off behind our back (then `wanted`
    /// is false and the UI should show it off).
    mutating func deviceReported(active: Bool, available: Bool, now: Double) -> Bool {
        guard wanted, now - changedAt >= Self.settleTime, !active || !available else { return false }
        wanted = false
        changedAt = now
        return true
    }

    /// Leaving the camera / going to the background. Returns true when the torch should be switched off.
    mutating func leave(now: Double) -> Bool {
        let was = wanted
        wanted = false
        changedAt = now
        return was
    }
}
