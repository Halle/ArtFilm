//
//  ExtensionProvider.swift
//  Extension
//
//  Created by Halle Winkler on 10.08.22.
//

import Accelerate
import AppKit
import AVFoundation
import CoreMediaIO
import Foundation
import IOKit.audio
import os.log

let outputWidth = 1280
let outputHeight = 720
let pixelBufferSize = vImage.Size(width: outputWidth, height: outputHeight)
let kFrameRate: Int = 24
let logger = Logger(subsystem: Identifiers.orgIDAndProduct.rawValue.lowercased(),
                    category: "Extension")

// MARK: - ExtensionDeviceSourceDelegate

protocol ExtensionDeviceSourceDelegate: NSObject {
    func bufferReceived(_ buffer: CMSampleBuffer)
}

// MARK: - ExtensionDeviceSource

class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    // MARK: Lifecycle

    init(localizedName: String) {
        super.init()

        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        if bundleID.contains("EndToEnd") {
            _isExtension = false
        }
        let deviceID = UUID()

        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: deviceID,
                                     legacyDeviceID: nil, source: self)

        let dims = CMVideoDimensions(width: Int32(outputWidth), height: Int32(outputHeight))
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: kCVPixelFormatType_32BGRA,
                                       width: dims.width, height: dims.height,
                                       extensions: nil,
                                       formatDescriptionOut: &_videoDescription)

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: dims.width,
            kCVPixelBufferHeightKey: dims.height,
            kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes,
                                &_bufferPool)

        let videoStreamFormat =
            CMIOExtensionStreamFormat(formatDescription: _videoDescription,
                                      maxFrameDuration: CMTime(value: 1,
                                                               timescale: Int32(kFrameRate)),
                                      minFrameDuration: CMTime(value: 1,
                                                               timescale: Int32(kFrameRate)),
                                      validFrameDurations: nil)
        _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        let videoID = UUID()
        _streamSource = ExtensionStreamSource(localizedName: "OffcutsCam.Video",
                                              streamID: videoID,
                                              streamFormat: videoStreamFormat,
                                              device: device)
        do {
            try device.addStream(_streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    // MARK: Public

    public weak var extensionDeviceSourceDelegate: ExtensionDeviceSourceDelegate?

    // MARK: Internal

    private(set) var device: CMIOExtensionDevice!

    var _isExtension: Bool = true
    var _streamSource: ExtensionStreamSource!
    var _videoDescription: CMFormatDescription!
    var mood = MoodName.bypass

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, customEffectExtensionProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties
    {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "OffcutsCam Model"
        }

        // If I get there and there is a key for my effect, that means that we've run before.
        // We are backing the custom property with the extension's UserDefaults.
        let userDefaultsPropertyKey = PropertyName.mood.rawValue
        if userDefaults?.object(forKey: userDefaultsPropertyKey) != nil, let propertyMood = userDefaults?.string(forKey: userDefaultsPropertyKey) { // Not first run
            deviceProperties.setPropertyState(CMIOExtensionPropertyState(value: propertyMood as NSString),
                                              forProperty: customEffectExtensionProperty)

            if let moodName = MoodName(rawValue: propertyMood) {
                mood = moodName
            }
        } else { // We have never run before, so set property and the backing UserDefaults to default setting
            deviceProperties.setPropertyState(CMIOExtensionPropertyState(value: MoodName.bypass.rawValue as NSString),
                                              forProperty: customEffectExtensionProperty)
            userDefaults?.set(MoodName.bypass.rawValue, forKey: userDefaultsPropertyKey)
            logger.debug("Did initial set of effects value to \(MoodName.bypass.rawValue)")
            mood = MoodName.bypass
        }

        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        let userDefaultsPropertyKey = PropertyName.mood.rawValue
        if let customEffectValueFromPropertiesDictionary = dictionaryValueForEffectProperty(in: deviceProperties) {
            logger.debug("New setting in device properties for custom effect property: \(customEffectValueFromPropertiesDictionary)")
            userDefaults?.set(customEffectValueFromPropertiesDictionary, forKey: userDefaultsPropertyKey)
            if let moodName = MoodName(rawValue: customEffectValueFromPropertiesDictionary) {
                mood = moodName
            }
        }
    }

    // MARK: Private

    private let customEffectExtensionProperty: CMIOExtensionProperty = .init(rawValue: "4cc_" + PropertyName.mood.rawValue + "_glob_0000") // Custom 'effect' property

    private let userDefaults = UserDefaults(suiteName: Identifiers.appGroup.rawValue)
    private var _bufferPool: CVPixelBufferPool!
    private var _bufferAuxAttributes: NSDictionary!

    private func dictionaryValueForEffectProperty(in deviceProperties: CMIOExtensionDeviceProperties) -> String? {
        guard let customEffectValueFromPropertiesDictionary = deviceProperties.propertiesDictionary[customEffectExtensionProperty]?.value as? String else {
            logger.debug("Was not able to get the value of the custom effect property from the properties dictionary of the device, returning.")
            return nil
        }
        return customEffectValueFromPropertiesDictionary
    }
}

// MARK: - ExtensionStreamSource

class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: Lifecycle

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        _streamFormat = streamFormat

        super.init()

        captureSessionManager = CaptureSessionManager(capturingOffcutsCam: false)
        guard let captureSessionManager = captureSessionManager else {
            logger.error("Not able to get capture session, returning.")
            return
        }

        guard captureSessionManager.configured == true, let captureSessionManagerOutput = captureSessionManager.videoOutput else {
            logger.error("Not able to configure session and change captureSessionManagerOutput delegate, returning")
            return
        }
        captureSessionManagerOutput.setSampleBufferDelegate(self, queue: captureSessionManager.dataOutputQueue)
        logger.debug("Sample buffer delegate is now \(captureSessionManagerOutput.sampleBufferDelegate.debugDescription)")
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
    }

    // MARK: Internal

    let effects = Effects()

    private(set) var stream: CMIOExtensionStream!

    var formats: [CMIOExtensionStreamFormat] {
        [_streamFormat]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func captureOutput(_: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from _: AVCaptureConnection)
    {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            logger.error("Couldn't obtain device source")
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        CVPixelBufferLockBaseAddress(
            pixelBuffer,
            CVPixelBufferLockFlags.readOnly)

        effects.populateDestinationBuffer(pixelBuffer: pixelBuffer)
        if deviceSource.mood != .bypass {
            effects.artFilm(forMood: deviceSource.mood)
        }

        CVPixelBufferUnlockBaseAddress(
            pixelBuffer,
            CVPixelBufferLockFlags.readOnly)

        var err: OSStatus = 0
        var sbuf: CMSampleBuffer!
        var timingInfo = CMSampleTimingInfo()
        timingInfo.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())

        let width = outputWidth
        let height = outputHeight

        let pixelBufferAttributes: NSDictionary = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: deviceSource._videoDescription.mediaSubType,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]

        var destinationCVPixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_422YpCbCr8,
                                         pixelBufferAttributes as CFDictionary,
                                         &destinationCVPixelBuffer)
        if result == 0, let destinationCVPixelBuffer = destinationCVPixelBuffer {
            CVPixelBufferLockBaseAddress(destinationCVPixelBuffer,
                                         CVPixelBufferLockFlags(rawValue: 0))

            do {
                try effects.destinationBuffer.copy(to: destinationCVPixelBuffer, cvImageFormat: effects.cvImageFormat, cgImageFormat: effects.cgImageFormat)
            } catch {
                logger.debug("Copy failed.")
            }

            CVPixelBufferUnlockBaseAddress(destinationCVPixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

            var formatDescription: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: destinationCVPixelBuffer, formatDescriptionOut: &formatDescription)
            err = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: destinationCVPixelBuffer, formatDescription: formatDescription!, sampleTiming: &timingInfo, sampleBufferOut: &sbuf)

            if err == 0 {
                if deviceSource._isExtension { // If I'm the extension, send to output stream
                    stream.send(sbuf, discontinuity: [], hostTimeInNanoseconds: UInt64(timingInfo.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
                } else {
                    deviceSource.extensionDeviceSourceDelegate?.bufferReceived(sbuf) // If I'm the end to end testing app, send to delegate method.
                }
            } else {
                logger.error("Error in stream: \(err)")
            }
        }
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
            streamProperties.frameDuration = frameDuration
        }

        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for _: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        guard let captureSessionManager = captureSessionManager, captureSessionManager.captureSession.isRunning == false else {
            logger.error("Can't start capture session running, returning")
            return
        }
        captureSessionManager.captureSession.startRunning()
    }

    func stopStream() throws {
        guard let captureSessionManager = captureSessionManager, captureSessionManager.configured, captureSessionManager.captureSession.isRunning else {
            logger.error("Can't stop AVCaptureSession where it is expected, returning")
            return
        }
        if captureSessionManager.captureSession.isRunning {
            captureSessionManager.captureSession.stopRunning()
        }
    }

    // MARK: Private

    private let device: CMIOExtensionDevice
    private var captureSessionManager: CaptureSessionManager?
    private let _streamFormat: CMIOExtensionStreamFormat
    private let sessionPreset = AVCaptureSession.Preset.hd1280x720

    private var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                os_log(.error, "Invalid index")
            }
        }
    }
}

// MARK: - ExtensionProviderSource

class ExtensionProviderSource: NSObject, CMIOExtensionProviderSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: Lifecycle

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = ExtensionDeviceSource(localizedName: "OffcutsCam")

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
        startNotificationListeners()
    }

    deinit {
        stopNotificationListeners()
    }

    // MARK: Internal

    private(set) var provider: CMIOExtensionProvider!

    var deviceSource: ExtensionDeviceSource!

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func connect(to _: CMIOExtensionClient) throws {}

    func disconnect(from _: CMIOExtensionClient) {}

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties
    {
        let providerProperties =
            CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "OffcutsCam Manufacturer"
        }
        return providerProperties
    }

    func setProviderProperties(_: CMIOExtensionProviderProperties) throws {}

    // MARK: Private

    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()
    private var notificationListenerStarted = false
}

// For various reasons, including that it is arguably extension provision for the end-to-end test app,
// it is preferable to keep notification listening in ExtensionProviderSource, but we can at least separate
// it into an extension.

extension ExtensionProviderSource {
    private func notificationReceived(notificationName: String) {
        if let name = NotificationName(rawValue: notificationName) {
            switch name {
            case .startStream:
                do {
                    try deviceSource._streamSource.startStream()
                } catch {
                    logger.debug("Couldn't start the stream")
                }
            case .stopStream:
                do {
                    try deviceSource._streamSource.stopStream()
                } catch {
                    logger.debug("Couldn't stop the stream")
                }
            }
        } else {
            if let mood = MoodName(rawValue: notificationName.replacingOccurrences(of: Identifiers.appGroup.rawValue + ".", with: "")) {
                deviceSource.mood = mood
            }
        }
    }

    private func startNotificationListeners() {
        var allNotifications = [String]()
        for notificationName in NotificationName.allCases {
            allNotifications.append(notificationName.rawValue)
        }

        for notificationName in MoodName.allCases {
            allNotifications.append(Identifiers.appGroup.rawValue + "." + notificationName.rawValue)
        }

        for notificationName in allNotifications {
            let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())

            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, name, _, _ in
                if let observer = observer, let name = name {
                    let extensionProviderSourceSelf = Unmanaged<ExtensionProviderSource>.fromOpaque(observer).takeUnretainedValue()
                    extensionProviderSourceSelf.notificationReceived(notificationName: name.rawValue as String)
                }
            },
            notificationName as CFString, nil, .deliverImmediately)
        }
    }

    private func stopNotificationListeners() {
        if notificationListenerStarted {
            CFNotificationCenterRemoveEveryObserver(notificationCenter,
                                                    Unmanaged.passRetained(self)
                                                        .toOpaque())
            notificationListenerStarted = false
        }
    }
}

// MARK: - Effects

class Effects: NSObject {
    // MARK: Lifecycle

    override init() {
        super.init()
        if let image = NSImage(named: "1.jpg") {
            sourceImageHistogramNewWave = getHistogram(for: image)
        }
        if let image = NSImage(named: "2.jpg") {
            sourceImageHistogramBerlin = getHistogram(for: image)
        }
        if let image = NSImage(named: "3.jpg") {
            sourceImageHistogramOldFilm = getHistogram(for: image)
        }
        if let image = NSImage(named: "4.jpg") {
            sourceImageHistogramSunset = getHistogram(for: image)
        }
        if let image = NSImage(named: "5.jpg") {
            sourceImageHistogramBadEnergy = getHistogram(for: image)
        }
        if let image = NSImage(named: "6.jpg") {
            sourceImageHistogramBeyondTheBeyond = getHistogram(for: image)
        }
        if let image = NSImage(named: "7.jpg") {
            sourceImageHistogramDrama = getHistogram(for: image)
        }

        let randomNumberGenerator = BNNSCreateRandomGenerator(
            BNNSRandomGeneratorMethodAES_CTR,
            nil)!

        for _ in 0 ..< maximumNoiseArrays {
            let noiseBuffer = vImage.PixelBuffer(
                size: pixelBufferSize,
                pixelFormat: vImage.InterleavedFx3.self)

            let shape = BNNS.Shape.tensor3DFirstMajor(
                noiseBuffer.width,
                noiseBuffer.height,
                noiseBuffer.channelCount)

            noiseBuffer.withUnsafeMutableBufferPointer { noisePtr in

                if var descriptor = BNNSNDArrayDescriptor(
                    data: noisePtr,
                    shape: shape)
                {
                    let mean: Float = 0.0125
                    let stdDev: Float = 0.025

                    BNNSRandomFillNormalFloat(randomNumberGenerator, &descriptor, mean, stdDev)
                }
            }
            noiseBufferArray.append(noiseBuffer)
        }
    }

    // MARK: Internal

    let cvImageFormat = vImageCVImageFormat.make(
        format: .format422YpCbCr8,
        matrix: kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4.pointee,
        chromaSiting: .center,
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        alphaIsOpaqueHint: true)!

    var cgImageFormat = vImage_CGImageFormat(
        bitsPerComponent: 32,
        bitsPerPixel: 32 * 3,
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Little.rawValue |
                CGBitmapInfo.floatComponents.rawValue |
                CGImageAlphaInfo.none.rawValue),
        renderingIntent: .defaultIntent)!

    let destinationBuffer = vImage.PixelBuffer(
        size: pixelBufferSize,
        pixelFormat: vImage.InterleavedFx3.self)

    func populateDestinationBuffer(pixelBuffer: CVPixelBuffer) {
        let sourceBuffer = vImage.PixelBuffer(
            referencing: pixelBuffer,
            converter: converter,
            destinationPixelFormat: vImage.DynamicPixelFormat.self)

        do {
            try converter.convert(
                from: sourceBuffer,
                to: destinationBuffer)
        } catch {
            fatalError("Any-to-any conversion failure.")
        }
    }

    func artFilm(forMood mood: MoodName) {
        tastefulNoise(destinationBuffer: destinationBuffer)
        specifySavedHistogram(forMood: mood)
        mildTemporalBlur()
    }

    // MARK: Private

    private lazy var converter: vImageConverter = {
        guard let converter = try? vImageConverter.make(
            sourceFormat: cvImageFormat,
            destinationFormat: cgImageFormat)
        else {
            fatalError("Unable to create converter")
        }

        return converter
    }()

    private lazy var temporalBuffer = vImage.PixelBuffer(
        size: pixelBufferSize,
        pixelFormat: vImage.InterleavedFx3.self)

    private lazy var histogramBuffer = vImage.PixelBuffer(
        size: pixelBufferSize,
        pixelFormat: vImage.PlanarFx3.self)

    private var noiseBufferArray: [vImage.PixelBuffer<vImage.InterleavedFx3>] = .init()

    private var sourceImageHistogramNewWave: vImage.PixelBuffer.HistogramFFF?
    private var sourceImageHistogramBerlin: vImage.PixelBuffer.HistogramFFF?
    private var sourceImageHistogramOldFilm: vImage.PixelBuffer.HistogramFFF?
    private var sourceImageHistogramSunset: vImage.PixelBuffer.HistogramFFF?
    private var sourceImageHistogramBadEnergy: vImage.PixelBuffer.HistogramFFF?
    private var sourceImageHistogramBeyondTheBeyond: vImage.PixelBuffer.HistogramFFF?
    private var sourceImageHistogramDrama: vImage.PixelBuffer.HistogramFFF?

    private let maximumNoiseArrays = kFrameRate / 2 // We can fake it for a second
    private var noiseArrayCount = 0
    private var noiseArrayCountAscending = true
    private let histogramBinCount = 32

    private func mildTemporalBlur() {
        let interpolationConstant: Float = 0.4

        destinationBuffer.linearInterpolate(
            bufferB: temporalBuffer,
            interpolationConstant: interpolationConstant,
            destination: temporalBuffer)

        temporalBuffer.copy(to: destinationBuffer)
    }

    private func tastefulNoise(destinationBuffer: vImage.PixelBuffer<vImage.InterleavedFx3>) {
        guard noiseBufferArray.count == maximumNoiseArrays else {
            return
        }

        destinationBuffer.withUnsafeMutableBufferPointer { mutableDestintationPtr in
            vDSP.add(destinationBuffer, noiseBufferArray[noiseArrayCount],
                     result: &mutableDestintationPtr)
        }

        if noiseArrayCount == maximumNoiseArrays - 1 {
            noiseArrayCountAscending = false
        } else if noiseArrayCount == 0 {
            if noiseArrayCountAscending == false {
                // the maximumNoiseArrays * 2 pass, we shuffle so the eyes don't start to notice patterns in the "noise dance"
                noiseBufferArray = noiseBufferArray.shuffled()
            }
            noiseArrayCountAscending = true
        }

        if noiseArrayCountAscending {
            noiseArrayCount += 1
        } else {
            noiseArrayCount -= 1
        }
    }

    private func specifySavedHistogram(forMood mood: MoodName) {
        var sourceHistogramToSpecify = sourceImageHistogramNewWave

        switch mood {
        case .newWave:
            sourceHistogramToSpecify = sourceImageHistogramNewWave
        case .berlin:
            sourceHistogramToSpecify = sourceImageHistogramBerlin
        case .oldFilm:
            sourceHistogramToSpecify = sourceImageHistogramOldFilm
        case .sunset:
            sourceHistogramToSpecify = sourceImageHistogramSunset
        case .badEnergy:
            sourceHistogramToSpecify = sourceImageHistogramBadEnergy
        case .beyondTheBeyond:
            sourceHistogramToSpecify = sourceImageHistogramBeyondTheBeyond
        case .drama:
            sourceHistogramToSpecify = sourceImageHistogramDrama
        case .bypass:
            return
        }

        if let sourceImageHistogram = sourceHistogramToSpecify {
            destinationBuffer.deinterleave(
                destination: histogramBuffer)

            histogramBuffer.specifyHistogram(
                sourceImageHistogram,
                destination: histogramBuffer)

            histogramBuffer.interleave(
                destination: destinationBuffer)
        }
    }

    private func getHistogram(for image: NSImage) -> vImage.PixelBuffer.HistogramFFF? {
        let sourceImageHistogramBuffer = vImage.PixelBuffer(
            size: pixelBufferSize,
            pixelFormat: vImage.PlanarFx3.self)

        var proposedRect = NSRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: image.size.width, height: image.size.height))

        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            logger.error("Couldn't get cgImage from \(image), returning.")
            return nil
        }

        let bytesPerPixel = cgImage.bitsPerPixel / cgImage.bitsPerComponent
        let destBytesPerRow = outputWidth * bytesPerPixel

        guard let colorSpace = cgImage.colorSpace, let context = CGContext(data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: destBytesPerRow, space: colorSpace, bitmapInfo: cgImage.alphaInfo.rawValue) else {
            logger.error("Problem setting up cgImage resize, returning.")
            return nil
        }

        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        guard let resizedCGImage = context.makeImage() else {
            logger.error("Couldn't resize cgImage for histogram, returning.")
            return nil
        }

        let pixelFormat = vImage.InterleavedFx3.self

        let sourceImageBuffer: vImage.PixelBuffer<vImage.InterleavedFx3>?

        do {
            sourceImageBuffer = try vImage.PixelBuffer(
                cgImage: resizedCGImage,
                cgImageFormat: &cgImageFormat,
                pixelFormat: pixelFormat)

            if let sourceImageBuffer = sourceImageBuffer {
                sourceImageBuffer.deinterleave(destination: sourceImageHistogramBuffer)
                return sourceImageHistogramBuffer.histogram(binCount: histogramBinCount)
            } else {
                logger.error("Source image buffer was nil, returning.")
                return nil
            }
        } catch {
            logger.error("Error creating source image buffer: \(error)")
            return nil
        }
    }
}
