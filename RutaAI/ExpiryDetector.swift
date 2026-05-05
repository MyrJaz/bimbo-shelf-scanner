import UIKit
import CoreImage
import os.log

// MARK: - Tipos de resultado

struct ExpiryResult {
    let etiquetasVerdes: Int
    let etiquetasAzules: Int
    let etiquetasRojas: Int
    let estadoCaducidad: EstadoCaducidad
    let mensajeVoz: String
    let requiereAtencionUrgente: Bool
}

enum EstadoCaducidad {
    case todo_fresco        // solo verdes o ninguna etiqueta
    case revisar_pronto     // hay azules pero no rojas
    case retirar_urgente    // hay rojas
}

// MARK: - Detector

/// Detecta etiquetas de colores en fotos de anaquel para identificar
/// productos próximos a caducar.
/// Verde → fresco · Azul → revisar pronto · Rojo → retirar urgente
class ExpiryDetector {

    private let log = Logger(subsystem: "com.rutaai.shelf", category: "ExpiryDetector")

    // Tamaño al que se reduce la imagen para análisis (300×300)
    // Más resolución → puntos pequeños tienen más píxeles y se detectan mejor
    private let tamano = 300

    // Mínimo de píxeles contiguos para considerar un cluster válido.
    // A 300×300, un punto de ~12 px de diámetro ≈ 113 px.
    // Threshold 100 filtra ruido de empaque pero acepta puntos reales.
    private let minPixelesCluster = 100

    // Etiquetas internas para clasificar cada píxel
    private enum ColorEtiqueta: UInt8 {
        case ninguno = 0
        case verde   = 1
        case azul    = 2
        case rojo    = 3
    }

    // MARK: - Punto de entrada

    func detect(image: UIImage) -> ExpiryResult {
        log.debug("detect() inicio — tamaño imagen: \(image.size.width)×\(image.size.height)")

        // Reducir + clasificar cada píxel por color HSV
        guard let mapa = construirMapaColores(de: image) else {
            log.warning("construirMapaColores falló, regresando vacío")
            return resultadoVacio()
        }

        // Contar clusters contiguos (flood-fill)
        let (verdes, azules, rojos) = contarClusters(mapa: mapa)
        log.debug("Clusters → verdes:\(verdes) azules:\(azules) rojos:\(rojos)")

        // Determinar estado global de caducidad
        let estado: EstadoCaducidad
        if rojos > 0 {
            estado = .retirar_urgente
        } else if azules > 0 {
            estado = .revisar_pronto
        } else {
            estado = .todo_fresco
        }

        return ExpiryResult(
            etiquetasVerdes: verdes,
            etiquetasAzules: azules,
            etiquetasRojas: rojos,
            estadoCaducidad: estado,
            mensajeVoz: mensajeVoz(estado: estado, azules: azules, rojos: rojos),
            requiereAtencionUrgente: rojos > 0
        )
    }

    // MARK: - Reducción de la imagen + clasificación pixel a pixel

    /// Redibuja la imagen a 200×200 RGBA y clasifica cada píxel por color HSV.
    /// Regresa un arreglo de 40,000 ColorEtiqueta (row-major).
    private func construirMapaColores(de image: UIImage) -> [ColorEtiqueta]? {
        guard let cgImage = image.cgImage else { return nil }

        let width = tamano
        let height = tamano
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        var pixels = [UInt8](repeating: 0, count: totalBytes)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Reescala la imagen original al tamaño de análisis
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Clasifica cada píxel
        var mapa = [ColorEtiqueta](repeating: .ninguno, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = CGFloat(pixels[idx])     / 255
                let g = CGFloat(pixels[idx + 1]) / 255
                let b = CGFloat(pixels[idx + 2]) / 255
                mapa[y * width + x] = clasificarPorHSV(r: r, g: g, b: b)
            }
        }
        return mapa
    }

    // MARK: - RGB → HSV → etiqueta

    /// Convierte RGB (0–1) a HSV y aplica los rangos de color de las etiquetas.
    private func clasificarPorHSV(r: CGFloat, g: CGFloat, b: CGFloat) -> ColorEtiqueta {
        let cMax = max(r, g, b)
        let cMin = min(r, g, b)
        let delta = cMax - cMin

        let v = cMax
        let s = cMax == 0 ? 0 : delta / cMax

        var h: CGFloat = 0
        if delta > 0 {
            if cMax == r {
                h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if cMax == g {
                h = 60 * (((b - r) / delta) + 2)
            } else {
                h = 60 * (((r - g) / delta) + 4)
            }
        }
        if h < 0 { h += 360 }

        // Verde:  H 75–165,  S > 0.30, V > 0.25
        // Rango un poco más amplio para capturar distintos tonos de verde lima
        if h >= 75 && h <= 165 && s > 0.30 && v > 0.25 {
            return .verde
        }
        // Azul:   H 185–265, S > 0.35, V > 0.25
        if h >= 185 && h <= 265 && s > 0.35 && v > 0.25 {
            return .azul
        }
        // Rosa/Magenta: H 295–345, S > 0.50, V > 0.30
        // Cubre hot-pink y magenta; excluye rojo-anaranjado de empaques (H 0–20)
        if h >= 295 && h <= 345 && s > 0.50 && v > 0.30 {
            return .rojo
        }
        return .ninguno
    }

    // MARK: - Conteo de clusters por flood-fill (BFS iterativo)

    /// Recorre el mapa contando regiones conectadas por color.
    /// Solo cuenta regiones de al menos `minPixelesCluster` píxeles.
    private func contarClusters(mapa: [ColorEtiqueta]) -> (verdes: Int, azules: Int, rojos: Int) {
        let width = tamano
        let height = tamano
        var visitado = [Bool](repeating: false, count: width * height)

        var verdes = 0
        var azules = 0
        var rojos = 0

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if visitado[idx] { continue }

                let color = mapa[idx]
                if color == .ninguno {
                    visitado[idx] = true
                    continue
                }

                // Flood-fill iterativo desde (x, y)
                var pila: [(Int, Int)] = [(x, y)]
                visitado[idx] = true
                var tamanoCluster = 0

                while let (cx, cy) = pila.popLast() {
                    tamanoCluster += 1

                    // 4-conectividad (arriba, abajo, izquierda, derecha)
                    let vecinos = [(cx, cy + 1), (cx, cy - 1), (cx + 1, cy), (cx - 1, cy)]
                    for (nx, ny) in vecinos {
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let nidx = ny * width + nx
                        if visitado[nidx] { continue }
                        if mapa[nidx] != color { continue }
                        visitado[nidx] = true
                        pila.append((nx, ny))
                    }
                }

                // Solo contamos clusters lo suficientemente grandes
                if tamanoCluster >= minPixelesCluster {
                    switch color {
                    case .verde:   verdes += 1
                    case .azul:    azules += 1
                    case .rojo:    rojos += 1
                    case .ninguno: break
                    }
                }
            }
        }
        return (verdes, azules, rojos)
    }

    // MARK: - Mensajes de voz en español mexicano

    private func mensajeVoz(estado: EstadoCaducidad, azules: Int, rojos: Int) -> String {
        switch estado {
        case .todo_fresco:
            return "Productos frescos, sin problema de caducidad"
        case .revisar_pronto:
            return azules == 1
                ? "Hay un producto de hace seis semanas, revísalo pronto"
                : "Hay \(azules) productos de hace seis semanas, revísalos pronto"
        case .retirar_urgente:
            return rojos == 1
                ? "Atención, hay un producto próximo a caducar, retíralo hoy"
                : "Atención, hay \(rojos) productos próximos a caducar, retíralos hoy"
        }
    }

    /// Fallback cuando no se pudo procesar la imagen.
    private func resultadoVacio() -> ExpiryResult {
        ExpiryResult(
            etiquetasVerdes: 0,
            etiquetasAzules: 0,
            etiquetasRojas: 0,
            estadoCaducidad: .todo_fresco,
            mensajeVoz: "Productos frescos, sin problema de caducidad",
            requiereAtencionUrgente: false
        )
    }
}
