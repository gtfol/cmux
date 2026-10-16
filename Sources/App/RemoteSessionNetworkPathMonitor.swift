import CmuxMobileHost
import Foundation
@preconcurrency import Network

/// Watches the macOS network path and re-arms suspended SSH remote workspaces
/// when connectivity returns.
///
/// `RemoteSessionCoordinator` deliberately suspends its auto-reconnect loop
/// after the host stays unreachable
/// (`WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes`, issue
/// [#5734](https://github.com/manaflow-ai/cmux/issues/5734)), and before this
/// type the only signals that re-armed a suspended coordinator were a manual
/// reconnect and `NSWorkspace.didWakeNotification`. A live network switch
/// (Wi-Fi handoff, VPN toggle, tether) therefore left every SSH workspace
/// suspended, and the single-shot wake re-arm fires before Wi-Fi is up. This
/// monitor supplies the missing trigger: when the path settles onto a usable
/// network, `onNetworkPathRestored` fans out to the existing
/// `resetReconnectPolicyAndReconnect` re-arm the wake path already uses.
///
/// The observation policy (``reArmDecision(previous:isSatisfied:signature:secondsSinceLastReArm:coalesceWindow:)``)
/// is a pure `nonisolated static` function so its baseline / transition /
/// throttle behavior is unit-testable without a live `NWPathMonitor`.
@MainActor
final class RemoteSessionNetworkPathMonitor {
    /// What a single path observation should do about re-arming.
    enum ReArmDecision: Equatable {
        /// No usable path, or a duplicate of the last reported observation.
        case ignore
        /// First observation at startup; record it silently, do not re-arm.
        case baseline
        /// The path transitioned onto a usable network; re-arm now.
        case reArm
        /// A qualifying transition arrived within the coalesce window of the
        /// last re-arm; suppressed so flapping cannot storm reconnect attempts.
        case throttled
    }

    /// A reported path observation: whether the path is usable, plus its
    /// deduplication signature.
    struct Observation: Equatable {
        let isSatisfied: Bool
        let signature: String
    }

    private let monitor = NWPathMonitor()
    private let onNetworkPathRestored: @MainActor () -> Void
    /// Minimum spacing between re-arms; absorbs `NWPathMonitor` bursts and
    /// network flapping.
    private let coalesceWindow: TimeInterval
    /// Local IPv4 lookup seam; called on the monitor queue, off-main.
    private let localIPv4Addresses: @Sendable () -> [String]

    /// Last reported observation, for baseline/transition/dedup decisions.
    private var lastObservation: Observation?
    /// Monotonic instant of the last re-arm, for the coalesce window.
    private var lastReArmInstant: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init(
        coalesceWindow: TimeInterval = 1.5,
        onNetworkPathRestored: @escaping @MainActor () -> Void,
        localIPv4Addresses: @escaping @Sendable () -> [String] = {
            MobileHostNetworkPathMonitor.systemLocalIPv4Addresses()
        }
    ) {
        self.coalesceWindow = coalesceWindow
        self.onNetworkPathRestored = onNetworkPathRestored
        self.localIPv4Addresses = localIPv4Addresses
    }

    /// Begin observing. The handler computes the signature off-main (on
    /// `queue`) and hops to the main actor for decision state and the callback.
    func start(queue: DispatchQueue) {
        monitor.pathUpdateHandler = { [weak self, localIPv4Addresses] path in
            let isSatisfied = path.status == .satisfied
            let signature = Self.signature(
                status: String(describing: path.status),
                interfaceNames: path.availableInterfaces.map(\.name),
                gateways: path.gateways.map { String(describing: $0) },
                localAddresses: localIPv4Addresses()
            )
            Task { @MainActor [weak self] in
                self?.handleObservation(isSatisfied: isSatisfied, signature: signature)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private func handleObservation(isSatisfied: Bool, signature: String) {
        let secondsSinceLastReArm = lastReArmInstant.map { Self.seconds(clock.now - $0) }
        let decision = Self.reArmDecision(
            previous: lastObservation,
            isSatisfied: isSatisfied,
            signature: signature,
            secondsSinceLastReArm: secondsSinceLastReArm,
            coalesceWindow: coalesceWindow
        )
        lastObservation = Observation(isSatisfied: isSatisfied, signature: signature)
        guard decision == .reArm else { return }
        lastReArmInstant = clock.now
        onNetworkPathRestored()
    }

    /// Whether a path observation should re-arm suspended remote workspaces.
    ///
    /// - Fires only on a usable (`.satisfied`) path, and only on a genuine
    ///   transition — the path came back online, or the online network changed.
    /// - The first observation is a silent baseline so app launch never re-arms.
    /// - A qualifying transition within `coalesceWindow` of the last re-arm is
    ///   `.throttled` so flapping networks cannot storm reconnect attempts; the
    ///   coordinator's own backoff lands the reconnect on the settled network.
    nonisolated static func reArmDecision(
        previous: Observation?,
        isSatisfied: Bool,
        signature: String,
        secondsSinceLastReArm: TimeInterval?,
        coalesceWindow: TimeInterval
    ) -> ReArmDecision {
        guard isSatisfied else { return .ignore }
        guard let previous else { return .baseline }
        let isTransition = !previous.isSatisfied || previous.signature != signature
        guard isTransition else { return .ignore }
        if let secondsSinceLastReArm, secondsSinceLastReArm < coalesceWindow {
            return .throttled
        }
        return .reArm
    }

    /// Stable identity of a network path for change detection. Order-insensitive
    /// over interfaces, gateways, and local addresses so enumeration order
    /// cannot fake a change.
    nonisolated static func signature(
        status: String,
        interfaceNames: [String],
        gateways: [String],
        localAddresses: [String]
    ) -> String {
        let interfaces = interfaceNames.sorted().joined(separator: ",")
        let gatewayList = gateways.sorted().joined(separator: ",")
        let addresses = localAddresses.sorted().joined(separator: ",")
        return "\(status)|\(interfaces)|\(gatewayList)|\(addresses)"
    }

    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
    }
}
