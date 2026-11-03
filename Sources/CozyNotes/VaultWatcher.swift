import Foundation
import CoreServices

@MainActor final class VaultWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(root: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated { Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue().onChange() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
                                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }
    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
