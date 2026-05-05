import SwiftUI

// MARK: - Vista principal de escaneo

struct ScanView: View {

    @StateObject var viewModel = ScanViewModel()
    @State private var mostrarAcciones = false
    @State private var fuenteSeleccionada: UIImagePickerController.SourceType = .photoLibrary

    private var camaraDisponible: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    // 1 · Título
                    Text("Análisis de anaquel")
                        .font(.system(.largeTitle, design: .default, weight: .bold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)

                    // 2 · Foto seleccionada
                    if let imagen = viewModel.imagenSeleccionada {
                        Image(uiImage: imagen)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal)
                    }

                    // 3 · Indicador de carga
                    if viewModel.isAnalyzing {
                        ProgressView("Analizando con IA...")
                            .progressViewStyle(.circular)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }

                    // 4 · Card de resultado
                    if let res = viewModel.resultado, !viewModel.isAnalyzing {
                        ResultadoCard(resultado: res) {
                            viewModel.reproducirVoz()
                        }
                        .padding(.horizontal)
                    }

                    Spacer(minLength: 32)

                    // 5 · Botones de acción
                    VStack(spacing: 12) {
                        // Galería — siempre visible
                        Button {
                            fuenteSeleccionada = .photoLibrary
                            viewModel.mostrarPicker = true
                        } label: {
                            Label("Subir foto", systemImage: "photo.on.rectangle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        // Cámara — solo en dispositivo real
                        if camaraDisponible {
                            Button {
                                fuenteSeleccionada = .camera
                                viewModel.mostrarPicker = true
                            } label: {
                                Label("Tomar foto", systemImage: "camera.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 24)
                }
            }
            // 6 · Sheet con el selector de imagen
            .sheet(isPresented: $viewModel.mostrarPicker) {
                ImagePicker(viewModel: viewModel, sourceType: fuenteSeleccionada)
                    .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Card de resultado

private struct ResultadoCard: View {

    let resultado: ShelfResult
    let onReproducir: () -> Void

    private var textoEstado: String {
        switch resultado.estado {
        case .lleno:        return "Anaquel completo"
        case .pocosHuecos:  return "Pocos huecos"
        case .variosHuecos: return "Varios huecos"
        }
    }

    var body: some View {
        VStack(spacing: 16) {

            // Semáforo circular con número de huecos (o checkmark si está lleno)
            ZStack {
                Circle()
                    .fill(resultado.colorSemaforo)
                    .frame(width: 80, height: 80)

                if resultado.huecosEstimados == 0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(resultado.huecosEstimados)")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                }
            }

            Text(textoEstado)
                .font(.system(size: 22, weight: .bold))

            Text("Se estiman \(resultado.huecosEstimados) huecos")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(String(format: "Certeza del modelo: %.0f%%", resultado.confidence * 100))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ProgressView(value: resultado.confidence)
                .tint(resultado.colorSemaforo)

            Button {
                onReproducir()
            } label: {
                Label("Reproducir voz", systemImage: "speaker.wave.2.fill")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.background)
                .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
        )
    }
}

#Preview {
    ScanView()
}
