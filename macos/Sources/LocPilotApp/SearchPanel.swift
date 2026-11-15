import SwiftUI

/// 地点搜索面板：一个输入框 + 结果列表，浮在地图左上角。
///
/// 设计约束（沿用项目既有风格）：
/// * 只用一套玻璃材质（`GlassChrome`），不引入第二种视觉语言；
/// * 搜索走系统地图 `MKLocalSearch`（国内为高德数据），后端 `/api/search` 仅作兜底；
/// * 每条结果都能"跳过去"，所以必须带坐标（`SearchItem`）。
///
/// 位置刻意压在标题栏下方 58pt：左上角是红绿灯（x 9–70、中心 y≈26），
/// 面板若从 14pt 起会把窗口按钮盖住，用户就关不掉窗口了。
struct SearchPanel: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    static let topInset: CGFloat = 58
    static let leadingInset: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            field
            if hasResults || state.searchError != nil {
                Divider().opacity(0.4)
                results
            }
        }
        .frame(width: 320)
        .modifier(GlassChrome(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)))
        .onAppear { focused = true }
        // Esc 关面板：地图类应用里这是肌肉记忆，不指望用户去点那枚 ✕
        .onExitCommand { state.closeSearch() }
    }

    private var hasResults: Bool { !state.searchResults.isEmpty }

    // MARK: - 输入框

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("搜索地点、地址或地标", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onChange(of: state.searchQuery) { _, _ in state.searchQueryDidChange() }
                // 回车直接选第一条：搜索框最常见的用法就是"打几个字 + 回车"
                .onSubmit {
                    guard let first = state.searchResults.first else { return }
                    Task { await state.choose(first) }
                }
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder private var trailing: some View {
        if state.searching {
            ProgressView().controlSize(.mini).scaleEffect(0.7)
        } else if !state.searchQuery.isEmpty {
            Button {
                state.clearSearch()
                focused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("清空")
        } else {
            Button { state.closeSearch() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭搜索（Esc）")
        }
    }

    // MARK: - 结果

    /// 不用 ScrollView：滚视图会把自己撑到可用高度，两条结果下面就留一大片空白。
    /// 结果已经去重且最多 8 条，直接按内容排，面板自然贴合。
    private var results: some View {
        VStack(spacing: 0) {
            ForEach(state.searchResults) { item in
                SearchRow(item: item) {
                    Task { await state.choose(item) }
                }
            }
            if let message = state.searchError {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
    }
}

// MARK: - 单条结果

private struct SearchRow: View {
    let item: SearchItem
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
                    .padding(.horizontal, 5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.subtitle ?? item.title)
    }
}
