import SwiftUI
import AVFoundation

// MARK: - ViewModel principal de escaneo

@MainActor
class ScanViewModel: ObservableObject {

    @Published var resultado: ShelfResult?
    @Published var isAnalyzing: Bool = false
    @Published var imagenSeleccionada: UIImage?
    @Published var mostrarPicker: Bool = false

    // Sintetizador reutilizable — se mantiene en memoria para no cortarse entre llamadas
    private let sintetizador = AVSpeechSynthesizer()

    // MARK: - Análisis con IA

    /// Toma la imagen actual, invoca el clasificador CoreML y actualiza el estado publicado.
    func analizar() {
        guard let imagen = imagenSeleccionada else { return }

        isAnalyzing = true
        resultado = nil

        Task {
            let clasificador = ShelfClassifier()
            let res = await clasificador.classify(image: imagen)

            // Ya estamos en @MainActor, la actualización de UI es directa
            self.resultado = res
            self.isAnalyzing = false
            self.reproducirVoz()
        }
    }

    // MARK: - Síntesis de voz

    /// Reproduce en voz alta el mensaje del último resultado.
    /// Usa voz es-MX con velocidad moderada (0.50).
    func reproducirVoz() {
        guard let mensaje = resultado?.mensajeVoz else { return }

        if sintetizador.isSpeaking {
            sintetizador.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: mensaje)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-MX")
        utterance.rate = 0.50

        sintetizador.speak(utterance)
    }
}
