import Vision
import CoreML
import SwiftUI
import UIKit

// MARK: - Tipos de resultado

enum EstadoAnaquel {
    case lleno
    case pocosHuecos
    case variosHuecos
}

struct ShelfResult {
    let estado: EstadoAnaquel
    let confidence: Double
    let huecosEstimados: Int
    let mensajeVoz: String
    let colorSemaforo: Color
}

// MARK: - Clasificador principal

class ShelfClassifier {

    // Usa la clase auto-generada por Xcode. Fuerza CPU para funcionar en simulador
    // (el simulador no tiene Neural Engine — "espresso context" falla con GPU/ANE).
    private func cargarModelo() -> VNCoreMLModel? {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly
            let model = try BimboShelfClassifier(configuration: config)
            return try VNCoreMLModel(for: model.model)
        } catch {
            return nil
        }
    }

    // Determina cuántos huecos estimar según clase y nivel de confianza
    private func calcularHuecos(clase: String, confidence: Double) -> Int {
        switch clase {
        case "lleno":
            return 0
        case "pocos_huecos":
            switch confidence {
            case 0.5..<0.7:  return 3
            case 0.7..<0.85: return 5
            default:         return 6  // 0.85 – 1.0
            }
        case "varios_huecos":
            switch confidence {
            case 0.5..<0.7:  return 7
            case 0.7..<0.85: return 10
            default:         return 14 // 0.85 – 1.0
            }
        default:
            return 0
        }
    }

    // Mensaje de voz en español mexicano natural según estado y huecos
    private func mensajeParaHuecos(clase: String, huecos: Int) -> String {
        switch clase {
        case "lleno":
            return "Anaquel completo, todo en orden"
        case "pocos_huecos":
            switch huecos {
            case 3:  return "Faltan como tres productos, hay que surtir"
            case 5:  return "Faltan unos cinco productos, surte pronto"
            default: return "Faltan seis productos, ya hay que surtir"
            }
        case "varios_huecos":
            switch huecos {
            case 7:  return "Hay varios huecos, faltan como siete piezas"
            case 10: return "Bastantes huecos, surte unas diez piezas"
            default: return "El anaquel está muy vacío, surte catorce piezas urgente"
            }
        default:
            return "No se pudo determinar el estado del anaquel"
        }
    }

    // Mapea la clase string al enum y su color de semáforo
    private func mapearEstado(clase: String) -> (EstadoAnaquel, Color) {
        switch clase {
        case "lleno":         return (.lleno,        .green)
        case "pocos_huecos":  return (.pocosHuecos,  .orange)
        case "varios_huecos": return (.variosHuecos, .red)
        default:              return (.variosHuecos, .red)
        }
    }

    // Resultado de fallback cuando el modelo .mlmodel no está en el bundle
    private func resultadoMock() -> ShelfResult {
        ShelfResult(
            estado: .variosHuecos,
            confidence: 0.0,
            huecosEstimados: 5,
            mensajeVoz: "Modo demo - modelo no encontrado",
            colorSemaforo: .orange
        )
    }

    // MARK: - Clasificación principal

    /// Analiza una imagen y regresa el estado del anaquel.
    /// Task.detached evita el warning "unsafeForcedSync" al correr CoreML
    /// fuera del cooperative thread pool de Swift Concurrency.
    func classify(image: UIImage) async -> ShelfResult {
        guard let cgImage = image.cgImage else { return resultadoMock() }

        return await Task.detached(priority: .userInitiated) { [self] in
            guard let vnModel = self.cargarModelo() else { return self.resultadoMock() }

            var resultado = self.resultadoMock()

            let request = VNCoreMLRequest(model: vnModel) { req, _ in
                guard let observations = req.results as? [VNClassificationObservation],
                      let top = observations.first else { return }

                let clase      = top.identifier
                let confidence = Double(top.confidence)
                let huecos     = self.calcularHuecos(clase: clase, confidence: confidence)
                let mensaje    = self.mensajeParaHuecos(clase: clase, huecos: huecos)
                let (estado, color) = self.mapearEstado(clase: clase)

                resultado = ShelfResult(
                    estado: estado,
                    confidence: confidence,
                    huecosEstimados: huecos,
                    mensajeVoz: mensaje,
                    colorSemaforo: color
                )
            }

            request.imageCropAndScaleOption = .centerCrop
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            return resultado
        }.value
    }
}
