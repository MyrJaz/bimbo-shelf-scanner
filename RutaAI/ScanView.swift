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

                    // 4 · Card de huecos
                    if let res = viewModel.resultado, !viewModel.isAnalyzing {
                        ResultadoCard(resultado: res) {
                            viewModel.reproducirVoz()
                        }
                        .padding(.horizontal)
                    }

                    // 4b · Card de caducidad
                    if let cad = viewModel.resultadoCaducidad, !viewModel.isAnalyzing {
                        CaducidadCard(resultado: cad) {
                            viewModel.reproducirVozCaducidad()
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

            // Si la certeza es 0, estamos en modo diagnóstico — mostrar la razón
            if resultado.confidence < 0.001 {
                Text(resultado.mensajeVoz)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else {
                Text("Se estiman \(resultado.huecosEstimados) huecos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(String(format: "Certeza del modelo: %.0f%%", resultado.confidence * 100))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ProgressView(value: resultado.confidence)
                    .tint(resultado.colorSemaforo)
            }

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

// MARK: - Card de caducidad

private struct CaducidadCard: View {

    let resultado: ExpiryResult
    let onReproducir: () -> Void

    // Ícono según estado de caducidad
    private var icono: String {
        switch resultado.estadoCaducidad {
        case .todo_fresco:     return "checkmark.seal"
        case .revisar_pronto:  return "clock"
        case .retirar_urgente: return "clock.badge.exclamationmark"
        }
    }

    // Color de fondo suave según estado
    private var fondoCard: Color {
        switch resultado.estadoCaducidad {
        case .todo_fresco:     return Color.green.opacity(0.12)
        case .revisar_pronto:  return Color.yellow.opacity(0.12)
        case .retirar_urgente: return Color.red.opacity(0.12)
        }
    }

    // Color del ícono y texto principal
    private var colorAccento: Color {
        switch resultado.estadoCaducidad {
        case .todo_fresco:     return .green
        case .revisar_pronto:  return .orange
        case .retirar_urgente: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Cabecera con ícono y título
            HStack(spacing: 12) {
                Image(systemName: icono)
                    .font(.title2)
                    .foregroundStyle(colorAccento)
                Text("Caducidad")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
            }

            // Tres filas: verde, azul, rojo con su contador
            VStack(spacing: 10) {
                FilaContador(color: .green, etiqueta: "frescas",   cantidad: resultado.etiquetasVerdes)
                FilaContador(color: .blue,  etiqueta: "por revisar", cantidad: resultado.etiquetasAzules)
                FilaContador(color: .red,   etiqueta: "por retirar", cantidad: resultado.etiquetasRojas)
            }

            // Banner de urgencia solo si hay rojas
            if resultado.requiereAtencionUrgente {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Retira estos productos hoy")
                        .font(.callout.bold())
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Botón para reproducir solo el mensaje de caducidad
            Button {
                onReproducir()
            } label: {
                Label("Reproducir voz", systemImage: "speaker.wave.2.fill")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .tint(colorAccento)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(fondoCard)
        )
    }
}

// MARK: - Fila individual con círculo de color y contador

private struct FilaContador: View {
    let color: Color
    let etiqueta: String
    let cantidad: Int

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
            Text("\(cantidad) \(etiqueta)")
                .font(.body)
            Spacer()
        }
    }
}

#Preview {
    ScanView()
}
