import SwiftUI

@main
struct TrackSplitApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 860, height: 760)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                switch model.screen {
                case .waiting: WaitingView()
                case .overview: OverviewView()
                case .running: RunningView()
                case .finished: FinishedView()
                }
                RuntimeFooter()
            }
        }
        .foregroundStyle(Theme.text)
    }
}

struct Logo: View {
    var size: CGFloat
    var body: some View {
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.09))
            .shadow(color: Theme.violet.opacity(0.55), radius: size * 0.12)
    }
}

// MARK: - Waiting for a drive

struct WaitingView: View {
    @EnvironmentObject var model: AppModel
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Logo(size: 240)
                .scaleEffect(pulse ? 1.02 : 0.98)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            VStack(spacing: 10) {
                Text("Conecte o pendrive")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("O TrackSplit detecta automaticamente um pendrive exportado pelo rekordbox\n(com as pastas PIONEER e Contents) e prepara os stems para o XDJ-RX3.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.secondary)
            }
            if let error = model.driveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
            }
            ProgressView().controlSize(.small).tint(Theme.cyan)
            Spacer()
        }
        .padding(40)
    }
}

// MARK: - Drive overview

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let drive = model.drive {
            VStack(spacing: 18) {
                header(drive)
                summary
                playlists(drive)
                startBar
            }
            .padding(.horizontal, 32)
            .padding(.top, 34)
            .padding(.bottom, 16)
        }
    }

    private func header(_ drive: Drive) -> some View {
        HStack(spacing: 18) {
            Logo(size: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pendrive detectado").font(.caption).foregroundStyle(Theme.cyan).textCase(.uppercase)
                Text(drive.name).font(.system(size: 30, weight: .bold, design: .rounded))
                Text("\(drive.tracks.count) músicas · \(drive.playlists.count) playlists · \(Format.bytes(drive.freeBytes)) livres")
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if model.otherDrives.count > 1 {
                Menu("Trocar pendrive") {
                    ForEach(model.otherDrives, id: \.path) { root in
                        Button(Drive.volumeName(root)) { model.load(root) }
                    }
                }
                .fixedSize()
            }
        }
    }

    private var summary: some View {
        let pending = model.pendingTracks
        return HStack(spacing: 14) {
            stat(value: "\(pending.count)", label: "para separar", color: Theme.cyan)
            stat(value: Format.duration(model.estimate(for: pending)), label: "tempo estimado", color: Theme.violet)
            stat(value: "\(model.doneCount)", label: "já prontas", color: Theme.success)
            stat(value: Format.bytes(model.bytesNeeded(for: pending)), label: "espaço necessário", color: Theme.secondary)
        }
    }

    private func stat(value: String, label: String, color: Color) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(color)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.callout).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func playlists(_ drive: Drive) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("O que separar").font(.headline)
                ScrollView {
                    VStack(spacing: 4) {
                        selectionRow(title: "Todas as músicas do pendrive",
                                     detail: "\(drive.tracks.count) músicas · \(drive.tracks.filter(\.hasStems).count) prontas",
                                     isOn: model.allTracks, icon: "externaldrive.fill") {
                            model.allTracks = true
                            model.selectedPlaylists = []
                        }
                        Divider().overlay(Theme.panelStroke).padding(.vertical, 4)
                        ForEach(drive.playlists) { playlist in
                            let counts = model.playlistCounts(playlist)
                            selectionRow(title: playlist.path,
                                         detail: "\(counts.total) músicas · \(counts.done) prontas",
                                         isOn: !model.allTracks && model.selectedPlaylists.contains(playlist.id),
                                         icon: "music.note.list") {
                                model.togglePlaylist(playlist.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                if model.missingCount > 0 {
                    Label("\(model.missingCount) música(s) do banco não foram encontradas no pendrive e serão ignoradas.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.danger)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func selectionRow(title: String, detail: String, isOn: Bool, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isOn ? Theme.cyan : Theme.secondary)
                Image(systemName: icon).foregroundStyle(Theme.violet)
                Text(title).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(detail).foregroundStyle(Theme.secondary).font(.callout)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? Theme.cyan.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var startBar: some View {
        let pending = model.pendingTracks
        let ready = model.runtime == .ready
        let room = model.hasRoomForPending
        let enabled = ready && room && !pending.isEmpty
        return HStack {
            Group {
                if pending.isEmpty {
                    Label("Tudo pronto: todas as músicas selecionadas já têm stems.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.success)
                } else if !room {
                    Label("Espaço insuficiente: faltam \(Format.bytes(model.bytesNeeded(for: pending) + 32 * 1_048_576 - (model.drive?.freeBytes ?? 0))). Escolha menos playlists.",
                          systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(Theme.danger)
                } else if !ready {
                    Label("Aguardando o motor de separação ficar pronto.", systemImage: "hourglass")
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text("Vocal, bateria e baixo · htdemucs_ft no Metal · saída em RX3_STEMS")
                        .foregroundStyle(Theme.secondary).font(.callout)
                }
            }
            Spacer()
            Button("Iniciar") { model.start() }
                .buttonStyle(NeonButtonStyle(enabled: enabled))
                .disabled(!enabled)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Running

struct RunningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Logo(size: 150)
            Text(model.cancelled ? "Cancelando…" : "Separando stems")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Progresso total").font(.headline)
                        Spacer()
                        Text("\(Int((model.overallFraction * 100).rounded()))%")
                            .font(.system(.headline, design: .rounded)).foregroundStyle(Theme.cyan)
                    }
                    NeonProgressBar(value: model.overallFraction, height: 14)
                    HStack {
                        Text("Faixa \(min(model.position + 1, model.queue.count)) de \(model.queue.count)")
                        Spacer()
                        Text("Faltam ≈ \(Format.duration(model.remainingTime))")
                        Text("·").foregroundStyle(Theme.secondary)
                        Text("Decorrido \(Format.duration(model.jobElapsed))").foregroundStyle(Theme.secondary)
                    }
                    .font(.callout)
                }
            }

            if let track = model.currentTrack {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Agora").font(.caption).foregroundStyle(Theme.violet).textCase(.uppercase)
                        Text(track.displayName).font(.title3.weight(.semibold)).lineLimit(1)
                        Text(track.fileURL.lastPathComponent).font(.callout).foregroundStyle(Theme.secondary).lineLimit(1)
                        NeonProgressBar(value: model.trackFraction, height: 8)
                        HStack {
                            Text(model.stageText)
                            Spacer()
                            Text(Format.duration(Double(track.track.duration)))
                        }
                        .font(.callout).foregroundStyle(Theme.secondary)
                    }
                }
            }

            let failed = model.outcomes.filter { !$0.succeeded }.count
            if !model.outcomes.isEmpty {
                Text("\(model.outcomes.count - failed) concluída(s) · \(failed) com erro")
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Cancelar") { model.cancel() }
                .buttonStyle(GhostButtonStyle(tint: Theme.danger))
                .disabled(model.cancelled)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 60)
        .padding(.bottom, 20)
    }
}

// MARK: - Finished

struct FinishedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let succeeded = model.outcomes.filter(\.succeeded)
        let failed = model.outcomes.filter { !$0.succeeded }
        VStack(spacing: 20) {
            Logo(size: 110).padding(.top, 30)
            Text(model.cancelled ? "Separação cancelada" : "Tudo pronto!")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(model.cancelled
                 ? "As faixas concluídas antes do cancelamento já estão no pendrive."
                 : "Pode ejetar o pendrive e levar para o XDJ-RX3.")
                .foregroundStyle(Theme.secondary)

            HStack(spacing: 14) {
                Panel {
                    VStack(alignment: .leading) {
                        Text("\(succeeded.count)").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Theme.success)
                        Text("separadas com sucesso").foregroundStyle(Theme.secondary)
                    }
                }
                Panel {
                    VStack(alignment: .leading) {
                        Text("\(failed.count)").font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(failed.isEmpty ? Theme.secondary : Theme.danger)
                        Text("com erro").foregroundStyle(Theme.secondary)
                    }
                }
                Panel {
                    VStack(alignment: .leading) {
                        Text(Format.duration(model.jobElapsed)).font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.violet).lineLimit(1).minimumScaleFactor(0.5)
                        Text("tempo total").foregroundStyle(Theme.secondary)
                    }
                }
            }

            Panel {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.outcomes.isEmpty {
                            Text("Nenhuma faixa foi processada.").foregroundStyle(Theme.secondary)
                        }
                        ForEach(failed) { outcome in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(outcome.track.fileURL.lastPathComponent).fontWeight(.medium)
                                    Text(outcome.reason ?? "Erro desconhecido").font(.callout)
                                        .foregroundStyle(Theme.secondary).textSelection(.enabled)
                                }
                            }
                        }
                        ForEach(succeeded) { outcome in
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                                Text(outcome.track.fileURL.lastPathComponent).lineLimit(1)
                                Spacer()
                                Text(Format.duration(outcome.seconds)).foregroundStyle(Theme.secondary).font(.callout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 14) {
                if let drive = model.drive {
                    Button("Mostrar RX3_STEMS no Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([drive.stemsDirectory])
                    }
                    .buttonStyle(GhostButtonStyle(tint: Theme.cyan))
                }
                Button("Voltar ao pendrive") { model.backToOverview() }
                    .buttonStyle(NeonButtonStyle())
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 16)
    }
}

// MARK: - Runtime status

struct RuntimeFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            switch model.runtime {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Verificando motor de separação…")
            case .ready:
                Circle().fill(Theme.success).frame(width: 8, height: 8).shadow(color: Theme.success, radius: 4)
                Text("Motor pronto · htdemucs_ft · Apple Silicon (Metal)")
            case .installing(let label, let fraction):
                Text("Preparando motor (só na primeira vez): \(label)").lineLimit(1)
                NeonProgressBar(value: fraction, height: 6).frame(width: 160)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text("Falha ao preparar o motor: \(message)").lineLimit(2).textSelection(.enabled)
                Button("Tentar de novo") { model.prepareRuntime() }.buttonStyle(GhostButtonStyle(tint: Theme.cyan))
            case .noPython:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text("Instale o Python 3.12 (brew install python@3.12 ou python.org) e reabra o TrackSplit.")
                Button("Tentar de novo") { model.prepareRuntime() }.buttonStyle(GhostButtonStyle(tint: Theme.cyan))
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.black.opacity(0.25))
    }
}
