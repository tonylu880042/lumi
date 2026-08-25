import OSLog

/// Closed, privacy-safe identity diagnostics.
///
/// Events intentionally carry no associated values. This prevents callers
/// from attaching names, member identifiers, images, embeddings, framework
/// errors, or other runtime payloads to a log line.
enum IdentityDiagnosticEvent: String, CaseIterable, Equatable, Sendable {
    case cameraStartRequested = "camera start requested"
    case cameraStartSucceeded = "camera start succeeded"
    case cameraStartCancelled = "camera start cancelled"
    case cameraStartFailedAlreadyRunning =
        "camera start failed reason=already-running"
    case cameraStartFailedPermissionDenied =
        "camera start failed reason=permission-denied"
    case cameraStartFailedPermissionRestricted =
        "camera start failed reason=permission-restricted"
    case cameraStartFailedUnavailable =
        "camera start failed reason=camera-unavailable"
    case cameraStartFailedCapture =
        "camera start failed reason=capture-failed"
    case cameraStopRequested = "camera stop requested"
    case cameraStopSucceeded = "camera stop succeeded"

    case cameraBackendFailedNoFrontCamera =
        "camera backend failed reason=no-front-camera"
    case cameraBackendFailedCannotAddInput =
        "camera backend failed reason=cannot-add-input"
    case cameraBackendFailedCannotAddOutput =
        "camera backend failed reason=cannot-add-output"
    case cameraBackendFailedUnsupportedPixelFormat =
        "camera backend failed reason=unsupported-pixel-format"
    case cameraBackendFailedUnsupportedRotation =
        "camera backend failed reason=unsupported-initial-rotation"
    case cameraBackendFailedMirroring =
        "camera backend failed reason=cannot-disable-mirroring"
    case cameraBackendFailedUnexpected =
        "camera backend failed reason=unexpected"

    case cameraInterruptedBackground =
        "camera interrupted reason=app-backgrounded"
    case cameraInterruptedDeviceInUse =
        "camera interrupted reason=device-in-use-by-another-client"
    case cameraInterruptedMultipleForegroundApps =
        "camera interrupted reason=multiple-foreground-apps"
    case cameraInterruptedSystemPressure =
        "camera interrupted reason=system-pressure"
    case cameraInterruptedUnknown =
        "camera interrupted reason=unknown"
    case cameraInterruptionEnded = "camera interruption ended"
    case cameraRuntimeErrorMediaServicesWereReset =
        "camera runtime-error reason=media-services-reset"
    case cameraRuntimeErrorUnknown =
        "camera runtime-error reason=unknown"
    case cameraRuntimeRotationUnsupported =
        "camera runtime-error reason=unsupported-rotation"

    case framePipelineFailedVision =
        "frame pipeline failed stage=vision-face-detection"
    case framePipelineFailedYuNet =
        "frame pipeline failed stage=yunet-candidate-detection"
    case framePipelineFailedAlignment =
        "frame pipeline failed stage=sface-alignment-crop"
    case framePipelineFailedSFace =
        "frame pipeline failed stage=sface-embedding"

    case identityFactoryLoadStarted = "identity factory load started"
    case identityFactoryLoadSucceeded = "identity factory load succeeded"
    case identityFactoryFailedInvalidModelResources =
        "identity factory failed stage=model-resource-validation"
    case identityFactoryFailedSFaceModelLoad =
        "identity factory failed stage=sface-model-load"
    case identityFactoryFailedYuNetModelLoad =
        "identity factory failed stage=yunet-model-load"
    case identityFactoryFailedSFaceConfiguration =
        "identity factory failed stage=sface-configuration"
    case identityFactoryFailedYuNetConfiguration =
        "identity factory failed stage=yunet-configuration"
    case identityFactoryFailedDatabase =
        "identity factory failed stage=database-open"

    case presenceArrivalStarted = "presence arrival started"
    case presenceArrivalSucceeded = "presence arrival succeeded"
    case presenceArrivalCancelled = "presence arrival cancelled"
    case presenceArrivalFailedCameraStart =
        "presence arrival failed stage=camera-start"
    case presenceArrivalFailedFaceCapture =
        "presence arrival failed stage=face-capture"
    case presenceDepartureStarted = "presence departure started"
    case presenceDepartureSucceeded = "presence departure succeeded"
    case presenceDepartureCancelled = "presence departure cancelled"
    case presenceDepartureFailedCameraStart =
        "presence departure failed stage=camera-start"
    case presenceDepartureFailedFaceCapture =
        "presence departure failed stage=face-capture"

    fileprivate var level: OSLogType {
        switch self {
        case .cameraStartFailedAlreadyRunning,
             .cameraStartFailedPermissionDenied,
             .cameraStartFailedPermissionRestricted,
             .cameraStartFailedUnavailable,
             .cameraStartFailedCapture,
             .cameraBackendFailedNoFrontCamera,
             .cameraBackendFailedCannotAddInput,
             .cameraBackendFailedCannotAddOutput,
             .cameraBackendFailedUnsupportedPixelFormat,
             .cameraBackendFailedUnsupportedRotation,
             .cameraBackendFailedMirroring,
             .cameraBackendFailedUnexpected,
             .cameraRuntimeErrorMediaServicesWereReset,
             .cameraRuntimeErrorUnknown,
             .cameraRuntimeRotationUnsupported,
             .framePipelineFailedVision,
             .framePipelineFailedYuNet,
             .framePipelineFailedAlignment,
             .framePipelineFailedSFace,
             .identityFactoryFailedInvalidModelResources,
             .identityFactoryFailedSFaceModelLoad,
             .identityFactoryFailedYuNetModelLoad,
             .identityFactoryFailedSFaceConfiguration,
             .identityFactoryFailedYuNetConfiguration,
             .identityFactoryFailedDatabase,
             .presenceArrivalFailedCameraStart,
             .presenceArrivalFailedFaceCapture,
             .presenceDepartureFailedCameraStart,
             .presenceDepartureFailedFaceCapture:
            .error
        case .cameraInterruptedBackground,
             .cameraInterruptedDeviceInUse,
             .cameraInterruptedMultipleForegroundApps,
             .cameraInterruptedSystemPressure,
             .cameraInterruptedUnknown,
             .cameraStartCancelled,
             .presenceArrivalCancelled,
             .presenceDepartureCancelled:
            .default
        default:
            .info
        }
    }
}

typealias IdentityDiagnosticSink = @Sendable (IdentityDiagnosticEvent) -> Void

enum IdentityDiagnostics {
    private static let logger = Logger(
        subsystem: "com.curves.lumi",
        category: "identity-recognition"
    )

    static func record(_ event: IdentityDiagnosticEvent) {
        logger.log(level: event.level, "\(event.rawValue, privacy: .public)")
    }
}
