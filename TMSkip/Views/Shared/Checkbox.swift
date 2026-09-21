import SwiftUI

/// 三态勾选框状态
enum CheckboxState {
    case off
    case partial
    case on
}

/// 自定义方形圆角勾选框，统一 App 内列表勾选样式。
/// 选中时蓝色填充 + 白色对勾；半选时蓝色填充 + 白色横条；未选中时白底灰边。
/// `action` 为 nil 时纯展示（适合嵌入外层 Button / 带标签场景）。
struct Checkbox: View {
    let state: CheckboxState
    let action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .frame(width: 14, height: 14)
    }

    private var content: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5)
                .fill(filled ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            if state == .on {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            } else if state == .partial {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white)
                    .frame(width: 8, height: 2)
            }
        }
        .frame(width: 14, height: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(filled ? Color.clear : Color(nsColor: .separatorColor))
        }
        .contentShape(Rectangle())
    }

    private var filled: Bool { state != .off }
}

extension Checkbox {
    /// 便利初始化：简单的选中/未选中两态
    init(isOn: Bool, action: @escaping (Bool) -> Void) {
        self.state = isOn ? .on : .off
        self.action = { action(!isOn) }
    }
}
