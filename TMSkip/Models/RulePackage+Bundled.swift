import Foundation

extension RulePackage {
    /// Offline fallback snapshot. Always available; never depends on network.
    /// Aligned with Asimov `data/sentinels.tsv` (upstream v0.12.0) + tmexclude defaults.
    static var bundledSnapshot: RulePackage {
        // Multiple exclude names for the same ecosystem are separate rules when
        // if-exists sets differ; same-name excludes with different sentinels stay separate.
        // Sentinel globs (`*.csproj` etc.) follow upstream Asimov and are matched by
        // ScanEngine as glob patterns.
        let rules: [RuleDefinition] = [
            // .NET
            .init(id: "dotnet-csproj", name: "MSBuild (C#)", excludes: ["bin", "obj"], ifExists: ["*.csproj"], group: ".NET", isEnabled: true),
            .init(id: "dotnet-fsproj", name: "MSBuild (F#)", excludes: ["bin", "obj"], ifExists: ["*.fsproj"], group: ".NET", isEnabled: true),
            // Node
            .init(id: "npm", name: "npm / Yarn", excludes: ["node_modules"], ifExists: ["package.json"], group: "Node.js", isEnabled: true),
            .init(id: "parcel-cache", name: "Parcel cache", excludes: [".parcel-cache"], ifExists: ["package.json"], group: "Node.js", isEnabled: true),
            .init(id: "bower", name: "Bower", excludes: ["bower_components"], ifExists: ["bower.json"], group: "Node.js", isEnabled: false),
            .init(id: "angular", name: "Angular", excludes: [".angular"], ifExists: ["angular.json"], group: "Node.js", isEnabled: true),
            .init(id: "nextjs", name: "Next.js", excludes: [".next"], ifExists: ["package.json"], group: "Node.js", isEnabled: true),
            .init(id: "nuxt", name: "Nuxt", excludes: [".nuxt"], ifExists: ["package.json"], group: "Node.js", isEnabled: true),
            .init(id: "svelte-kit", name: "SvelteKit", excludes: [".svelte-kit"], ifExists: ["svelte.config.js"], group: "Node.js", isEnabled: true),
            .init(id: "turbo", name: "Turborepo", excludes: [".turbo"], ifExists: ["turbo.json"], group: "Node.js", isEnabled: true),
            .init(id: "yarn-berry", name: "Yarn Berry", excludes: [".yarn"], ifExists: [".yarnrc.yml"], group: "Node.js", isEnabled: true),
            .init(id: "moonrepo", name: "moonrepo cache", excludes: ["cache"], ifExists: ["workspace.yml"], group: "Node.js", isEnabled: true),
            // Rust / JVM
            .init(id: "cargo", name: "Cargo (Rust)", excludes: ["target"], ifExists: ["Cargo.toml"], group: "Rust", isEnabled: true),
            .init(id: "maven", name: "Maven", excludes: ["target"], ifExists: ["pom.xml"], group: "JVM", isEnabled: true),
            .init(id: "sbt", name: "Sbt (Scala)", excludes: ["target"], ifExists: ["build.sbt"], group: "JVM", isEnabled: true),
            .init(id: "sbt-plugins", name: "Sbt plugins", excludes: ["target"], ifExists: ["plugins.sbt"], group: "JVM", isEnabled: true),
            .init(id: "gradle", name: "Gradle", excludes: ["build", ".gradle"], ifExists: ["build.gradle"], group: "JVM", isEnabled: true),
            .init(id: "gradle-kts", name: "Gradle KTS", excludes: ["build", ".gradle"], ifExists: ["build.gradle.kts"], group: "JVM", isEnabled: true),
            // Apple
            .init(id: "spm", name: "SwiftPM", excludes: [".build"], ifExists: ["Package.swift"], group: "Apple", isEnabled: true),
            .init(id: "pods", name: "CocoaPods", excludes: ["Pods"], ifExists: ["Podfile"], group: "Apple", isEnabled: true),
            .init(id: "carthage", name: "Carthage", excludes: ["Carthage"], ifExists: ["Cartfile"], group: "Apple", isEnabled: true),
            .init(id: "xcode-deriveddata", name: "Xcode DerivedData", excludes: ["DerivedData"], ifExists: ["*.xcodeproj"], group: "Apple", isEnabled: true),
            // Python
            .init(id: "python-venv-req", name: "Python venv (requirements)", excludes: ["venv", ".venv"], ifExists: ["requirements.txt"], group: "Python", isEnabled: true),
            .init(id: "python-venv-pyproject", name: "Python venv (pyproject)", excludes: ["venv", ".venv"], ifExists: ["pyproject.toml"], group: "Python", isEnabled: true),
            .init(id: "python-tox", name: "Tox", excludes: [".tox"], ifExists: ["tox.ini"], group: "Python", isEnabled: true),
            .init(id: "python-nox", name: "Nox", excludes: [".nox"], ifExists: ["noxfile.py"], group: "Python", isEnabled: true),
            .init(id: "python-dist", name: "PyPI dist/build", excludes: ["dist", "build"], ifExists: ["setup.py"], group: "Python", isEnabled: true),
            .init(id: "python-pypackages", name: "PEP 582 packages", excludes: ["__pypackages__"], ifExists: ["pyproject.toml"], group: "Python", isEnabled: true),
            // PHP / Ruby / Go
            .init(id: "composer", name: "Composer", excludes: ["vendor"], ifExists: ["composer.json"], group: "PHP", isEnabled: true),
            .init(id: "bundler", name: "Bundler", excludes: ["vendor"], ifExists: ["Gemfile"], group: "Ruby", isEnabled: true),
            .init(id: "go", name: "Go Modules", excludes: ["vendor"], ifExists: ["go.mod"], group: "Go", isEnabled: true),
            // Dart
            .init(id: "flutter-build", name: "Flutter build", excludes: ["build"], ifExists: ["pubspec.yaml"], group: "Dart", isEnabled: true),
            .init(id: "dart-tool", name: "Dart tool", excludes: [".dart_tool", ".packages"], ifExists: ["pubspec.yaml"], group: "Dart", isEnabled: true),
            // Clojure
            .init(id: "clojure-cpcache", name: "Clojure CLI cache", excludes: [".cpcache"], ifExists: ["deps.edn"], group: "Clojure", isEnabled: true),
            .init(id: "clojure-cli", name: "Clojure CLI", excludes: ["target"], ifExists: ["deps.edn"], group: "Clojure", isEnabled: true),
            .init(id: "leiningen", name: "Leiningen", excludes: ["target"], ifExists: ["project.clj"], group: "Clojure", isEnabled: true),
            .init(id: "shadow-cljs", name: "ClojureScript", excludes: [".shadow-cljs"], ifExists: ["shadow-cljs.edn"], group: "Clojure", isEnabled: true),
            // Elixir / Haskell
            .init(id: "mix-deps", name: "Mix deps", excludes: ["deps"], ifExists: ["mix.exs"], group: "Elixir", isEnabled: true),
            .init(id: "mix-build", name: "Mix build", excludes: ["_build", ".build"], ifExists: ["mix.exs"], group: "Elixir", isEnabled: true),
            .init(id: "stack", name: "Stack (Haskell)", excludes: [".stack-work"], ifExists: ["stack.yaml"], group: "Haskell", isEnabled: true),
            // Elm / Godot / OCaml / R / Zig
            .init(id: "elm", name: "Elm", excludes: ["elm-stuff"], ifExists: ["elm.json"], group: "Elm", isEnabled: true),
            .init(id: "godot", name: "Godot", excludes: [".godot"], ifExists: ["project.godot"], group: "Godot", isEnabled: true),
            .init(id: "ocaml-dune", name: "Dune (OCaml)", excludes: ["_build"], ifExists: ["dune-project"], group: "OCaml", isEnabled: true),
            .init(id: "r-renv", name: "R renv", excludes: ["renv"], ifExists: ["renv.lock"], group: "R", isEnabled: true),
            .init(id: "zig-cache", name: "Zig cache", excludes: [".zig-cache"], ifExists: ["build.zig"], group: "Zig", isEnabled: true),
            .init(id: "zig-out", name: "Zig build output", excludes: ["zig-out"], ifExists: ["build.zig"], group: "Zig", isEnabled: true),
            // Shell
            .init(id: "direnv", name: "direnv", excludes: [".direnv"], ifExists: [".envrc"], group: "Shell", isEnabled: true),
            // Other / Infra (legacy or noisy — off by default)
            .init(id: "vagrant", name: "Vagrant", excludes: [".vagrant"], ifExists: ["Vagrantfile"], group: "Other", isEnabled: false),
            .init(id: "terraform", name: "Terraform plugin cache", excludes: [".terraform.d"], ifExists: [".terraformrc"], group: "Infra", isEnabled: false),
            .init(id: "terraform-lock", name: "Terraform modules", excludes: [".terraform"], ifExists: [".terraform.lock.hcl"], group: "Infra", isEnabled: false),
            .init(id: "terragrunt", name: "Terragrunt cache", excludes: [".terragrunt-cache"], ifExists: ["terragrunt.hcl"], group: "Infra", isEnabled: false),
            .init(id: "cdk", name: "AWS CDK", excludes: ["cdk.out"], ifExists: ["cdk.json"], group: "Infra", isEnabled: false),
        ]

        return RulePackage(
            version: "2026.09-bundled",
            origin: .bundled,
            source: "Asimov 兼容内置快照（随 App 发布）",
            syncedAt: nil,
            upstreamURL: "https://github.com/stevegrunwell/asimov",
            rules: rules
        )
    }
}
