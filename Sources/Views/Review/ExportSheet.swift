import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// ExportSheet (§2.9): format/quality/size/name/folder + tiến độ.
/// Sử dụng ExportViewModel đã có sẵn.
public struct ExportSheet: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var reviewVM: ReviewViewModel
    @StateObject private var vm: ExportViewModel
    @Environment(\.dismiss) private var dismiss

    public init(env: AppEnvironment, reviewVM: ReviewViewModel) {
        self.env = env
        self.reviewVM = reviewVM
        _vm = StateObject(wrappedValue: ExportViewModel(env: env))
    }

    public var body: some View {
        VStack(spacing: 14) {
            Text("Xuất ảnh").font(.headline)
            Form {
                Picker("Định dạng", selection: $vm.format) {
                    Text("JPG").tag(ExportImageFormat.jpeg)
                    Text("PNG").tag(ExportImageFormat.png)
                }
                if vm.format == .jpeg {
                    HStack {
                        Text("Chất lượng")
                        Slider(value: Binding(
                            get: { Double(vm.quality) },
                            set: { vm.quality = Int($0) }), in: 1...100)
                        Text("\(vm.quality)%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Stepper("Rộng: \(vm.width)", value: Binding(
                        get: { vm.width },
                        set: { vm.setWidth($0) }), in: 256...8192, step: 50)
                }
                HStack {
                    Stepper("Cao: \(vm.height)", value: Binding(
                        get: { vm.height },
                        set: { vm.setHeight($0) }), in: 256...8192, step: 50)
                }
                Toggle("Khóa tỉ lệ", isOn: $vm.aspectLocked)
                HStack {
                    Text("Tên file")
                    TextField("Tên", text: $vm.filename).textFieldStyle(.roundedBorder)
                    Text(vm.format.fileExtension).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Thư mục")
                    Spacer()
                    Button(vm.folderURL?.lastPathComponent ?? "Chọn…") {
                        vm.chooseFolder()
                    }
                }
                Toggle("Ghi đè file trùng", isOn: $vm.replaceExisting)
            }
            .formStyle(.grouped)

            if let err = vm.errorMessage {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            if let url = vm.lastResultURL {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Đã xuất: \(url.lastPathComponent)")
                    Spacer()
                    Button("Hiện trong Finder") { vm.revealResult() }
                }
                .padding(.horizontal)
            }

            HStack {
                Button("Hủy") { dismiss() }
                Spacer()
                if vm.isExporting {
                    ProgressView()
                } else if vm.lastResultURL != nil {
                    Button("Xong") { dismiss() }
                }
                PrimaryButton(title: "Xuất", systemImage: "square.and.arrow.up",
                              disabledReason: vm.folderURL == nil ? "Chọn thư mục xuất" : nil) {
                    Task {
                        // KHÔNG gọi configure(detail:) lần nữa — nó reset filename/width/height
                        // và xóa sạch dữ liệu người dùng vừa nhập (P1-13). configure chỉ chạy ở onAppear.
                        vm.review = reviewVM
                        await vm.runExport()
                    }
                }
                .disabled(vm.isExporting)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 560, height: 560)
        .onAppear {
            vm.review = reviewVM
            if let detail = reviewVM.detail {
                vm.configure(detail: detail)
            }
        }
    }
}
