import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("给 Time Machine 减负")
                    .font(.largeTitle.weight(.bold))

                Text("TMSkip 会找出 node_modules、target 等可再生目录，把它们标记为「不备份」。不删除文件，不上传内容。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    point(title: "默认扫描 ~/", desc: "开箱即用，聚焦用户主目录")
                    point(title: "可审阅可撤销", desc: "忽略列表一目了然")
                    point(title: "看见省了多少", desc: "体积估算帮你做决定")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("需要「完全磁盘访问」权限")
                        .font(.headline)
                    Text("为了扫描主目录并正确读写 Time Machine 排除标记，请授予全盘访问。TMSkip 不会删除或上传你的文件。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("打开系统设置…") {
                            app.openFullDiskAccessSettings()
                        }
                        .buttonStyle(.prominent)

                        Button("我已授权，重新检测") {
                            app.recheckFullDiskAccess()
                        }
                        .buttonStyle(.secondary)
                    }

                    Label(
                        app.fdaService.isGranted ? "已检测到完全磁盘访问权限" : "尚未检测到权限",
                        systemImage: app.fdaService.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(app.fdaService.isGranted ? Color.green : Color.orange, in: Capsule())
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.35))
                )

                if app.fdaService.isGranted {
                    Button {
                        app.finishOnboarding()
                    } label: {
                        Text("进入 TMSkip")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.prominent)
                    .controlSize(.large)
                }
            }
            .padding(28)
            .frame(maxWidth: 520)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(radius: 30, y: 12)
            .padding(24)
        }
    }

    private func point(title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(desc).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
