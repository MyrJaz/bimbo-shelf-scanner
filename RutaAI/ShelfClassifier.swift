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

    // MARK: - Carga del modelo (probando varios computeUnits)

    private func cargarModelo(units: MLComputeUnits) -> BimboShelfClassifier? {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try BimboShelfClassifier(configuration: config)
        } catch {
            log.warning("Load \(String(describing: units)) falló: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Reglas de negocio

    private func calcularHuecos(clase: String, confidence: Double) -> Int {
        switch clase {
        case "lleno":         return 0
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
        default: return 0
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

    private func resultadoMock(razon: String) -> ShelfResult {
        ShelfResult(
            estado: .variosHuecos,
            confidence: 0.0,
            huecosEstimados: 0,
            mensajeVoz: razon,
            colorSemaforo: .gray
        )
    }

    // MARK: - Helpers de imagen

    /// Convierte UIImage a CVPixelBuffer (BGRA) del tamaño deseado.
    /// Se usa para `prediction(image:)` directo, sin pasar por Vision.
    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        return buffer
    }

    // MARK: - Estrategia 1: Vision + VNCoreMLRequest

    private func clasificarConVision(image: UIImage, modelo: BimboShelfClassifier) async -> ShelfResult? {
        guard let cgImage = image.cgImage else { return nil }
        guard let vnModel = try? VNCoreMLModel(for: modelo.model) else { return nil }

        return await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)

            let request = VNCoreMLRequest(model: vnModel) { req, error in
                if let error = error {
                    self.log.warning("Vision error: \(error.localizedDescription)")
                    box.resume(nil)
                    return
                }
                guard let observations = req.results as? [VNClassificationObservation],
                      let top = observations.first else {
                    box.resume(nil)
                    return
                }
                self.log.debug("[Vision] Top: \(top.identifier) confidence=\(top.confidence)")
                box.resume(self.construirResultado(clase: top.identifier, confidence: Double(top.confidence)))
            }
            request.imageCropAndScaleOption = .centerCrop

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])
                } catch {
                    self.log.warning("handler.perform throw: \(error.localizedDescription)")
                    box.resume(nil)
                }
            }
        }
    }

    // MARK: - Estrategia 2: CoreML directo (bypassing Vision)

    private func clasificarConCoreML(image: UIImage, modelo: BimboShelfClassifier) -> ShelfResult? {
        // Create ML image classifier usa 299×299 por defecto (VisionFeaturePrint_Scene)
        guard let buffer = pixelBuffer(from: image, size: CGSize(width: 299, height: 299)) else {
            log.warning("No se pudo crear pixel buffer")
            return nil
        }

        do {
            let output = try modelo.prediction(image: buffer)
            let clase = output.target
            let confidence = output.targetProbability[clase] ?? 0
            log.debug("[CoreML directo] \(clase) confidence=\(confidence)")
            for (k, v) in output.targetProbability {
                log.debug("  \(k): \(v)")
            }
            return construirResultado(clase: clase, confidence: confidence)
        } catch {
            log.warning("CoreML prediction throw: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Construcción del resultado

    private func construirResultado(clase: String, confidence: Double) -> ShelfResult {
        let huecos = calcularHuecos(clase: clase, confidence: confidence)
        let mensaje = mensajeParaHuecos(clase: clase, huecos: huecos)
        let (estado, color) = mapearEstado(clase: clase)
        return ShelfResult(
            estado: estado,
            confidence: confidence,
            huecosEstimados: huecos,
            mensajeVoz: mensaje,
            colorSemaforo: color
        )
    }

    // MARK: - Caja para evitar doble-resume

    private final class ResumeBox: @unchecked Sendable {
        var resumed = false
        let continuation: CheckedContinuation<ShelfResult?, Never>
        init(_ c: CheckedContinuation<ShelfResult?, Never>) { continuation = c }
        func resume(_ result: ShelfResult?) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: result)
        }
    }

    // MARK: - Punto de entrada

    /// Estrategia: probar varios computeUnits con Vision y CoreML directo.
    /// Si todo falla, regresa diagnóstico claro al usuario.
    func classify(image: UIImage) async -> ShelfResult {
        log.debug("classify() inicio")

        let unitsAProbar: [MLComputeUnits] = [.all, .cpuAndGPU, .cpuOnly]

        for units in unitsAProbar {
            guard let modelo = cargarModelo(units: units) else { continue }
            log.debug("Modelo cargado con \(String(describing: units))")

            // Intento 1: Vision
            if let res = await clasificarConVision(image: image, modelo: modelo) {
                log.debug("✓ Clasificó con Vision (\(String(describing: units)))")
                return res
            }

            // Intento 2: CoreML directo
            if let res = clasificarConCoreML(image: image, modelo: modelo) {
                log.debug("✓ Clasificó con CoreML directo (\(String(describing: units)))")
                return res
            }

            log.warning("Ambos métodos fallaron con \(String(describing: units))")
        }

        return resultadoMock(razon: "El simulador iOS 26 no puede correr este modelo (espresso context falla). Pruébalo en un iPhone real.")
    }
}
