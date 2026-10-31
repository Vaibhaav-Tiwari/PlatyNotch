import PlatyNotchKit
import SwiftUI

/// The full-panel search (Island spec 4, wireframe D): the field on top with an `esc`
/// keycap, then Tools, Commands and Also (memory last), the shipped ranking. ⌥⌘K, ⌘K, the
/// dock's Search and typing with no field focused open it; Esc clears, then goes back.
struct SearchView: View {
    let model: PanelViewModel
    let logic: CommandLineLogic
    let memory: MemoryServices?

    var body: some View {
        CommandLineView(model: model, logic: logic, memory: memory, fullPanel: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
