//
// Created by Halle Winkler on Aug/17/22. Copyright © 2022. All rights reserved.
//

import AppKit
import AVFoundation
import CoreMediaIO
import Foundation

// MARK: - CaptureSessionManager

class CaptureSessionManager: NSObject {
    // MARK: Lifecycle

    // Flexible standard capture setup for Continuity and for extension

    init(capturingOffcutsCam: Bool) {
        super.init()
        captureOffcutsCam = capturingOffcutsCam
        configured = configureCaptureSession()
    }

    // MARK: Internal

    enum Camera: String {
        case continuityCamera
        case offcutsCam = "OffcutsCam"
    }

    var configured: Bool = false
    var captureOffcutsCam = false
    var captureSession: AVCaptureSession = .init()

    var videoOutput: AVCaptureVideoDataOutput?

    let dataOutputQueue = DispatchQueue(label: "video_queue",
                                        qos: .userInteractive,
                                        attributes: [],
                                        autoreleaseFrequency: .workItem)

    func configureCaptureSession() -> Bool {
        var result = false
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(
                for: .video,
                completionHandler: { granted in
                    if !granted {
                        logger.error("1. App requires camera access, returning")
                        return
                    } else {
                        result = self.configureCaptureSession()
                    }
                }
            )
            return result
        default:

            logger.error("2. App requires camera access, returning")
            return false
        }

        captureSession.beginConfiguration()

        captureSession.sessionPreset = sessionPreset

        guard let camera = getCameraIfAvailable(camera: captureOffcutsCam ? .offcutsCam : .continuityCamera) else {
            logger.error("Can't create default camera, this could be because the extension isn't installed, returning")
            return false
        }

        do {
            let fallbackPreset = AVCaptureSession.Preset.high
            let input = try AVCaptureDeviceInput(device: camera)

            let supportStandardPreset = input.device.supportsSessionPreset(sessionPreset)
            if !supportStandardPreset {
                let supportFallbackPreset = input.device.supportsSessionPreset(fallbackPreset)
                if supportFallbackPreset {
                    captureSession.sessionPreset = fallbackPreset
                } else {
                    logger.error("No HD formats used by this code supported, returning.")
                    return false
                }
            }
            captureSession.addInput(input)
        } catch {
            logger.error("Can't create AVCaptureDeviceInput, returning")
            return false
        }

        videoOutput = AVCaptureVideoDataOutput()
        if let videoOutput = videoOutput {
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
                captureSession.commitConfiguration()
                return true
            } else {
                logger.error("Can't add video output, returning")
                return false
            }
        }
        return false
    }

    // MARK: Private

    private let sessionPreset = AVCaptureSession.Preset.hd1280x720

    private func getCameraIfAvailable(camera: Camera) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes:
            [.externalUnknown, .builtInMicrophone, .builtInMicrophone, .builtInWideAngleCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        for device in discoverySession.devices {
            switch camera {
            case .continuityCamera:
                if device.isContinuityCamera, device.deviceType != .deskViewCamera {
                    return device
                }
            case .offcutsCam:
                if device.localizedName == camera.rawValue {
                    return device
                }
            }
        }
        return AVCaptureDevice.userPreferredCamera
    }
}

// MARK: - Identifiers

enum Identifiers: String {
    case appGroup = "Z39BRGKSRW.com.politepix.OffcutsCam"
    case orgIDAndProduct = "com.politepix.OffcutsCam"
}

// MARK: - NotificationName

enum NotificationName: String, CaseIterable {
    case startStream = "Z39BRGKSRW.com.politepix.OffcutsCam.startStream"
    case stopStream = "Z39BRGKSRW.com.politepix.OffcutsCam.stopStream"
}

// MARK: - MoodName

enum MoodName: String, CaseIterable {
    case bypass = "Bypass"
    case newWave = "New Wave"
    case berlin = "Berlin"
    case oldFilm = "OldFilm"
    case sunset = "Sunset"
    case badEnergy = "BadEnergy"
    case beyondTheBeyond = "BeyondTheBeyond"
    case drama = "Drama"
}

// MARK: - PropertyName

enum PropertyName: String, CaseIterable {
    case mood
}

// MARK: - NotificationManager

class NotificationManager {
    class func postNotification(named notificationName: String) {
        let completeNotificationName = Identifiers.appGroup.rawValue + "." + notificationName
        logger
            .debug(
                "Posting notification \(completeNotificationName) from container app"
            )

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(completeNotificationName as NSString),
            nil,
            nil,
            true
        )
    }

    class func postNotification(named notificationName: NotificationName) {
        logger
            .debug(
                "Posting notification \(notificationName.rawValue) from container app"
            )

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName.rawValue as NSString),
            nil,
            nil,
            true
        )
    }
}

extension String {
    func convertedToCMIOObjectPropertySelectorName() -> CMIOObjectPropertySelector {
        let noName: CMIOObjectPropertySelector = 0
        if count == MemoryLayout<CMIOObjectPropertySelector>.size {
            return data(using: .utf8, allowLossyConversion: false)?.withUnsafeBytes {
                $0.load(as: CMIOObjectPropertySelector.self).byteSwapped
            } ?? noName
        } else {
            return noName
        }
    }
}
