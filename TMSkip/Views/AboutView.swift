import SwiftUI

struct AboutView: View {
    @EnvironmentObject private var app: AppModel
    @State private var githubHovered = false

    /// From build settings (MARKETING_VERSION), so releases stay in sync.
    private static var displayVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private static let githubURL = URL(string: "https://github.com/JosephusZhou/TMSkip")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("关于 TMSkip")
                .font(.largeTitle.weight(.bold))
            Text("把可再生目录移出 Time Machine")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        Text("TMSkip").font(.title2.weight(.bold))
                        Text("v\(Self.displayVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                githubRow

                HStack {
                    Button("重看权限引导") { app.showOnboardingAgain() }
                        .buttonStyle(.secondary)
                        .controlSize(.large)
                    Button("重新检测权限") { app.recheckFullDiskAccess() }
                        .buttonStyle(.secondary)
                        .controlSize(.large)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))

            Spacer()
        }
        .padding(20)
    }

    private var githubRow: some View {
        Link(destination: Self.githubURL) {
            HStack(spacing: 10) {
                Image("GitHubMark")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("github.com/JosephusZhou/TMSkip")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(githubHovered ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(githubHovered ? Color.primary.opacity(0.07) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                githubHovered = hovering
            }
        }
        .help("在浏览器中打开 GitHub 仓库")
    }
}
