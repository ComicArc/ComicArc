import SwiftUI

struct SortPicker: View {
    @EnvironmentObject var vm: LibraryViewModel

    var body: some View {
        Menu {
            ForEach(DatabaseManager.SortOrder.allCases) { order in
                Button {
                    vm.sortOrder = order
                    vm.reload()
                } label: {
                    if vm.sortOrder == order {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.system(size: 12))
        }
        .help("Sort: \(vm.sortOrder.rawValue)")
        .accessibilityLabel("Sort by \(vm.sortOrder.rawValue)")
    }
}

struct FilterPicker: View {
    @EnvironmentObject var vm: LibraryViewModel

    private var isActive: Bool { vm.unreadOnly }

    var body: some View {
        Menu {
            Button {
                vm.unreadOnly.toggle()
            } label: {
                if vm.unreadOnly {
                    Label("Unread Only", systemImage: "checkmark")
                } else {
                    Text("Unread Only")
                }
            }
        } label: {
            Label("Filter", systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
        }
        .help(isActive ? "Filters active" : "Filter by read status")
        .accessibilityLabel(isActive ? "Filters active" : "Filter comics")
    }
}

struct DensityPicker: View {
    @AppStorage("gridDensity") private var densityRaw = GridDensity.regular.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var density: GridDensity { GridDensity(rawValue: densityRaw) ?? .regular }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GridDensity.allCases, id: \.rawValue) { d in
                Button {
                    withAnimation(Design.motion(Design.easeFast, reduce: reduceMotion)) { densityRaw = d.rawValue }
                } label: {
                    Image(systemName: d.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(density == d ? Design.brandGold : .secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help(d.rawValue.capitalized + " grid")
                .accessibilityLabel("\(d.rawValue.capitalized) grid")
                .accessibilityAddTraits(density == d ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Design.surfaceBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
