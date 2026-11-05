#if os(iOS)
    import AVFoundation

    /// Configures the shared audio session for both playback engines.
    enum PlaybackAudioSession {
        /// Activates the playback category before audio starts.
        ///
        /// Both engines call this on every play, skip, and reconnect, often while audio is
        /// already playing through CarPlay or another accessory. A category write while audio
        /// plays can reconfigure the active route, so the category is written only when it
        /// differs. Activating an already active session changes nothing.
        static func activate(_ caller: String = #function) throws {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback || session.mode != .default || !session.categoryOptions.isEmpty {
                // Playback already supports AirPlay. Explicit allowAirPlay is only valid
                // with playAndRecord and causes OSStatus -50 on iOS.
                try session.setCategory(.playback, mode: .default)
                PlaybackDiagnostics.log("audio session category set by \(caller)")
            }
            try session.setActive(true)
            PlaybackDiagnostics.log("audio session activated by \(caller) | \(describe(session.currentRoute))")
        }

        static func deactivate(_ caller: String = #function) {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                PlaybackDiagnostics.log("audio session deactivated by \(caller)")
            } catch {
                PlaybackDiagnostics.log("audio session deactivation by \(caller) failed: \(error)")
            }
        }

        static func logRouteChange(_ notification: Notification) {
            guard PlaybackDiagnostics.enabled else { return }
            let session = AVAudioSession.sharedInstance()
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let previous = notification
                .userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            PlaybackDiagnostics.log(
                "audio route changed reason=\(reason.map(name) ?? "unknown") " +
                    "from=\(previous.map(describe) ?? "-") to=\(describe(session.currentRoute)) " +
                    "rate=\(session.sampleRate) io=\(session.ioBufferDuration)"
            )
        }

        private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
            route.outputs.map { "\($0.portType.rawValue)/\($0.portName)" }.joined(separator: ",")
        }

        private static func name(_ reason: AVAudioSession.RouteChangeReason) -> String {
            switch reason {
            case .newDeviceAvailable: "newDevice"
            case .oldDeviceUnavailable: "oldDeviceUnavailable"
            case .categoryChange: "categoryChange"
            case .override: "override"
            case .wakeFromSleep: "wakeFromSleep"
            case .noSuitableRouteForCategory: "noSuitableRoute"
            case .routeConfigurationChange: "routeConfiguration"
            case .unknown: "unknown"
            @unknown default: "other(\(reason.rawValue))"
            }
        }
    }
#endif
