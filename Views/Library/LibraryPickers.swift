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
    @State private var showSaveViewPrompt = false
    @State private var saveViewNameDraft = ""

    private var isActive: Bool { vm.unreadOnly || vm.minRatingFilter > 0 }

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

            Divider()

            ForEach([0, 1, 2, 3, 4, 5], id: \.self) { threshold in
                Button {
                    vm.minRatingFilter = threshold
                } label: {
                    let label = threshold == 0 ? "Any Rating" : "★\(threshold) & Up"
                    if vm.minRatingFilter == threshold {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }

            Divider()

            Button {
                saveViewNameDraft = ""
                showSaveViewPrompt = true
            } label: {
                Label("Save Current View…", systemImage: "pin")
            }
        } label: {
            Label("Filter", systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
        }
        .help(isActive ? "Filters active" : "Filter by read status or rating")
        .accessibilityLabel(isActive ? "Filters active" : "Filter comics")
        .alert("Save Current View", isPresented: $showSaveViewPrompt) {
            TextField("Name", text: $saveViewNameDraft)
            Button("Save") {
                let trimmed = saveViewNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                vm.saveCurrentAsView(name: trimmed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remembers the current sort, filter, and search so you can jump straight back to it from the sidebar.")
        }
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
