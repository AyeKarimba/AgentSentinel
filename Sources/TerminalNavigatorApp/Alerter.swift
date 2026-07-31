import AppKit
import TNavCore

/// Turns "this session is waiting" into something the user actually notices.
///
/// The decision itself is `AlertPolicy`, which was written and tested long before anything
/// called it — every suppression rule (mute, snooze, pause, blocking-only, the tab you are
/// already looking at, the request you have already been told about) lives there. This type
/// only supplies what the policy cannot know on its own: what has already been sent.
///
/// That record is `AlertStore`, keyed by the wait rather than the session, so a new request in
/// the same tab re-arms without any flag needing to be reset.
final class Alerter {
    private let store: AlertStore
    private let banner: BannerPanel
    private var sound: NSSound?
    /// False until the first pass has run.
    ///
    /// On launch the app sees every session that is already waiting at once. Those are not new
    /// information — the user has been living with them — so the first pass adopts their state
    /// silently instead of firing a banner and a sound for each. Without this, starting the app
    /// with four tabs waiting means four alerts stacked on top of each other.
    private var primed = false

    init(store: AlertStore = AlertStore(), onBannerClick: @escaping (SessionRecord) -> Void) {
        self.store = store
        self.banner = BannerPanel(onClick: onBannerClick)
    }

    /// Called after every reload. Cheap when nothing is due, which is almost always.
    func evaluate(records: [SessionRecord],
                  config: Config,
                  frontmostTTY: String?,
                  now: Double = Date().timeIntervalSince1970) {
        for record in records {
            // The policy reasons about a record's own notified flag. That belongs to the
            // hook, so hand it a copy carrying what this app has actually sent instead.
            var view = record
            view.notified = store.hasNotified(record)

            switch AlertPolicy.decide(record: view, config: config,
                                      frontmostTTY: frontmostTTY,
                                      escalationsSent: store.escalations(record), now: now) {
            case .notify(let urgency):
                guard primed else {
                    store.adopt(record, escalateAfterSeconds: config.escalateAfterSeconds, now: now)
                    break
                }
                store.markNotified(record)
                deliver(record, urgent: urgency == .urgent, config: config, escalating: false)
            case .escalate:
                store.markEscalated(record)
                guard primed else { break }
                deliver(record, urgent: true, config: config, escalating: true)
            default:
                break
            }
        }
        store.prune(keeping: Set(records.map(\.sessionId)))
        primed = true
    }

    private func deliver(_ record: SessionRecord,
                         urgent: Bool,
                         config: Config,
                         escalating: Bool) {
        let settings = config.alerts
        EventLog.append("alert: \(escalating ? "escalate" : "notify") \(record.project) (\(record.tty))")

        if settings.soundEnabled {
            // An escalation always uses the urgent sound, whatever tier the original was: the
            // point of a second ping is that it does not sound like the one already missed.
            let name = (urgent || escalating) ? settings.urgentSoundName : settings.soundName
            if let effect = NSSound(named: name) {
                effect.volume = Float(settings.soundVolume)
                // Held onto because NSSound stops when it is deallocated, and a local would be
                // released before it finished playing.
                sound = effect
                effect.play()
            }
        }

        if settings.bannerEnabled {
            // Alerting means this is unread by definition, so the row's own tint is what the
            // banner should wear — an escalation forces urgent, matching its urgent sound.
            let tint: RowTint = urgent ? .urgent : record.tint(lastVisit: nil)
            banner.show(record: record, tint: tint, settings: settings)
        }
    }

    func dismissBanner() { banner.dismiss() }
}
