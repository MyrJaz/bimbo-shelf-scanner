import SwiftUI
import AVFoundation

// MARK: - ViewModel principal de escaneo

@MainActor
class ScanViewModel: ObservableObject {

    @Published var resultado: ShelfResult?
    @Published var resultadoCaducidad: ExpiryResult?
    @Published var isAnalyzing: Bool = false
    @Published var imagenSeleccionada: UIImage?
    @Published var mostrarPicker: Bool = false

    // Sintetizador reutilizable — se mantiene en memoria para no cortarse entre llamadas
    private let sintetizador = AVSpeechSynthesizer()

    // MARK: - Análisis con IA (huecos + caducidad en paralelo)

    /// Lanza ambos análisis en paralelo con async let.
    /// ShelfClassifier es async; ExpiryDetector es síncrono y se envuelve en Task.detached.
    func analizar() {
        guard let imagen = imagenSeleccionada else { return }

        isAnalyzing = true
        resultado = nil
        resultadoCaducidad = nil

        Task {
            // Ambas tareas corren simultáneamente
            async let shelfResult = ShelfClassifier().classify(image: imagen)
            async let expiryResult = Task.detached(priority: .userInitiated) {
                ExpiryDetector().detect(image: imagen)
            }.value

            let (shelf, expiry) = await (shelfResult, expiryResult)

            // Update de UI en main actor
            self.resultado = shelf
            self.resultadoCaducidad = expiry
            self.isAnalyzing = false

            // Reproducir voz: si hay urgencia de caducidad, ese mensaje va primero
            self.reproducirVozCompleto()
        }
    }

    // MARK: - Síntesis de voz

    /// Reproduce caducidad (si urgente) y luego huecos.
    /// AVSpeechSynthesizer encola los utterances y los reproduce en orden.
    private func reproducirVozCompleto() {
        if sintetizador.isSpeaking {
            sintetizador.stopSpeaking(at: .immediate)
        }

        // 1. Caducidad primero si es urgente
        if let cad = resultadoCaducidad, cad.requiereAtencionUrgente {
            sintetizador.speak(crearUtterance(cad.mensajeVoz))
        }

        // 2. Mensaje de huecos (siempre)
        if let res = resultado {
            sintetizador.speak(crearUtterance(res.mensajeVoz))
        }
    }

    /// Reproduce solo el mensaje de huecos (botón en la card de huecos).
    func reproducirVoz() {
        guard let mensaje = resultado?.mensajeVoz else { return }
        if sintetizador.isSpeaking {
            sintetizador.stopSpeaking(at: .immediate)
        }
        sintetizador.speak(crearUtterance(mensaje))
    }

    /// Reproduce solo el mensaje de caducidad (botón en la card de caducidad).
    func reproducirVozCaducidad() {
        guard let mensaje = resultadoCaducidad?.mensajeVoz else { return }
        if sintetizador.isSpeaking {
            sintetizador.stopSpeaking(at: .immediate)
        }
        sintetizador.speak(crearUtterance(mensaje))
    }

    // MARK: - Helper

    private func crearUtterance(_ texto: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: texto)
        u.voice = AVSpeechSynthesisVoice(language: "es-MX")
        u.rate = 0.50
        return u
    }
}
