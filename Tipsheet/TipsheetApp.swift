import CloudKit
import Combine
import StoreKit
import SwiftUI

@main
struct TipsheetApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notifications
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environment(\.calendar, .tipsheet)
                .onOpenURL { model.open($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.open(url) }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @State private var obscured = false

    var body: some View {
        VStack(spacing: 0) {
            if model.storageBlocked {
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                    Text(L.t("Could not read your records. Your local file is preserved.")).multilineTextAlignment(.center)
                }
                .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.tab {
                case .home: HomeView()
                case .calendar: CalendarScreen()
                case .insights: InsightsView()
                }
                bottom
            }
        }
        .ledgerCanvas()
        .modifier(AppPrivacyCover(obscured: obscured))
        .sheet(item: $model.sheet) { sheet in
            SheetHost(sheet: sheet)
                .modifier(AppPrivacyCover(obscured: obscured))
        }
        .task {
            if phase == .active && model.locked { Task { await model.unlock() } }
            await model.start()
        }
        .onChange(of: phase) { _, new in
            obscured = new != .active
            if new == .active {
                model.foreground()
                if model.locked { Task { await model.unlock() } }
            } else if new == .background {
                model.background()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WidgetBridge.logRequest)) { _ in model.handleLaunchFlag() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            if phase == .active { model.foregroundTick() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in model.requestCloud() }
        .task(id: model.pendingReview && model.sheet == nil && phase == .active) {
            guard model.pendingReview, model.sheet == nil, phase == .active else { return }
            try? await Task.sleep(for: .milliseconds(650))
            if !Task.isCancelled, phase == .active, model.sheet == nil {
                model.pendingReview = false
                requestReview()
            }
        }
        .overlay(alignment: .top) {
            if let notice = model.notice, model.sheet == nil, !model.locked, !model.storageBlocked {
                NoticeBanner(text: notice)
            }
        }
    }

    private var bottom: some View {
        VStack(spacing: 9) {
            if let id = model.undoID {
                HStack {
                    Text(L.t("Shift deleted"))
                    Spacer()
                    Button(L.t("Undo")) { model.restore(id) }.fontWeight(.semibold)
                }
                .padding(12).ledgerCard(12)
                .padding(.horizontal, 22)
                .accessibilityIdentifier("undoBanner")
            }
            Button { model.logShift() } label: {
                Label(L.t("Log shift"), systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 25).frame(minHeight: 54)
                    .foregroundStyle(Palette.onAccent).background(Palette.accent, in: Capsule())
                    .shadow(color: Palette.accent.opacity(0.2), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("logShift")
            Divider().overlay(Palette.line)
            HStack(spacing: 0) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Button {
                        model.tab = tab
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.icon).font(.system(size: 22, weight: .medium))
                            Text(tab.title).font(.caption2.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(model.tab == tab ? Palette.accent : Palette.subdued)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                    .accessibilityIdentifier(tab.rawValue + "Tab")
                }
            }
        }
        .padding(.top, 5)
        .background(Palette.background)
    }
}

struct AppPrivacyCover: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let obscured: Bool

    func body(content: Content) -> some View {
        content
            .privacySensitive()
            .blur(radius: obscured || model.locked ? 24 : 0)
            .accessibilityHidden(obscured || model.locked)
            .allowsHitTesting(!obscured && !model.locked)
            .overlay {
                if model.locked {
                    VStack(spacing: 16) {
                        Image(systemName: "lock").font(.title)
                        Button(L.t("Unlock Tipsheet")) { Task { await model.unlock() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.authenticating)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.background.opacity(0.94))
                }
            }
    }
}

struct NoticeBanner: View {
    @EnvironmentObject private var model: AppModel
    let text: String
    var body: some View {
        Button { model.notice = nil } label: {
            Label(text, systemImage: "info.circle")
                .font(.footnote.weight(.medium)).padding(12).ledgerCard(12)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
        .buttonStyle(.plain).padding(.horizontal, 16)
        .task(id: text) {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, model.notice == text { model.notice = nil }
        }
    }
}

struct SheetHost: View {
    @EnvironmentObject private var model: AppModel
    let sheet: Sheet

    var body: some View {
        Group {
            switch sheet {
            case .shift(let day, let existing, let focus):
                ShiftEditor(day: day, existing: existing, shouldFocus: focus, job: model.defaultJob)
            case .day(let day): DayDetail(day: day)
            case .settings: SettingsView()
            case .paywall: PaywallView()
            case .weekShare: SharingView(kind: .week)
            case .milestones: SharingView(kind: .milestones)
            case .receipt(let shift): SharingView(kind: .receipt(shift))
            case .coworker: CoworkerView()
            case .tax: TaxView()
            }
        }
        .ledgerCanvas()
        .overlay(alignment: .top) {
            if let notice = model.notice, !model.locked { NoticeBanner(text: notice) }
        }
        .sheet(isPresented: Binding(get: { !model.pendingFiles.isEmpty }, set: { if !$0 { model.pendingFiles = [] } })) {
            ActivitySheet(items: model.pendingFiles)
        }
    }
}
