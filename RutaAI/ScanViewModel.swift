import SwiftUI
import AVFoundation
import os.log

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
    private let log = Logger(subsystem: "com.rutaai.shelf", category: "ScanViewModel")

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

    /// Activa la sesión de audio para que iOS permita síntesis de voz en primer plano.
    private func activarSesionAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try session.setActive(true)
        } catch {
            log.warning("AVAudioSession setup falló: \(error.localizedDescription)")
        }
    }

    /// Reproduce caducidad (siempre) y luego huecos.
    /// AVSpeechSynthesizer encola los utterances y los reproduce en orden.
    private func reproducirVozCompleto() {
        activarSesionAudio()
        if sintetizador.isSpeaking {
            sintetizador.stopSpeaking(at: .immediate)
        }

        // 1. Caducidad siempre (urgente primero)
        if let cad = resultadoCaducidad {
            sintetizador.speak(crearUtterance(cad.mensajeVoz))
        }

        // 2. Mensaje de huecos
        if let res = resultado {
            sintetizador.speak(crearUtterance(res.mensajeVoz))
        }
    }

    /// Reproduce solo el mensaje de huecos (botón en la card de huecos).
    func reproducirVoz() {
        guard let mensaje = resultado?.mensajeVoz else { return }
        activarSesionAudio()
        if sintetizador.isSpeaking {
            sintetizador.stopSpeaking(at: .immediate)
        }
        sintetizador.speak(crearUtterance(mensaje))
    }

    /// Reproduce solo el mensaje de caducidad (botón en la card de caducidad).
    func reproducirVozCaducidad() {
        guard let mensaje = resultadoCaducidad?.mensajeVoz else { return }
        activarSesionAudio()
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
