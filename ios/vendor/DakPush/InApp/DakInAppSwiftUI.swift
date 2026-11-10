#if canImport(SwiftUI)
    import SwiftUI

    extension View {
        /// Keeps DakPush in-app messages away while this view is on screen,
        /// for a screen that must not be covered (a call, a payment). See
        /// ``Dak/blockInApp()``.
        ///
        /// ```swift
        /// CallScreen().dakInAppBlocked()
        /// ```
        public func dakInAppBlocked(_ blocked: Bool = true) -> some View {
            modifier(DakInAppBlockModifier(blocked: blocked))
        }
    }

    private struct DakInAppBlockModifier: ViewModifier {
        let blocked: Bool
        @State private var block: DakInAppBlock?
        @State private var visible = false

        func body(content: Content) -> some View {
            content
                .onAppear {
                    visible = true
                    update()
                }
                .onDisappear {
                    visible = false
                    update()
                }
                .onChange(of: blocked) { _ in update() }
        }

        private func update() {
            if visible && blocked {
                if block == nil { block = Dak.blockInApp() }
            } else {
                block?.end()
                block = nil
            }
        }
    }
#endif
