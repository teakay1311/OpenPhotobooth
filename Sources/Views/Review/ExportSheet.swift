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
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                        if let preview = vm.previewImage {
                            Image(nsImage: NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height)))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .padding(8)
                        } else if vm.isPreviewLoading {
                            ProgressView()
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "photo")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.secondary)
                                Text(vm.previewUnavailable ? "Không tạo được xem trước. Hãy kiểm tra ảnh và khung." : "Xem trước ảnh xuất")
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 8)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if vm.isPreviewLoading && vm.previewImage != nil {
                            ProgressView()
                                .padding(6)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .frame(width: 210, height: 270)
                    Text("\(vm.width) × \(vm.height) px • \(vm.format.fileExtension.uppercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)

                Form {
                    Picker("Định dạng", selection: $vm.format) {
                        Text("JPG").tag(ExportImageFormat.jpeg)
                        Text("PNG").tag(ExportImageFormat.png)
                    }
                    .onChange(of: vm.format) { _ in vm.updatePreview() }
                    if vm.format == .jpeg {
                        HStack {
                            Text("Chất lượng")
                            Slider(value: Binding(
                                get: { Double(vm.quality) },
                                set: { vm.quality = Int($0) }), in: 1...100)
                            Text("\(vm.quality)%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .onChange(of: vm.quality) { vm.updatePreview() }
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
                .disabled(vm.isExporting)
                .padding(.trailing, 16)
            }

            if let err = vm.errorMessage {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            if let warning = vm.finderWarning {
                Text(warning).foregroundStyle(.orange).font(.caption)
            }
            if let url = vm.lastResultURL {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: vm.historySaveFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(vm.historySaveFailed ? .orange : .green)
                        Text("Đã lưu tệp: \(url.lastPathComponent)")
                        Spacer()
                        Button("Hiện trong Finder") { vm.revealResult() }
                    }
                    if let warning = vm.historyWarning {
                        Text(warning).foregroundStyle(.orange).font(.caption)
                    }
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
                PrimaryButton(title: "Xuất", systemImage: "square.and.arrow.down",
                              disabledReason: vm.folderURL == nil ? "Chọn thư mục xuất" : (vm.canExportPreview ? nil : "Chờ xem trước hợp lệ")) {
                    Task {
                        // KHÔNG gọi configure(detail:) lần nữa — nó reset filename/width/height
                        // và xóa sạch dữ liệu người dùng vừa nhập (P1-13). configure chỉ chạy ở onAppear.
                        vm.review = reviewVM
                        await vm.runExport()
                    }
                }
                .disabled(vm.isExporting || !vm.canExportPreview)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .frame(width: 660, height: 530)
        .onChange(of: reviewVM.detail?.session.revisionNo) { vm.updatePreview() }
        .onChange(of: reviewVM.detail?.snapshot.id) { vm.updatePreview() }
        .onDisappear { vm.cancelResultReveal() }
        .onAppear {
            vm.review = reviewVM
            if let detail = reviewVM.detail {
                vm.configure(detail: detail)
            }
        }
    }
}
