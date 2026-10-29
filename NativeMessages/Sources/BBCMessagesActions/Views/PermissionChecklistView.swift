import SwiftUI

struct PermissionChecklistView: View {
    @Bindable var model: AppModel
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            ForEach(PermissionStep.allCases) { step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: model.permissions.granted(step) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.permissions.granted(step) ? Color.green : Color.secondary)
                        .font(.title3).accessibilityLabel(model.permissions.granted(step) ? "Allowed" : "Not verified")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title).fontWeight(.medium)
                        if !compact {
                            Text(model.permissions.granted(step) ? "Allowed" : step.instruction).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if !model.permissions.granted(step) {
                        Button(step == .automation ? "Allow…" : "Settings…") { model.setUpPermission(step) }.controlSize(.small)
                    }
                }
            }
        }
    }
}
