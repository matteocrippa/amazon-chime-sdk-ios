//
//  DualCameraCaptureSource.swift
//  AmazonChimeSDKDemo
//
//  Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
//  SPDX-License-Identifier: Apache-2.0
//

import AVFoundation
import Foundation
import UIKit
import AmazonChimeSDK


public class PassthroughVideoFrameAdapter: NSObject, VideoSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    public var videoContentHint: VideoContentHint = .motion
    private let sinks = NSMutableSet()
    private let dualCameraCaptureSource: DualCameraCaptureSource
    private let isFront: Bool
    
    public init(dualCameraCaptureSource: DualCameraCaptureSource, isFront: Bool) {
        self.dualCameraCaptureSource = dualCameraCaptureSource
        self.isFront = isFront
    }
    
    public func addVideoSink(sink: VideoSink) {
        sinks.add(sink)
    }

    public func removeVideoSink(sink: VideoSink) {
        sinks.remove(sink)
    }
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from _: AVCaptureConnection) {
        guard let frame = VideoFrame(sampleBuffer: sampleBuffer) else {
            print("DefaultCameraCaptureSource could not convert captured CMSampleBuffer to video frame")
            return
        }
        
        let videoDataOutput = output as? AVCaptureVideoDataOutput

        sinks.forEach { item in
            guard let sink = item as? VideoSink else { return }
            if videoDataOutput == dualCameraCaptureSource.frontCameraVideoDataOutput, isFront{
                sink.onVideoFrameReceived(frame: frame)
            }
            if videoDataOutput == dualCameraCaptureSource.backCameraVideoDataOutput, !isFront{
                sink.onVideoFrameReceived(frame: frame)
            }
        }
    }
}

public class DualCameraCaptureSource: NSObject, VideoSource {
    public var frontFrameAdapter: PassthroughVideoFrameAdapter?
    public var backFrameAdapter: PassthroughVideoFrameAdapter?
    public var videoContentHint: VideoContentHint = .motion
    private let logger: Logger
    private let cameraLock = NSLock()
    private let deviceType = AVCaptureDevice.DeviceType.builtInWideAngleCamera
    private let sinks = NSMutableSet()
    private let captureSourceObservers = NSMutableSet()
    private var backCameraDeviceInput: AVCaptureDeviceInput?
    public let backCameraVideoDataOutput = AVCaptureVideoDataOutput()
    private var frontCameraDeviceInput: AVCaptureDeviceInput?
    public let frontCameraVideoDataOutput = AVCaptureVideoDataOutput()
    private let dataOutputQueue = DispatchQueue(label: "data output queue")
    private static let defaultCaptureFormat = VideoCaptureFormat(width: Constants.maxSupportedVideoWidth,
                                                                 height: Constants.maxSupportedVideoHeight,
                                                                 maxFrameRate: Constants.maxSupportedVideoFrameRate)

    @available(iOS 13.0, *)
    lazy var session: AVCaptureMultiCamSession = {
        let source = AVCaptureMultiCamSession()
        return source
    }()
    private var orientation = UIInterfaceOrientation.portrait
    private var captureDevice: AVCaptureDevice?
    private var frontCamera: AVCaptureDevice?
    private var backCamera: AVCaptureDevice?
    private var eventAnalyticsController: EventAnalyticsController?

    public init(logger: Logger) {
        self.logger = logger
        super.init()
        frontFrameAdapter = PassthroughVideoFrameAdapter(dualCameraCaptureSource: self, isFront: true)
        backFrameAdapter = PassthroughVideoFrameAdapter(dualCameraCaptureSource: self, isFront: false)
        device = MediaDevice.listVideoDevices().first { mediaDevice in
            mediaDevice.type == MediaDeviceType.videoFrontCamera
        }
        frontCamera = AVCaptureDevice.default(deviceType,
                                               for: .video,
                                               position: .front)
        backCamera = AVCaptureDevice.default(deviceType,
                                             for: .video,
                                             position: .back)

        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self,
                                       selector: #selector(deviceOrientationDidChange),
                                       name: UIDevice.orientationDidChangeNotification,
                                       object: nil)
    }

    deinit {
        if torchEnabled {
            torchEnabled = false
        }
        guard #available(iOS 13.0, *) else {
            logger.error(msg: "Dual Camera is only available on iOS 13+")
            return
        }
        if session.isRunning {
            session.stopRunning()
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    public var device: MediaDevice? = MediaDevice.listVideoDevices().first {
        didSet {
            guard let device = device else { return }
            let isUsingFrontCamera = device.type == .videoFrontCamera
            captureDevice = isUsingFrontCamera ? frontCamera : backCamera
            guard #available(iOS 13.0, *) else {
                logger.error(msg: "Dual Camera is only available on iOS 13+")
                return
            }
            if session.isRunning {
                start() // Restart
            }
        }
    }

    public var format: VideoCaptureFormat = defaultCaptureFormat {
        didSet {
            guard #available(iOS 13.0, *) else {
                logger.error(msg: "Dual Camera is only available on iOS 13+")
                return
            }
            if captureDevice != nil, session.isRunning {
                start() // Restart
            }
        }
    }

    public var torchEnabled: Bool = false {
        didSet {
            if let captureDevice = captureDevice, torchAvailable {
                do {
                    try captureDevice.lockForConfiguration()
                    if torchEnabled {
                        captureDevice.torchMode = .on
                    } else {
                        captureDevice.torchMode = .off
                    }
                    captureDevice.unlockForConfiguration()
                } catch {
                    logger.error(msg: "Unable to set torch on current camera. Error: \(error.localizedDescription)")
                }
            } else {
                torchEnabled = false
                logger.info(msg: "Torch is not available on current camera.")
            }
        }
    }

    /// Expose current capture device's torch availability
    public var torchAvailable: Bool {
        guard let captureDevice = captureDevice else {
            return false
        }

        return captureDevice.hasTorch && captureDevice.isTorchAvailable
    }

    public func addVideoSink(sink: VideoSink) {
        sinks.add(sink)
    }

    public func removeVideoSink(sink: VideoSink) {
        sinks.remove(sink)
    }

    private func configureBackCamera() {
        guard #available(iOS 13.0, *) else {
            logger.error(msg: "Dual Camera is only available on iOS 13+")
            return
        }
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        
        // Find the back camera
        guard let backCamera = backCamera else {
            logger.error(msg: "Could not find the back camera")
            return
        }
        
        // Add the back camera input to the session
        do {
            backCameraDeviceInput = try AVCaptureDeviceInput(device: backCamera)
            
            guard let backCameraDeviceInput = backCameraDeviceInput,
                session.canAddInput(backCameraDeviceInput) else {
                logger.error(msg: "Could not add back camera device input")
                    return
            }
            session.addInputWithNoConnections(backCameraDeviceInput)
        } catch {
            logger.error(msg: "Could not create back camera device input: \(error)")
            return
        }
        
        // Find the back camera device input's video port
        guard let backCameraDeviceInput = backCameraDeviceInput,
            let backCameraVideoPort = backCameraDeviceInput.ports(for: .video,
                                                              sourceDeviceType: backCamera.deviceType,
                                                              sourceDevicePosition: backCamera.position).first else {
            logger.error(msg: "Could not find the back camera device input's video port")
                                                                return
        }
        
        // Add the back camera video data output
        guard session.canAddOutput(backCameraVideoDataOutput) else {
            logger.error(msg: "Could not add the back camera video data output")
            return
        }
        session.addOutputWithNoConnections(backCameraVideoDataOutput)
        
        backCameraVideoDataOutput.setSampleBufferDelegate(backFrameAdapter, queue: dataOutputQueue)
        
        // Connect the back camera device input to the back camera video data output
        let backCameraVideoDataOutputConnection = AVCaptureConnection(inputPorts: [backCameraVideoPort], output: backCameraVideoDataOutput)
        guard session.canAddConnection(backCameraVideoDataOutputConnection) else {
            logger.error(msg: "Could not add a connection to the back camera video data output")
            return
        }
        session.addConnection(backCameraVideoDataOutputConnection)
        backCameraVideoDataOutputConnection.videoOrientation = .portrait
        return
    }
    
    private func configureFrontCamera(){
        guard #available(iOS 13.0, *) else {
            logger.error(msg: "Dual Camera is only available on iOS 13+")
            return
        }
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        
        // Find the front camera
        guard let frontCamera = frontCamera else {
            logger.error(msg: "Could not find the front camera")
            return
        }
        
        // Add the front camera input to the session
        do {
            frontCameraDeviceInput = try AVCaptureDeviceInput(device: frontCamera)
            
            guard let frontCameraDeviceInput = frontCameraDeviceInput,
                session.canAddInput(frontCameraDeviceInput) else {
                logger.error(msg: "Could not add front camera device input")
                    return
            }
            session.addInputWithNoConnections(frontCameraDeviceInput)
        } catch {
            logger.error(msg: "Could not create front camera device input: \(error)")
            return
        }
        
        // Find the front camera device input's video port
        guard let frontCameraDeviceInput = frontCameraDeviceInput,
            let frontCameraVideoPort = frontCameraDeviceInput.ports(for: .video,
                                                                    sourceDeviceType: frontCamera.deviceType,
                                                                    sourceDevicePosition: frontCamera.position).first else {
            logger.error(msg: "Could not find the front camera device input's video port")
                                                                        return
        }
        
        // Add the front camera video data output
        guard session.canAddOutput(frontCameraVideoDataOutput) else {
            logger.error(msg: "Could not add the front camera video data output")
            return
        }
        session.addOutputWithNoConnections(frontCameraVideoDataOutput)

        frontCameraVideoDataOutput.setSampleBufferDelegate(frontFrameAdapter, queue: dataOutputQueue)
        
        // Connect the front camera device input to the front camera video data output
        let frontCameraVideoDataOutputConnection = AVCaptureConnection(inputPorts: [frontCameraVideoPort], output: frontCameraVideoDataOutput)
        guard session.canAddConnection(frontCameraVideoDataOutputConnection) else {
            logger.error(msg: "Could not add a connection to the front camera video data output")
            return
        }
        session.addConnection(frontCameraVideoDataOutputConnection)
        
        frontCameraVideoDataOutputConnection.videoOrientation = .portrait
        frontCameraVideoDataOutputConnection.automaticallyAdjustsVideoMirroring = false
        frontCameraVideoDataOutputConnection.isVideoMirrored = true
        return
    }
    
    public func start() {
        cameraLock.lock()
        defer { cameraLock.unlock() }
        guard #available(iOS 13.0, *) else {
            logger.error(msg: "Dual Camera is only available on iOS 13+")
            return
        }
        session.beginConfiguration()
        
        configureBackCamera()
        configureFrontCamera()
            
        session.commitConfiguration()
        session.startRunning()

        // If the torch was currently on, starting the sessions
        // would turn it off. See if we can turn it back on.
        let currentTorchEnabled = torchEnabled
        self.torchEnabled = currentTorchEnabled
    }

    public func stop() {
        cameraLock.lock()
        defer { cameraLock.unlock() }

        guard #available(iOS 13.0, *) else {
            logger.error(msg: "Dual Camera is only available on iOS 13+")
            return
        }
        session.stopRunning()

        // If the torch was currently on, stopping the sessions
        // would turn it off. See if we can turn it back on.
        let currentTorchEnabled = torchEnabled
        self.torchEnabled = currentTorchEnabled
    }

    public func addCaptureSourceObserver(observer: CaptureSourceObserver) {
        captureSourceObservers.add(observer)
    }

    public func removeCaptureSourceObserver(observer: CaptureSourceObserver) {
        captureSourceObservers.remove(observer)
    }
    
    public func switchCamera() {
        let isUsingFrontCamera = device?.type == .videoFrontCamera
        device = MediaDevice.listVideoDevices().first { mediaDevice in
            mediaDevice.type == (isUsingFrontCamera ? .videoBackCamera : .videoFrontCamera)
        }

        if device != nil {
            eventAnalyticsController?.pushHistory(historyEventName: .videoInputSelected)
        }
    }

    private func updateOrientation() {
        guard let frontConnection = frontCameraVideoDataOutput.connection(with: AVMediaType.video) else {
            return
        }
        guard let backConnection = backCameraVideoDataOutput.connection(with: AVMediaType.video) else {
            return
        }

        DispatchQueue.main.async {
            self.orientation = UIApplication.shared.statusBarOrientation

            switch self.orientation {
            case .portrait, .unknown:
                frontConnection.videoOrientation = .portrait
                backConnection.videoOrientation = .portrait
            case .portraitUpsideDown:
                frontConnection.videoOrientation = .portraitUpsideDown
                backConnection.videoOrientation = .portraitUpsideDown
            case .landscapeLeft:
                frontConnection.videoOrientation = .landscapeLeft
                backConnection.videoOrientation = .landscapeLeft
            case .landscapeRight:
                frontConnection.videoOrientation = .landscapeRight
                backConnection.videoOrientation = .landscapeRight
            @unknown default:
                break
            }
        }
    }

    @objc private func deviceOrientationDidChange(notification: NSNotification) {
        dataOutputQueue.async {
            self.updateOrientation()
        }
    }

    public func setEventAnalyticsController(eventAnalyticsController: EventAnalyticsController?) {
        self.eventAnalyticsController = eventAnalyticsController
    }
}
