import AppKit
import Combine
import SwiftUI

/// Classic interface style. `OrbitOverlay`'s panels as they are drawn when
/// `Preferences.interfaceStyle` is `.classic`; the Liquid Drop counterparts
/// are the `drop…` members in `OrbitSteer.swift`, and `OrbitPanelStyles.swift`
/// picks between them.
extension OrbitOverlay {

    /// What the host's probe knows about one guest — a VM from `virsh list` or a
    /// container from `docker ps`. A guest answers for itself: handing the click
    /// to its host answers a question nobody asked.
    @ViewBuilder
    var classicGuestPanel: some View {
        if let g = inspector.guestOnHost {
            let probe = probes["host:\(g.host)"]
            let container: HostInfo.Container? = {
                if case .loaded(let info)? = probe?.phase {
                    return info.containers?.first { $0.name == g.name }
                }
                return nil
            }()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: container == nil ? "macwindow.on.rectangle" : "shippingbox.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(g.name)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        Button { withAnimation(Theme.Spring.snappy) { inspector = .none } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                        }.buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        guestRow("host", Self.hostShort(g.host))
                        if let c = container {
                            guestRow("image", c.image)
                            guestRow("status", c.status)
                            if let runtime = containerRuntime(ofHost: g.host) {
                                guestRow("runtime", runtime.displayName)
                                if let s = containers.stats(host: g.host, container: c.name) {
                                    guestRow("cpu", s.cpu)
                                    guestRow("memory", s.memory)
                                }
                                if containers.isBusy(host: g.host, container: c.name) {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("asking \(runtime.displayName)…")
                                            .font(.system(size: 10, design: .rounded))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                        } else {
                            // A guest's real detail costs a `virsh dominfo` on
                            // the host, so it is fetched when this panel opens
                            // rather than on every map refresh.
                            let d = guests.detail(host: g.host, guest: g.name)
                            guestRow("state", d?.state ?? "—")
                            if let v = d?.vcpus { guestRow("cpu", v + (v == "1" ? " core" : " cores")) }
                            if let m = d?.maxMemoryMB ?? d?.memoryMB { guestRow("memory", Self.gb(m)) }
                            if let a = d?.autostart {
                                guestRow("on boot", a.hasPrefix("enable") ? "starts" : "manual")
                            }
                            if let ips = d?.addresses, !ips.isEmpty {
                                guestRow("address", ips.joined(separator: ", "))
                            }
                            if guests.isLoading(host: g.host, guest: g.name) {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("reading virsh…")
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            } else if let why = guests.failure(host: g.host, guest: g.name) {
                                Text(why).font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                                    .lineLimit(2)
                            }
                        }
                    }
                    .task(id: g.name + g.host) {
                        if container == nil {
                            guests.load(host: g.host, guest: g.name)
                        } else if let runtime = containerRuntime(ofHost: g.host) {
                            containers.loadStats(container: g.name, host: g.host, runtime: runtime)
                        }
                    }
                    if let c = container, let runtime = containerRuntime(ofHost: g.host) {
                        containerActions(c, host: g.host, runtime: runtime)
                    }
                    if let why = containers.failure(host: g.host, container: g.name) {
                        Text(why).font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.warning).lineLimit(3)
                    }
                    Button("Select \(Self.hostShort(g.host))") {
                        withAnimation(Theme.Spring.snappy) { inspector = .none }
                        toggleHostSelection(g.host)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Capsule().fill(chromeFill(prefs, selected: true)))
                }
                .padding(14)
                .frame(width: 280, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .padding(.trailing, 18).padding(.top, 60)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// Send input to a running agent, or interrupt it — writing straight to its
    /// tty via the pane's controller. No leaving Orbit.
    @ViewBuilder
    var classicSteerPanel: some View {
        if let paneID = inspector.agentPaneID, let pane = pane(withID: paneID) {
            let dir = friendlyDirLabel(for: pane.cwd)
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 13) {
                    // Header — the session's directory names it; a coloured pill
                    // reads its state at a glance.
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dir).font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            // Which tab it is, so the session you are steering
                            // here is one you can also find in the tab bar —
                            // the two name the same thing differently.
                            Text(tabName(for: pane).map { "Claude session · \($0)" }
                                 ?? "Claude session")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        steerStatusPill(pane.agent.phase)
                        Button { withAnimation(Theme.Spring.snappy) { inspector = .none } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain)
                    }

                    // Talk to it.
                    VStack(alignment: .leading, spacing: 6) {
                        steerSectionLabel("Message")
                        HStack(spacing: 6) {
                            TextField("Type a message…", text: $steerInput, axis: .vertical)
                                .textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
                                .focused($steerFocused).lineLimit(1...4)
                                .onSubmit { sendToAgent(pane) }
                            Button { sendToAgent(pane) } label: {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                                    .foregroundStyle(steerInput.isEmpty ? Theme.textSecondary : Theme.accent)
                            }.buttonStyle(.plain).disabled(steerInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.selectionFill))
                    }

                    // One-key replies to Claude's prompts.
                    VStack(alignment: .leading, spacing: 6) {
                        steerSectionLabel("Quick reply")
                        HStack(spacing: 8) {
                            steerAction("Stop", "stop.circle", tint: Theme.warning) {
                                pane.controller?.typeText("\u{1b}")   // Esc — interrupt
                            }.help("Interrupt what it's doing (Esc)")
                            steerAction("Enter", "return", tint: Theme.accent) {
                                pane.controller?.sendReturn()
                            }.help("Press Return")
                            steerAction("Yes", "checkmark", tint: Theme.accent) {
                                pane.controller?.typeText("y"); pane.controller?.sendReturn()
                            }.help("Answer yes to a prompt")
                        }
                    }
                    steerFeedSection(for: pane)
                    followUpSection(for: pane)
                }
                .padding(15)
                .frame(width: 320)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                .padding(.trailing, 18).padding(.top, 60)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    func classicSteerSectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary).textCase(.uppercase).tracking(0.5)
    }

    /// Coloured state pill in the steer header.
    func classicSteerStatusPill(_ phase: AgentStatus.Phase) -> some View {
        let (label, color): (String, Color) = {
            switch phase {
            case .working:     return ("working", Theme.accent)
            case .attention:   return ("needs you", Theme.warning)
            case .ready:       return ("ready", Color(red: 0.35, green: 0.82, blue: 0.45))
            case .interrupted: return ("stopped", Theme.textSecondary)
            case .idle:        return ("idle", Theme.textSecondary)
            }
        }()
        return Text(label).font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    /// Live feed of what the session just did — its pane is hidden in Orbit, so
    /// this is how you see the result of a steer without leaving the map.
    @ViewBuilder
    func classicSteerFeedSection(for pane: Pane) -> some View {
        let feed = steerFeed(for: pane)
        if !feed.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                steerSectionLabel("Recent activity")
                ForEach(feed) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isSubagent ? "person.2.fill" : "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(item.isSubagent ? Color(red: 0.62, green: 0.52, blue: 0.96) : Theme.accent)
                            .frame(width: 12)
                        Text(item.label).font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(hhmm(item.at)).font(.system(size: 9, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}
