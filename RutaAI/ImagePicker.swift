import SwiftUI
import UIKit

// MARK: - Selector de imagen (cámara o galería)

/// Envuelve UIImagePickerController para usarlo desde SwiftUI.
/// Recibe la fuente explícitamente (cámara o galería).
struct ImagePicker: UIViewControllerRepresentable {

    @ObservedObject var viewModel: ScanViewModel
    var sourceType: UIImagePickerController.SourceType = .photoLibrary

    // MARK: Coordinator

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {

        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let imagen = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage

            picker.dismiss(animated: true) {
                if let img = imagen {
                    // Asignamos y disparamos el análisis automáticamente
                    self.parent.viewModel.imagenSeleccionada = img
                    self.parent.viewModel.analizar()
                }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = false

        picker.sourceType = sourceType

        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}
