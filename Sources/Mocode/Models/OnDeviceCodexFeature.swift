import Foundation

enum OnDeviceCodexFeature {
    static var compiledIn: Bool {
#if MOCODE_DISABLE_ON_DEVICE_CODEX
        return false
#else
        return true
#endif
    }

    static var isEnabled: Bool {
        compiledIn
    }
}
