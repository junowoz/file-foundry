import Foundation

struct AssemblyAIClient {
    let apiKey: String
    let region: AssemblyRegion
    private let session: URLSession

    init(apiKey: String, region: AssemblyRegion, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
        self.session = session
    }

    func validateKey() async throws {
        var request = try request(path: "/v2/transcript", method: "GET")
        request.url = request.url?.appending(queryItems: [URLQueryItem(name: "limit", value: "1")])
        _ = try await data(for: request)
    }

    func upload(fileURL: URL) async throws -> String {
        var request = try request(path: "/v2/upload", method: "POST")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return try await Self.withTransientRetries {
            let (data, response) = try await session.upload(for: request, fromFile: fileURL)
            try validate(response: response, data: data)
            return try JSONDecoder().decode(UploadResponse.self, from: data).uploadURL
        }
    }

    /// Retries server errors (5xx, 429) and dropped connections up to 3 times, waiting 3, 10 and 30 seconds.
    /// Long uploads often hit a brief AssemblyAI or network hiccup that a retry clears.
    static func withTransientRetries<T>(_ operation: () async throws -> T) async throws -> T {
        let delays: [UInt64] = [3, 10, 30]
        var attempt = 0
        while true {
            do { return try await operation() }
            catch {
                guard attempt < delays.count, isTransient(error), !Task.isCancelled else { throw error }
                try await Task.sleep(nanoseconds: delays[attempt] * 1_000_000_000)
                attempt += 1
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if case ClientError.transient = error { return true }
        guard let urlError = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code)
    }

    func submit(audioURL: String, settings: TranscriptionSettings) async throws -> String {
        var payload: [String: ScribeJSONValue] = [
            "audio_url": .string(audioURL),
            "speech_models": .array(settings.model.modelIDs.map(ScribeJSONValue.string)),
            "speaker_labels": .bool(settings.speakerLabels),
            "punctuate": .bool(settings.speakerLabels || settings.sentimentAnalysis || settings.punctuate),
            "format_text": .bool(settings.redactPII || settings.formatText),
            "disfluencies": .bool(settings.disfluencies)
        ]
        if settings.languageCode.isEmpty { payload["language_detection"] = .bool(true) }
        else { payload["language_code"] = .string(settings.languageCode) }
        if let count = settings.expectedSpeakers, settings.speakerLabels { payload["speakers_expected"] = .int(count) }
        else if settings.speakerLabels, let minimum = settings.minimumSpeakers, let maximum = settings.maximumSpeakers {
            payload["speaker_options"] = .object(["min_speakers_expected": .int(minimum), "max_speakers_expected": .int(maximum)])
        }
        if settings.multichannel { payload["multichannel"] = .bool(true) }
        if !settings.prompt.isEmpty, settings.model != .universal2 { payload["prompt"] = .string(settings.prompt) }
        if !settings.parsedKeyterms.isEmpty { payload["keyterms_prompt"] = .array(settings.parsedKeyterms.map(ScribeJSONValue.string)) }
        if !settings.parsedCustomSpelling.isEmpty {
            payload["custom_spelling"] = .array(settings.parsedCustomSpelling.map {
                .object(["from": .array($0.from.map(ScribeJSONValue.string)), "to": .string($0.to)])
            })
        }
        if settings.model != .universal2 { payload["remove_audio_tags"] = .string(settings.audioTags.rawValue) }
        if settings.filterProfanity { payload["filter_profanity"] = .bool(true) }
        if settings.redactPII {
            payload["redact_pii"] = .bool(true)
            payload["redact_pii_sub"] = .string(settings.piiSubstitution.rawValue)
            payload["redact_pii_policies"] = .array([
                "person_name", "email_address", "phone_number", "credit_card_number", "us_social_security_number", "date_of_birth"
            ].map(ScribeJSONValue.string))
        }
        if settings.entityDetection { payload["entity_detection"] = .bool(true) }
        if settings.sentimentAnalysis { payload["sentiment_analysis"] = .bool(true) }
        if settings.autoHighlights { payload["auto_highlights"] = .bool(true) }
        if settings.contentSafety { payload["content_safety"] = .bool(true) }
        if settings.iabCategories { payload["iab_categories"] = .bool(true) }
        if settings.medicalMode { payload["domain"] = .string("medical-v1") }
        if let start = settings.audioStartSeconds { payload["audio_start_from"] = .int(Int(start * 1_000)) }
        if let end = settings.audioEndSeconds { payload["audio_end_at"] = .int(Int(end * 1_000)) }
        if settings.speakerLabels, !settings.parsedSpeakerNames.isEmpty {
            payload["speech_understanding"] = .object([
                "request": .object([
                    "speaker_identification": .object([
                        "speaker_type": .string("name"),
                        "known_values": .array(settings.parsedSpeakerNames.map(ScribeJSONValue.string))
                    ])
                ])
            ])
        }

        var request = try request(path: "/v2/transcript", method: "POST")
        request.httpBody = try JSONEncoder().encode(payload)
        let data = try await data(for: request)
        return try JSONDecoder().decode(SubmitResponse.self, from: data).id
    }

    func waitForTranscript(id: String, onStatus: @escaping @Sendable (String) async -> Void) async throws -> CompletedTranscript {
        while !Task.isCancelled {
            let data = try await data(for: request(path: "/v2/transcript/\(id)", method: "GET"))
            let result = try decoder.decode(AssemblyTranscriptResponse.self, from: data)
            await onStatus(result.status)
            switch result.status {
            case "completed": return CompletedTranscript(result: result, rawData: data)
            case "error": throw ClientError.api(result.error ?? "The transcript failed without details.")
            default: try await Task.sleep(for: .seconds(4))
            }
        }
        throw CancellationError()
    }

    func subtitle(id: String, format: String) async throws -> String {
        let request = try request(path: "/v2/transcript/\(id)/\(format)?chars_per_caption=32", method: "GET")
        return String(decoding: try await data(for: request), as: UTF8.self)
    }

    func summary(transcriptText: String) async throws -> String {
        let endpoint = region.llmBaseURL.appending(path: "/v1/chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: ScribeJSONValue] = [
            "model": .string("claude-sonnet-4-6"),
            "max_tokens": .int(1600),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string("Summarize this meeting in the same language as the transcript. Use short sections for: summary, decisions, key points, and action items with owners when mentioned. Do not invent information.\n\nTRANSCRIPT:\n\(transcriptText)")
                ])
            ])
        ]
        request.httpBody = try JSONEncoder().encode(payload)
        let data = try await data(for: request)
        guard let content = try decoder.decode(LLMResponse.self, from: data).choices.first?.message.content else {
            throw ClientError.invalidResponse
        }
        return content
    }

    func deleteTranscript(id: String) async throws {
        _ = try await data(for: request(path: "/v2/transcript/\(id)", method: "DELETE"))
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private func request(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: region.apiBaseURL) else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 1_800
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let once: () async throws -> Data = {
            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)
            return data
        }
        // Only reads are retried: repeating a POST could create (and bill) a second transcript.
        return request.httpMethod == "GET" ? try await Self.withTransientRetries(once) : try await once()
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(statusCode: http.statusCode, data: data)
            if http.statusCode == 429 || (500...599).contains(http.statusCode) { throw ClientError.transient(message) }
            throw ClientError.api(message)
        }
    }

    static func errorMessage(statusCode: Int, data: Data) -> String {
        let body = String(decoding: data, as: UTF8.self).lowercased()
        if body.contains("does not have access to this llm") {
            return "Your AssemblyAI account doesn't have access to the summary model. The transcript is still available. Turn on LLM Gateway access in AssemblyAI, then try generating the summary again."
        }
        switch statusCode {
        case 401, 403:
            return "AssemblyAI denied access. Check the API key and region in Settings, then try again."
        case 402:
            return "AssemblyAI needs a credit balance to continue. Check billing for your account, then try again."
        case 429:
            return "AssemblyAI hit its request limit. Wait a few minutes, then try again."
        case 500...599:
            return "AssemblyAI is unavailable right now. Try again in a few minutes."
        case 404:
            return "This transcript is no longer available in AssemblyAI. Import the file again to create a new transcript."
        default:
            return "AssemblyAI didn't accept the request (HTTP \(statusCode)). Check the file format and transcription options in Settings."
        }
    }

    enum ClientError: LocalizedError {
        case invalidResponse, api(String), transient(String)
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "AssemblyAI sent an invalid response."
            case .api(let message), .transient(let message): message
            }
        }
    }
}
