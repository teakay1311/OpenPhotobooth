import SwiftUI
import AppKit

/// PackImportSheet (§2.10): verify trước, preview chính sách từng khung, áp dụng import.
/// Sử dụng FramePackImportViewModel đã có sẵn.
public struct PackImportSheet: View {
    @ObservedObject var env: AppEnvironment
    @StateObject private var vm: FramePackImportViewModel
    @Environment(\.dismiss) private var dismiss
    let packURL: URL

    public init(env: AppEnvironment, packURL: URL) {
        self.env = env
        self.packURL = packURL
        _vm = StateObject(wrappedValue: FramePackImportViewModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let fatal = vm.fatalMessage {
                fatalView(fatal)
            } else if vm.packResult == nil {
                ProgressView("Đang xác minh gói…").padding()
            } else {
                content
            }
            Divider()
            footer
        }
        .onAppear { Task { await vm.loadAndValidate(url: packURL) } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.packName.isEmpty ? "Nhập gói khung" : vm.packName).font(.headline)
                if let result = vm.packResult {
                    Text("\(result.manifest.frames.count) khung · \(result.manifest.files.count) tệp")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private func fatalView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36)).foregroundStyle(.red)
            Text("Không thể nhập gói").font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Đóng") { dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !vm.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vm.warnings.enumerated()), id: \.offset) { _, w in
                        Label(w, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.caption)
                    }
                }
                .padding(8)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12).padding(.top, 8)
            }
            if let result = vm.packResult {
                List {
                    Section("Khung trong gói") {
                        ForEach(result.entries, id: \.id) { entry in
                            PackImportRow(entry: entry,
                                          choice: binding(for: entry.frame.frameId),
                                          result: vm.results?[entry.frame.frameId])
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func binding(for frameID: String) -> Binding<PackDuplicatePolicy> {
        Binding(
            get: { vm.choices[frameID]?.policy ?? .skip },
            set: { newPolicy in
                if var c = vm.choices[frameID] {
                    c.policy = newPolicy
                    vm.choices[frameID] = c
                }
            })
    }

    private var footer: some View {
        HStack {
            Button("Hủy") { dismiss() }
            Spacer()
            if vm.isImporting {
                ProgressView()
            }
            PrimaryButton(title: "Nhập", systemImage: "square.and.arrow.down",
                          disabledReason: vm.choices.values.allSatisfy({ !$0.selected }) ? "Chọn ít nhất 1 khung" : nil) {
                vm.applyImport()
            }
            .disabled(vm.isImporting || vm.choices.values.allSatisfy({ !$0.selected }))
        }
        .padding(10)
    }
}

struct PackImportRow: View {
    let entry: PackEntry
    @Binding var choice: PackDuplicatePolicy
    let result: Result<String, String>?

    var body: some View {
        HStack(spacing: 10) {
            ImageDataView(data: entry.thumbnailData)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.frame.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(entry.frame.slots.count) ảnh").font(.caption2).foregroundStyle(.secondary)
                    if entry.isDuplicate {
                        Text("Trùng lặp").font(.caption2)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            Picker("", selection: $choice) {
                ForEach(PackDuplicatePolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .frame(width: 120)
            .labelsHidden()
            if let r = result {
                switch r {
                case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
