import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    Image(systemName: "chart.bar.xaxis").font(.title).foregroundStyle(Palette.accent)
                        .padding(13).background(Palette.soft, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L.t("Your time, accounted for")).font(.largeTitle.bold())
                        Text(L.t("Track more than one job, automate tip out, and see what each shift really earns."))
                            .foregroundStyle(Palette.subdued)
                    }
                    VStack(alignment: .leading, spacing: 13) {
                        feature("briefcase", L.t("Multiple jobs, tip-out rules and overtime"))
                        feature("chart.bar", L.t("Complete insights and pay periods"))
                        feature("doc.text", L.t("Annual tip reports and CSV import"))
                        feature("square.grid.2x2", L.t("Widgets, reminders and Face ID"))
                    }
                    .padding(16).ledgerCard()
                    Text(L.t("Pay once. No subscription or ads. Logging, viewing, editing and exporting your records stay free."))
                        .font(.subheadline).foregroundStyle(Palette.subdued)
                    actions
                }
                .padding(22)
            }
            .ledgerCanvas()
            .navigationTitle(L.t("Tipsheet Pro")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { CloseButton() } }
            .task { await model.loadProducts() }
            .accessibilityIdentifier("paywallScreen")
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.data.entitlement.purchasedPro {
                Label(L.t("Pro is unlocked."), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.accent)
            } else {
                let days = model.data.entitlement.remainingDays(at: model.now)
                if days > 0 {
                    Text(L.f("Pro trial · %@ days left", String(days))).font(.subheadline.weight(.medium))
                    if model.data.entitlement.trialClaimedAt == nil {
                        Button {
                            Task { await model.purchase(AppModel.trialID) }
                        } label: { Text(L.t("Claim free 30-day trial receipt")).frame(maxWidth: .infinity, minHeight: 36) }
                            .buttonStyle(.bordered).accessibilityIdentifier("claimTrial")
                    }
                } else {
                    Text(L.t("Your 30-day trial has ended.")).font(.subheadline.weight(.medium))
                }
                Button {
                    Task { await model.purchase(AppModel.proID) }
                } label: {
                    let price = model.proPriceText
                    Text(price.map { L.f("Unlock Pro · %@", $0) } ?? L.t("Unlock Pro"))
                        .fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 41)
                }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("buyPro")
            }
            Button(L.t("Restore purchases")) { Task { await model.restorePurchases() } }
                .frame(maxWidth: .infinity).font(.subheadline).accessibilityIdentifier("restorePurchases")
            if let message = model.purchaseMessage {
                Text(message).font(.footnote).foregroundStyle(Palette.subdued).accessibilityIdentifier("purchaseStatus")
            }
        }
        .disabled(model.busy)
    }

    private func feature(_ icon: String, _ title: String) -> some View {
        Label {
            Text(title).font(.subheadline)
        } icon: {
            Image(systemName: icon).foregroundStyle(Palette.accent).frame(width: 23)
        }
    }
}
