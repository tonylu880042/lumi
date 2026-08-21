#if DEBUG

import Foundation
import LumiDomain

/// Stable, payload-free failure for the DEBUG identity calibration tool.
///
/// The calibration surface deliberately does not expose camera, Vision,
/// Core ML, SQLite, embedding, or recognition-policy diagnostics.
public enum IdentityCalibrationError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    case failed

    public var description: String {
        "Identity calibration failed."
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [:], displayStyle: .enum)
    }
}

/// One transient photo selected by the DEBUG App photo picker.
///
/// The encoded bytes remain in memory for one operation only. Application and
/// Infrastructure must not retain, persist, log, or expose this value after
/// the capture call returns.
public struct IdentityCalibrationPhoto: Equatable, Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}

/// The result of one manually requested enrollment capture.
public enum IdentityCalibrationCaptureResult: Equatable, Sendable {
    case noUsableFace
    case stored
}

/// The result of one manually requested return-visit capture.
public enum IdentityCalibrationReturnResult: Equatable, Sendable {
    case noUsableFace
    case measured(IdentityCalibrationEvidence)
}

/// One temporary calibration-gallery candidate and its raw cosine score.
///
/// These are calibration observations only. They are not a `known` or
/// `unknown` identity decision and must not be routed through the production
/// confidence policy.
public struct IdentityCalibrationCandidate: Equatable, Sendable {
    public let memberID: MemberID
    public let cosineSimilarity: Double

    public init(memberID: MemberID, cosineSimilarity: Double) {
        self.memberID = memberID
        self.cosineSimilarity = cosineSimilarity
    }
}

/// Score-only evidence from the complete temporary calibration gallery.
///
/// `gallerySampleCount` counts all SFace samples currently in that dedicated
/// calibration gallery. The top candidates are distinct temporary members;
/// no acceptance threshold or identity decision is represented here.
public struct IdentityCalibrationEvidence: Equatable, Sendable {
    public let gallerySampleCount: Int
    public let top1: IdentityCalibrationCandidate?
    public let top2: IdentityCalibrationCandidate?

    public init(
        gallerySampleCount: Int,
        top1: IdentityCalibrationCandidate?,
        top2: IdentityCalibrationCandidate?
    ) {
        self.gallerySampleCount = gallerySampleCount
        self.top1 = top1
        self.top2 = top2
    }

    public var margin: Double? {
        guard let top1, let top2 else { return nil }
        return top1.cosineSimilarity - top2.cosineSimilarity
    }
}

/// Application-facing DEBUG calibration boundary.
///
/// Implementations own the camera session and all Vision/Core ML/SQLite
/// details. The UI receives only lifecycle completion, sample outcomes, and
/// score evidence; it never receives an owned frame, embedding, SDK object,
/// `UnknownReason`, or production recognition decision.
public protocol IdentityCalibrationPort: Sendable {
    func startCamera() async throws
    func stopCamera() async

    func captureEnrollmentSample(
        for temporaryMemberID: MemberID,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult

    /// Imports one transient user-selected image. The implementation must not
    /// retain or persist the URL or any decoded photo bytes.
    func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from imageURL: URL,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult

    /// Imports one transient in-memory user-selected image. Implementations
    /// must not retain or persist the encoded bytes.
    func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from photo: IdentityCalibrationPhoto,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult

    func captureReturnVisit() async throws -> IdentityCalibrationReturnResult

    /// Imports one transient user-selected return-visit image. No sample is
    /// written; the result ranks the existing calibration gallery.
    func captureReturnVisitPhoto(
        from imageURL: URL
    ) async throws -> IdentityCalibrationReturnResult

    /// Imports one transient in-memory return-visit image. No sample is
    /// written; implementations must not retain or persist the bytes.
    func captureReturnVisitPhoto(
        from photo: IdentityCalibrationPhoto
    ) async throws -> IdentityCalibrationReturnResult

    func sampleCount(for temporaryMemberID: MemberID) async throws -> Int

    /// Deletes only the explicitly selected temporary member's calibration
    /// samples. The App must gate this behind an explicit confirmation.
    func reset(for temporaryMemberID: MemberID) async throws
}

public extension IdentityCalibrationPort {
    /// Compatibility default for existing DEBUG-only port implementations.
    /// New photo paths fail closed until the implementation opts in.
    func captureEnrollmentPhoto(
        for temporaryMemberID: MemberID,
        from photo: IdentityCalibrationPhoto,
        at createdAt: Date
    ) async throws -> IdentityCalibrationCaptureResult {
        _ = temporaryMemberID
        _ = photo
        _ = createdAt
        throw IdentityCalibrationError.failed
    }

    /// Compatibility default for existing DEBUG-only port implementations.
    /// New photo paths fail closed until the implementation opts in.
    func captureReturnVisitPhoto(
        from photo: IdentityCalibrationPhoto
    ) async throws -> IdentityCalibrationReturnResult {
        _ = photo
        throw IdentityCalibrationError.failed
    }
}

#endif
