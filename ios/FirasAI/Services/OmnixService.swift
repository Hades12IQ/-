import Foundation
import CryptoKit

/// Only the account-bound web endpoints are used; no worker/model key lives on the phone.
enum OmnixService {
    static func access(api: APIClient) async throws -> OmnixAccess {
        try await api.json(.get, "/api/omnix/access", as: OmnixAccess.self)
    }
    static func cloud(api: APIClient) async throws -> OmnixCloudStatus {
        try await api.json(.get, "/api/omnix/cloud", as: OmnixCloudStatus.self)
    }
    static func requestAccess(reason: String, api: APIClient) async throws -> OmnixAccess {
        guard (20...1200).contains(reason.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) else {
            throw APIError.decoding("omnix_access_reason")
        }
        return try await api.json(.post, "/api/omnix/access", body: OmnixAccessRequest(reason: reason), as: OmnixAccess.self)
    }
    static func submit(_ request: OmnixSubmission, api: APIClient) async throws -> OmnixJob {
        guard request.text.utf16.count <= 60_000, ["ai", "code"].contains(request.product) else {
            throw APIError.decoding("omnix_request_invalid")
        }
        return try await api.json(.post, "/api/omnix/runs", body: request, budget: .poll, as: OmnixJob.self)
    }
    static func conversation(_ id: String, api: APIClient) async throws -> OmnixConversationJobs {
        guard OmnixReceipt.matches(id, #"^[A-Za-z0-9_-]{1,128}$"#) else { throw APIError.invalidURL }
        let result = try await api.json(.get, "/api/omnix/conversations/" + id, budget: .poll, as: OmnixConversationJobs.self)
        guard result.conversationId == id else { throw APIError.decoding("omnix_conversation_binding") }
        return result
    }
    static func job(_ receipt: OmnixReceipt, api: APIClient) async throws -> OmnixJob {
        guard receipt.isValid, !receipt.jobId.isEmpty else { throw APIError.invalidURL }
        let result = try await api.json(.get, "/api/omnix/runs/" + receipt.jobId, budget: .poll, as: OmnixJob.self)
        guard receipt.accepts(result) else { throw APIError.decoding("omnix_run_binding") }
        return result
    }
    static func cancel(_ receipt: OmnixReceipt, api: APIClient) async throws -> OmnixCancellation {
        guard receipt.isValid else { throw APIError.invalidURL }
        if !receipt.jobId.isEmpty {
            let job = try await api.json(.post, "/api/omnix/runs/" + receipt.jobId + "/cancel", body: OmnixEmpty(), budget: .poll, as: OmnixJob.self)
            guard receipt.accepts(job) else { throw APIError.decoding("omnix_cancel_binding") }
            return OmnixCancellation(requestKey: receipt.requestKey, cancelled: ["cancelled", "canceled"].contains(job.state), job: job)
        }
        let result = try await api.json(.post, "/api/omnix/conversations/" + receipt.conversationId + "/cancel-request", body: OmnixCancelRequest(requestKey: receipt.requestKey), budget: .poll, as: OmnixCancellation.self)
        guard result.requestKey == receipt.requestKey, result.job.map(receipt.accepts) ?? true else {
            throw APIError.decoding("omnix_cancel_binding")
        }
        return result
    }
    static func approve(_ receipt: OmnixReceipt, request: OmnixApprovalRequest, api: APIClient) async throws {
        guard receipt.isValid, !receipt.jobId.isEmpty, ["once", "deny"].contains(request.choice) else { throw APIError.invalidURL }
        _ = try await api.raw(.post, "/api/omnix/runs/" + receipt.jobId + "/approval", body: request, budget: .poll)
    }
    static func definitelyNotAdmitted(_ error: Error) -> Bool {
        guard case APIError.http(_, _, let raw) = error, let bytes = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
        return object["admitted"] as? Bool == false
    }

    struct Input: Sendable {
        let clientID: String
        let name: String
        let mime: String
        let bytes: Data
        var sha256: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }
    static func inputs(_ attachments: [PreparedAttachment]) throws -> [Input] {
        guard attachments.count <= 10 else { throw APIError.decoding("omnix_inputs_limit") }
        var total = 0
        return try attachments.map { item in
            let bytes: Data
            let name: String
            let mime: String
            if let original = item.originalData {
                bytes = original
                let declaredMime = item.originalMime?.lowercased()
                if item.kind == "image" || declaredMime == "image/jpeg" || declaredMime == "image/png" {
                    let image = try imageIdentity(bytes: original, name: item.name, declaredMime: declaredMime)
                    name = image.name; mime = image.mime
                } else {
                    name = item.name; mime = item.originalMime ?? "application/octet-stream"
                }
            } else if let base64 = item.imageBase64, let image = Data(base64Encoded: base64) {
                bytes = image
                let identity = try imageIdentity(bytes: image, name: item.name, declaredMime: nil)
                name = identity.name; mime = identity.mime
            } else if let text = item.text, !text.isEmpty, !item.truncated {
                bytes = Data(text.utf8); name = item.name + ".txt"; mime = "text/plain"
            } else { throw APIError.decoding("omnix_original_attachment_unavailable") }
            total += bytes.count
            guard !bytes.isEmpty, bytes.count <= 20 * 1024 * 1024, total <= 25 * 1024 * 1024,
                  name.utf8.count <= 240, name.utf16.count <= 180, !name.hasPrefix("."),
                  name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                  name.range(of: #"[\x00-\x1f\x7f/\\:\u202a-\u202e\u2066-\u2069]"#, options: .regularExpression) == nil else {
                throw APIError.decoding("omnix_inputs_limit")
            }
            return Input(clientID: UUID().uuidString.replacingOccurrences(of: "-", with: ""), name: name, mime: mime, bytes: bytes)
        }
    }
    /// The picker re-encodes images to JPEG while retaining the source chip's filename.
    /// Upload names must describe those bytes because the server validates extension and signature.
    private static func imageIdentity(bytes: Data, name: String, declaredMime: String?) throws -> (name: String, mime: String) {
        let png = Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10]
        let jpeg = Array(bytes.prefix(3)) == [255, 216, 255]
        guard png || jpeg else { throw APIError.decoding("omnix_image_bytes_unsupported") }
        let mime = png ? "image/png" : "image/jpeg"
        guard declaredMime == nil || declaredMime == "application/octet-stream" || declaredMime == mime else {
            throw APIError.decoding("omnix_image_type_mismatch")
        }
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        return (stem + (png ? ".png" : ".jpg"), mime)
    }
    static func upload(_ input: Input, receipt: OmnixReceipt, api: APIClient) async throws -> OmnixInputReceipt {
        guard receipt.isValid, receipt.jobId.isEmpty else { throw APIError.invalidURL }
        let encodedName = input.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let result = try await api.uploadBytes("/api/omnix/inputs/" + receipt.requestKey + "/" + input.clientID,
            data: input.bytes, headers: ["content-type": input.mime, "x-omnix-conversation": receipt.conversationId,
                "x-omnix-size": String(input.bytes.count), "x-omnix-filename": encodedName, "x-omnix-sha256": input.sha256],
            as: OmnixInputReceipt.self)
        guard OmnixReceipt.matches(result.id, #"^[a-f0-9]{64}$"#), result.requestKey == receipt.requestKey,
              result.name == input.name, result.size == input.bytes.count, result.sha256 == input.sha256 else {
            throw APIError.decoding("omnix_attachment_binding")
        }
        return result
    }
    static func download(_ file: OmnixFile, api: APIClient) async throws -> URL {
        guard let path = file.downloadPath else { throw APIError.invalidURL }
        let response = try await api.download(path)
        let attrs = try FileManager.default.attributesOfItem(atPath: response.url.path)
        if let size = file.size, (attrs[.size] as? NSNumber)?.intValue != size {
            try? FileManager.default.removeItem(at: response.url)
            throw APIError.decoding("omnix_file_size")
        }
        if let expected = file.sha256 {
            let bytes = try Data(contentsOf: response.url, options: .mappedIfSafe)
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                try? FileManager.default.removeItem(at: response.url)
                throw APIError.decoding("omnix_file_hash")
            }
        }
        return response.url
    }
}
