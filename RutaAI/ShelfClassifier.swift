import Vision
import CoreML
import SwiftUI
import UIKit
import os.log

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

    private let log = Logger(subsystem: "com.rutaai.shelf", category: "ShelfClassifier")

    // MARK: - Carga del modelo

    /// Intenta cargar el modelo de varias maneras y reporta exactamente qué falla.
    private func cargarModelo() -> (VNCoreMLModel?, String) {
        // Paso 1: ¿está el .mlmodelc en el bundle?
        let bundleURL = Bundle.main.url(forResource: "BimboShelfClassifier", withExtension: "mlmodelc")
        log.debug("URL .mlmodelc en bundle: \(String(describing: bundleURL))")

        // Paso 2: configurar para CPU (simulador no tiene Neural Engine)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly

        // Paso 3: usar la clase auto-generada
        do {
            let generated = try BimboShelfClassifier(configuration: config)
            let vn = try VNCoreMLModel(for: generated.model)
            log.debug("Modelo cargado vía clase auto-generada ✓")
            return (vn, "ok")
        } catch {
            log.error("Falló clase auto-generada: \(error.localizedDescription)")
        }

        // Paso 4: fallback — cargar directo desde la URL del bundle
        if let url = bundleURL {
            do {
                let mlModel = try MLModel(contentsOf: url, configuration: config)
                let vn = try VNCoreMLModel(for: mlModel)
                log.debug("Modelo cargado vía Bundle URL ✓")
                return (vn, "ok")
            } catch {
                log.error("Falló carga desde URL: \(error.localizedDescription)")
                return (nil, "Error cargando modelo: \(error.localizedDescription)")
            }
        }

        return (nil, "BimboShelfClassifier no está en el bundle")
    }

    // MARK: - Reglas de negocio

    private func calcularHuecos(clase: String, confidence: Double) -> Int {
        switch clase {
        case "lleno":
            return 0
        case "pocos_huecos":
            switch confidence {
            case 0.5..<0.7:  return 3
            case 0.7..<0.85: return 5
            default:         return 6
            }
        case "varios_huecos":
            switch confidence {
            case 0.5..<0.7:  return 7
            case 0.7..<0.85: return 10
            default:         return 14
            }
        default:
            return 0
        }
    }

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

    private func mapearEstado(clase: String) -> (EstadoAnaquel, Color) {
        switch clase {
        case "lleno":         return (.lleno,        .green)
        case "pocos_huecos":  return (.pocosHuecos,  .orange)
        case "varios_huecos": return (.variosHuecos, .red)
        default:              return (.variosHuecos, .red)
        }
    }

    /// Mock con razón específica para que la UI muestre qué falló.
    private func resultadoMock(razon: String) -> ShelfResult {
        ShelfResult(
            estado: .variosHuecos,
            confidence: 0.0,
            huecosEstimados: 0,
            mensajeVoz: "Diagnóstico: \(razon)",
            colorSemaforo: .gray
        )
    }

    // MARK: - Caja para evitar doble-resume

    private final class Box: @unchecked Sendable {
        var resumed = false
        let continuation: CheckedContinuation<ShelfResult, Never>
        init(_ c: CheckedContinuation<ShelfResult, Never>) { continuation = c }
        func resume(_ result: ShelfResult) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: result)
        }
    }

    // MARK: - Clasificación principal

    func classify(image: UIImage) async -> ShelfResult {
        log.debug("classify() llamado")

        guard let cgImage = image.cgImage else {
            log.error("UIImage sin cgImage")
            return resultadoMock(razon: "Imagen sin cgImage")
        }

        let (modeloOpt, razon) = cargarModelo()
        guard let vnModel = modeloOpt else {
            return resultadoMock(razon: razon)
        }

        return await withCheckedContinuation { continuation in
            let box = Box(continuation)

            let request = VNCoreMLRequest(model: vnModel) { req, error in
                if let error = error {
                    self.log.error("VNCoreMLRequest error: \(error.localizedDescription)")
                    box.resume(self.resultadoMock(razon: "Vision: \(error.localizedDescription)"))
                    return
                }
                guard let observations = req.results as? [VNClassificationObservation] else {
                    self.log.error("Resultados no son VNClassificationObservation")
                    box.resume(self.resultadoMock(razon: "Resultados con tipo inesperado"))
                    return
                }
                guard let top = observations.first else {
                    self.log.error("Sin observaciones")
                    box.resume(self.resultadoMock(razon: "Sin observaciones"))
                    return
                }

                self.log.debug("Top: \(top.identifier) confidence=\(top.confidence)")
                for obs in observations {
                    self.log.debug("  - \(obs.identifier): \(obs.confidence)")
                }

                let clase      = top.identifier
                let confidence = Double(top.confidence)
                let huecos     = self.calcularHuecos(clase: clase, confidence: confidence)
                let mensaje    = self.mensajeParaHuecos(clase: clase, huecos: huecos)
                let (estado, color) = self.mapearEstado(clase: clase)

                box.resume(ShelfResult(
                    estado: estado,
                    confidence: confidence,
                    huecosEstimados: huecos,
                    mensajeVoz: mensaje,
                    colorSemaforo: color
                ))
            }
            request.imageCropAndScaleOption = .centerCrop

            // CoreML síncrono fuera del cooperative thread pool de Swift Concurrency
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])
                    // Si perform regresó sin throw, el completion ya se llamó
                } catch {
                    self.log.error("handler.perform throw: \(error.localizedDescription)")
                    box.resume(self.resultadoMock(razon: "Handler: \(error.localizedDescription)"))
                }
            }
        }
    }
}
