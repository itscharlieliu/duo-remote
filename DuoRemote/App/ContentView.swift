import SwiftUI

/// The Duo layout decision, in one place.
///
/// - Folded (compact width, the outer screen): a TabView. One pane at a
///   time, full-bleed, thumb-reachable.
/// - Unfolded (regular width, the inner screen): terminal and desktop
///   side by side, both live at once, with a draggable divider. This is
///   the whole point on a Duo: watch a build in the terminal while you
///   click around the desktop, without switching tabs.
///
/// The threshold is width-based, not device-name-based, so it also does
/// the right thing on an iPad or in Split View, and so a future Duo size
/// just works.
struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @State private var splitFraction: CGFloat = 0.5
    @State private var foldedTab = 0
    @State private var dragStartFraction: CGFloat?
    @State private var showingHosts = false

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                unfoldedLayout(width: geometry.size.width)
            } else {
                foldedLayout
            }
        }
    }

    // MARK: - Folded: tabs

    private var foldedLayout: some View {
        TabView(selection: $foldedTab) {
            TerminalPane(session: store.ssh)
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(0)
            DesktopPane(client: store.vnc)
                .tabItem { Label("Desktop", systemImage: "macwindow") }
                .tag(1)
            HostListView()
                .tabItem { Label("Hosts", systemImage: "server.rack") }
                .tag(2)
        }
    }

    // MARK: - Unfolded: side-by-side with draggable divider

    private func unfoldedLayout(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            hostBar
            HStack(spacing: 0) {
                TerminalPane(session: store.ssh)
                    .frame(width: width * splitFraction)
                divider(totalWidth: width)
                DesktopPane(client: store.vnc)
                    .frame(width: width * (1 - splitFraction) - dividerWidth)
            }
        }
    }

    private var dividerWidth: CGFloat { 10 }

    private func divider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color(.separator))
            .frame(width: dividerWidth)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary)
                    .frame(width: 3, height: 44)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStartFraction == nil {
                            dragStartFraction = splitFraction
                        }
                        let start = dragStartFraction ?? splitFraction
                        let next = start + value.translation.width / totalWidth
                        splitFraction = min(0.7, max(0.3, next))
                    }
                    .onEnded { _ in dragStartFraction = nil }
            )
    }

    private var hostBar: some View {
        HStack {
            if let host = store.selectedHost {
                Label(host.name, systemImage: "macmini")
                    .font(.subheadline)
                Text(host.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No Mac selected")
                    .font(.subheadline)
            }
            Spacer()
            Button {
                showingHosts = true
            } label: {
                Label("Hosts", systemImage: "server.rack")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .sheet(isPresented: $showingHosts) {
            HostListView()
        }
    }
}
