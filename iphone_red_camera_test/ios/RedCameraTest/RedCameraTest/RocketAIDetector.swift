import CoreML
import CoreVideo
import Foundation
import ImageIO
import Vision

struct WaterRocketDetection {
    /// Tọa độ chuẩn hóa, gốc ở góc trên-trái để dùng trực tiếp với giao diện app.
    let rect: CGRect
    let confidence: Double
    let label: String
}

/// Lớp nối model YOLO/Core ML với Vision.
///
/// Chỉ cần thêm `WaterRocketDetector.mlpackage` vào thư mục source. Xcode sẽ
/// biên dịch thành `WaterRocketDetector.mlmodelc` và lớp này tự nạp model.
final class RocketAIDetector {
    private let visionModel: VNCoreMLModel?
    private let modelInputSize: CGSize
    private let acceptedLabels: Set<String>
    private let acceptedClassIndices: Set<Int>
    private let resultLabel: String
    private(set) var loadMessage = "Chưa có WaterRocketDetector.mlpackage"

    var isAvailable: Bool { visionModel != nil }

    init(
        bundle: Bundle = .main,
        modelNames: [String] = ["WaterRocketDetector", "water_rocket", "best"],
        acceptedLabels: Set<String> = [
            "water_rocket", "waterrocket", "rocket", "ten_lua_nuoc"
        ],
        acceptedClassIndices: Set<Int> = [0],
        resultLabel: String = "water_rocket"
    ) {
        self.acceptedLabels = acceptedLabels
        self.acceptedClassIndices = acceptedClassIndices
        self.resultLabel = resultLabel
        var loadedModel: VNCoreMLModel?
        var loadedInputSize = CGSize(width: 640, height: 640)

        for name in modelNames {
            guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
                continue
            }
            do {
                let configuration = MLModelConfiguration()
                if #available(iOS 16.0, *) {
                    configuration.computeUnits = .cpuAndNeuralEngine
                } else {
                    configuration.computeUnits = .all
                }
                let model = try MLModel(contentsOf: url, configuration: configuration)
                if let imageInput = model.modelDescription.inputDescriptionsByName.values
                    .compactMap({ $0.imageConstraint })
                    .first {
                    loadedInputSize = CGSize(
                        width: CGFloat(imageInput.pixelsWide),
                        height: CGFloat(imageInput.pixelsHigh)
                    )
                }
                loadedModel = try VNCoreMLModel(for: model)
                loadMessage = "AI Core ML: \(name)"
                break
            } catch {
                loadMessage = "Không nạp được \(name): \(error.localizedDescription)"
            }
        }
        visionModel = loadedModel
        modelInputSize = loadedInputSize
    }

    func detect(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        minimumConfidence: Double = 0.24,
        regionOfInterest: CGRect? = nil
    ) -> [WaterRocketDetection] {
        guard let visionModel else { return [] }

        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
        let normalizedROI = regionOfInterest?
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if let roi = normalizedROI,
           !roi.isNull,
           roi.width >= 0.08,
           roi.height >= 0.08 {
            // App dùng gốc trên-trái, còn Vision nhận ROI với gốc dưới-trái.
            // Bounding box Vision trả về tương đối với chính ROI; remapToFullFrame
            // sẽ đưa kết quả về lại hệ tọa độ toàn khung.
            request.regionOfInterest = CGRect(
                x: roi.minX,
                y: 1.0 - roi.maxY,
                width: roi.width,
                height: roi.height
            )
        }
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = request.results as? [VNRecognizedObjectObservation] ?? []
        let recognized: [WaterRocketDetection] = observations.compactMap {
            (observation: VNRecognizedObjectObservation) -> WaterRocketDetection? in
            guard let label = observation.labels.first else { return nil }
            let confidence = Double(min(observation.confidence, label.confidence))
            guard confidence >= minimumConfidence else { return nil }

            let normalizedLabel = label.identifier
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            // Model một lớp đôi lúc xuất nhãn "0". Chấp nhận nhãn này nhưng
            // không nhận các lớp COCO ngẫu nhiên từ model chưa huấn luyện.
            guard acceptedLabels.contains(normalizedLabel)
                    || (acceptedClassIndices.count == 1
                        && acceptedClassIndices.contains(0)
                        && normalizedLabel == "0") else {
                return nil
            }

            let box = observation.boundingBox
            let topLeftRect = CGRect(
                x: box.minX,
                y: 1.0 - box.maxY,
                width: box.width,
                height: box.height
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard topLeftRect.width > 0.004, topLeftRect.height > 0.004 else {
                return nil
            }
            return WaterRocketDetection(
                rect: topLeftRect,
                confidence: confidence,
                label: label.identifier
            )
        }
        .sorted {
            (lhs: WaterRocketDetection, rhs: WaterRocketDetection) -> Bool in
            lhs.confidence > rhs.confidence
        }
        if !recognized.isEmpty {
            return remapToFullFrame(recognized, regionOfInterest: normalizedROI)
        }

        // YOLO26 end-to-end mặc định xuất MultiArray [1, 300, 6] thay vì
        // VNRecognizedObjectObservation. Parser này giữ app tương thích cả hai
        // kiểu export: NMS pipeline và NMS-free.
        let featureResults = (request.results ?? []).compactMap {
            $0 as? VNCoreMLFeatureValueObservation
        }
        let decoded = parseFeatureArrays(
            featureResults,
            minimumConfidence: minimumConfidence
        )
        return remapToFullFrame(decoded, regionOfInterest: normalizedROI)
    }

    private func remapToFullFrame(
        _ detections: [WaterRocketDetection],
        regionOfInterest: CGRect?
    ) -> [WaterRocketDetection] {
        guard let roi = regionOfInterest,
              !roi.isNull,
              roi.width >= 0.08,
              roi.height >= 0.08 else { return detections }

        return detections.compactMap { detection in
            let rect = CGRect(
                x: roi.minX + detection.rect.minX * roi.width,
                y: roi.minY + detection.rect.minY * roi.height,
                width: detection.rect.width * roi.width,
                height: detection.rect.height * roi.height
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard rect.width > 0.002, rect.height > 0.002 else { return nil }
            return WaterRocketDetection(
                rect: rect,
                confidence: detection.confidence,
                label: detection.label
            )
        }
        .sorted { $0.confidence > $1.confidence }
    }

    private func parseFeatureArrays(
        _ results: [VNCoreMLFeatureValueObservation],
        minimumConfidence: Double
    ) -> [WaterRocketDetection] {
        let arrays = results.compactMap { result -> (String, MLMultiArray)? in
            guard let value = result.featureValue.multiArrayValue else { return nil }
            return (result.featureName.lowercased(), value)
        }

        if let endToEnd = arrays.first(where: { item in
            let shape = item.1.shape.map(\.intValue)
            return shape.last == 6 || (shape.count >= 2 && shape[shape.count - 2] == 6)
        }) {
            return parseEndToEnd(endToEnd.1, minimumConfidence: minimumConfidence)
        }

        guard let coordinates = arrays.first(where: { $0.0.contains("coordinate") })?.1,
              let confidence = arrays.first(where: { $0.0.contains("confidence") })?.1 else {
            return []
        }
        return parseNMSArrays(
            coordinates: coordinates,
            confidence: confidence,
            minimumConfidence: minimumConfidence
        )
    }

    private func parseEndToEnd(
        _ array: MLMultiArray,
        minimumConfidence: Double
    ) -> [WaterRocketDetection] {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 2 else { return [] }
        let fieldsLast = shape.last == 6
        let rowCount = fieldsLast ? shape[shape.count - 2] : shape.last!
        guard fieldsLast || shape[shape.count - 2] == 6 else { return [] }

        func value(row: Int, field: Int) -> Double {
            var indices = Array(repeating: 0, count: shape.count)
            if fieldsLast {
                indices[shape.count - 2] = row
                indices[shape.count - 1] = field
            } else {
                indices[shape.count - 2] = field
                indices[shape.count - 1] = row
            }
            let linear = zip(indices, strides).reduce(0) { $0 + $1.0 * $1.1 }
            return array[linear].doubleValue
        }

        var detections: [WaterRocketDetection] = []
        for row in 0..<rowCount {
            let confidence = value(row: row, field: 4)
            guard confidence >= minimumConfidence else { continue }
            let classIndex = Int(value(row: row, field: 5).rounded())
            guard acceptedClassIndices.isEmpty
                    || acceptedClassIndices.contains(classIndex) else { continue }
            var x1 = value(row: row, field: 0)
            var y1 = value(row: row, field: 1)
            var x2 = value(row: row, field: 2)
            var y2 = value(row: row, field: 3)
            if max(x1, y1, x2, y2) > 1.5 {
                x1 /= Double(max(1, modelInputSize.width))
                x2 /= Double(max(1, modelInputSize.width))
                y1 /= Double(max(1, modelInputSize.height))
                y2 /= Double(max(1, modelInputSize.height))
            }
            let rect = CGRect(
                x: CGFloat(min(x1, x2)),
                y: CGFloat(min(y1, y2)),
                width: CGFloat(abs(x2 - x1)),
                height: CGFloat(abs(y2 - y1))
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard rect.width > 0.004, rect.height > 0.004 else { continue }
            detections.append(WaterRocketDetection(
                rect: rect,
                confidence: confidence,
                label: resultLabel
            ))
        }
        return detections.sorted { $0.confidence > $1.confidence }
    }

    private func parseNMSArrays(
        coordinates: MLMultiArray,
        confidence: MLMultiArray,
        minimumConfidence: Double
    ) -> [WaterRocketDetection] {
        let coordinateShape = coordinates.shape.map(\.intValue)
        let coordinateStrides = coordinates.strides.map(\.intValue)
        let confidenceShape = confidence.shape.map(\.intValue)
        let confidenceStrides = confidence.strides.map(\.intValue)
        guard coordinateShape.count >= 2,
              confidenceShape.count >= 2,
              coordinateShape.last == 4 else { return [] }
        let boxCount = coordinateShape[coordinateShape.count - 2]
        let classCount = confidenceShape.last ?? 1

        func coordinate(_ box: Int, _ field: Int) -> Double {
            var indices = Array(repeating: 0, count: coordinateShape.count)
            indices[coordinateShape.count - 2] = box
            indices[coordinateShape.count - 1] = field
            let linear = zip(indices, coordinateStrides).reduce(0) { $0 + $1.0 * $1.1 }
            return coordinates[linear].doubleValue
        }
        func classConfidence(_ box: Int, _ classIndex: Int) -> Double {
            var indices = Array(repeating: 0, count: confidenceShape.count)
            indices[confidenceShape.count - 2] = box
            indices[confidenceShape.count - 1] = classIndex
            let linear = zip(indices, confidenceStrides).reduce(0) { $0 + $1.0 * $1.1 }
            return confidence[linear].doubleValue
        }

        var detections: [WaterRocketDetection] = []
        for box in 0..<boxCount {
            var bestConfidence = 0.0
            let classIndices: [Int] = acceptedClassIndices.isEmpty
                ? Array(0..<classCount)
                : Array(acceptedClassIndices.filter { $0 >= 0 && $0 < classCount })
            for classIndex in classIndices {
                bestConfidence = max(bestConfidence, classConfidence(box, classIndex))
            }
            guard bestConfidence >= minimumConfidence else { continue }
            let centerX = coordinate(box, 0)
            let centerY = coordinate(box, 1)
            let width = coordinate(box, 2)
            let height = coordinate(box, 3)
            let rect = CGRect(
                x: CGFloat(centerX - width / 2),
                y: CGFloat(centerY - height / 2),
                width: CGFloat(width),
                height: CGFloat(height)
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard rect.width > 0.004, rect.height > 0.004 else { continue }
            detections.append(WaterRocketDetection(
                rect: rect,
                confidence: bestConfidence,
                label: resultLabel
            ))
        }
        return detections.sorted { $0.confidence > $1.confidence }
    }
}
