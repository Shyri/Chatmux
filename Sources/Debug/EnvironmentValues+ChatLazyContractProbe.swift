import SwiftUI

#if DEBUG
extension EnvironmentValues {
    var chatLazyContractProbe: ChatLazyContractProbe {
        get { self[ChatLazyContractProbeKey.self] }
        set { self[ChatLazyContractProbeKey.self] = newValue }
    }
}
#endif
