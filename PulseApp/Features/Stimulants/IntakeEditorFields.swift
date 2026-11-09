import SwiftUI

/// Keep the compact row only when both strings fit at their natural width.
struct IntakeLabelAndValue: View {
    @Environment(\.dynamicTypeSize) private var type
    let label: String
    let value: String

    private var title: some View { Text(label).frame(maxWidth: .infinity, alignment: .leading) }
    private var detail: some View { Text(value).foregroundStyle(.secondary) }

    var body: some View {
        Group {
            if type.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text(label).fixedSize()
                        Spacer(minLength: 0)
                        detail.fixedSize()
                    }
                    stacked
                }
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 3) {
            title
            detail
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IntakeChoice<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let name: (Value) -> String

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in Text(name(option)).tag(option) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                IntakeLabelAndValue(label: label, value: name(selection))
                Image(systemName: "chevron.up.chevron.down").font(.caption).accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(name(selection))
    }
}

struct IntakeDateFields: View {
    let label: String
    @Binding var date: Date
    let bounds: ClosedRange<Date>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.body).fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { day; time }.fixedSize()
                VStack(alignment: .leading, spacing: 6) { day; time }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var day: some View {
        DatePicker(label + " date", selection: $date, in: bounds, displayedComponents: .date)
            .datePickerStyle(.compact).labelsHidden().accessibilityLabel(label + " date")
    }
    private var time: some View {
        DatePicker(label + " time", selection: $date, in: bounds, displayedComponents: .hourAndMinute)
            .datePickerStyle(.compact).labelsHidden().accessibilityLabel(label + " time")
    }
}
