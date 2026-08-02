import SwiftUI

#if DEBUG
struct ChatLazyContractProbeKey: EnvironmentKey {
    static let defaultValue = ChatLazyContractProbe()
}
#endif
