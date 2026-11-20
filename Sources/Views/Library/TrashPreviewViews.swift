import SwiftUI

struct TrashPreviewImage: View {
    let item: TrashItem
    let env: AppEnvironment
    var photoID: String? = nil
    let maxPixel: Int
    @State private var image: CGImage?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image {
                Image(image, scale: 1, label: Text(item.displayName)).resizable().scaledToFit()
            } else if let error {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                    if maxPixel > 120 {
                        Text(error).font(.caption).multilineTextAlignment(.center)
                        Button("Thử lại") { retry += 1 }
                    }
                }.help(error).accessibilityLabel(error)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(item.id):\(photoID ?? "cover"):\(retry)") {
            image = nil
            error = nil
            do {
                let result = try await env.trashPreviews.image(item: item, photoID: photoID, maxPixel: maxPixel)
                guard !Task.isCancelled else { return }
                image = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = (error as? AppError)?.message ?? "Không thể đọc ảnh xem trước"
            }
        }
    }
}

struct TrashPreviewSheet: View {
    let item: TrashItem
    @ObservedObject var env: AppEnvironment
    let onClose: () -> Void
    @State private var photos: [TrashService.PreviewPhoto] = []
    @State private var selected: String?
    @State private var listState = PhotoListState.loading
    @State private var listRetry = 0
    @State private var listItemID: String?
    @State private var loadGeneration: UUID?

    private enum PhotoListState {
        case loading, ready
        case failed(String)
    }

    private struct PhotoListRequest: Equatable {
        let itemID: String
        let retry: Int
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(item.displayName).font(.headline).lineLimit(2)
                Spacer()
                Button("Đóng", action: onClose).keyboardShortcut(.cancelAction)
            }
            TrashPreviewImage(item: item, env: env, photoID: listItemID == item.id ? selected : nil, maxPixel: 1600)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if item.rootType == .session {
                Text("Xem ảnh trong phiên. Khôi phục và xóa vĩnh viễn áp dụng cho cả phiên.")
                    .font(.caption).foregroundStyle(.secondary)
                photoList.frame(height: 100)
            }
        }
        .padding(20).frame(minWidth: 520, idealWidth: 800, minHeight: 500, idealHeight: 680)
        .task(id: PhotoListRequest(itemID: item.id, retry: listRetry)) {
            guard item.rootType == .session else { return }
            await loadPhotoList()
        }
        .task(id: item.id) {
            for await event in EventBus.shared.stream {
                if case .trashChanged = event {
                    let repo = env.trashRepo
                    let fresh = try? await Task.detached { try repo.getItem(id: item.id) }.value
                    if fresh == nil { onClose(); return }
                }
            }
        }
    }

    @ViewBuilder private var photoList: some View {
        if listItemID != item.id {
            ProgressView("Đang tải danh sách ảnh…").controlSize(.small)
        } else {
            switch listState {
            case .loading:
                ProgressView("Đang tải danh sách ảnh…").controlSize(.small)
            case .failed(let message):
                VStack(spacing: 6) {
                    Text(message).font(.caption).lineLimit(2).help(message)
                        .foregroundStyle(.secondary).accessibilityLabel(message)
                    Button("Thử lại") {
                        listState = .loading
                        listRetry += 1
                    }
                }
            case .ready where photos.isEmpty:
                Text("Phiên không có ảnh xem trước.").font(.caption).foregroundStyle(.secondary)
            case .ready:
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(photos) { photo in
                            Button { selected = photo.id } label: {
                                VStack {
                                    TrashPreviewImage(item: item, env: env, photoID: photo.id, maxPixel: 120)
                                        .frame(width: 80, height: 60)
                                    Text(photo.label).font(.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(selected == photo.id ? .accentColor : nil)
                        }
                    }
                }
            }
        }
    }

    @MainActor private func loadPhotoList() async {
        let generation = UUID()
        loadGeneration = generation
        if listItemID != item.id {
            photos = []
            selected = nil
            listItemID = item.id
        }
        listState = .loading
        do {
            let result = try await env.trashPreviews.photos(item: item)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            photos = result
            if !result.contains(where: { $0.id == selected }) {
                selected = result.first?.id
            }
            listState = .ready
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            listState = .failed((error as? AppError)?.message ?? error.localizedDescription)
        }
    }
}
