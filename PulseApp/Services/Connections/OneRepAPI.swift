import Foundation

struct OneRepDaySummary: Sendable {
    let workoutCount: Int
    let trainingMinutes: Double
    let waterML: Double?
    let proteinGrams: Double?
    let sleepMinutes: Double?
    let steps: Double?
    let restingHeartRateBPM: Double?
    let hrvMS: Double?
    let activeEnergyKcal: Double?
    let restDay: Bool
}

enum OneRepAPIError: LocalizedError {
    case unauthorized, forbidden, rateLimited, unavailable, invalidResponse, workoutLimit

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your OneRep access has expired. Reconnect to continue."
        case .forbidden: "Check the permissions for this connection in OneRep Settings under API & MCP."
        case .workoutLimit: "Two workouts are already logged for this day. Edit one in OneRep."
        case .rateLimited: "OneRep has received too many requests. Try again later."
        case .unavailable: "OneRep is unavailable. Try again later."
        case .invalidResponse: "OneRep couldn’t complete this request."
        }
    }
}

private final class OneRepRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct OneRepAPI: Sendable {
    // Production origin and routes published in @onerep/sdk.
    static let origin = URL(string: "https://chatty-panda-144.convex.site")!
    private static let transport: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func send(_ request: URLRequest, token: String) async throws -> Data {
        guard let url = request.url, url.scheme == Self.origin.scheme, url.host == Self.origin.host,
              url.port == nil, url.user == nil, url.password == nil, url.path.hasPrefix("/v1/") else {
            throw OneRepAPIError.invalidResponse
        }
        var authorized = request
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        authorized.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.transport.data(for: authorized, delegate: OneRepRedirectPolicy())
        guard let http = response as? HTTPURLResponse else { throw OneRepAPIError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 400 where url.path == "/v1/workouts":
            struct Failure: Decodable {
                struct Reason: Decodable { let message: String }
                let error: Reason
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            if failure?.error.message.contains("Two sessions are already logged") == true {
                throw OneRepAPIError.workoutLimit
            }
            throw OneRepAPIError.invalidResponse
        case 401: throw OneRepAPIError.unauthorized
        case 403: throw OneRepAPIError.forbidden
        case 429: throw OneRepAPIError.rateLimited
        case 500...599: throw OneRepAPIError.unavailable
        default: throw OneRepAPIError.invalidResponse
        }
    }

    static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func readDay(_ date: Date, token: String) async throws -> OneRepDaySummary {
        let day = Self.dayKey(date)
        let diary = Self.origin.appending(path: "v1/days/\(day)")
        let health = Self.origin.appending(path: "v1/health/days").appending(queryItems: [
            URLQueryItem(name: "start", value: day), URLQueryItem(name: "end", value: day)
        ])
        async let diaryData = send(URLRequest(url: diary), token: token)
        async let healthData = send(URLRequest(url: health), token: token)
        return try await Self.summary(diaryData: diaryData, healthData: healthData, day: day)
    }

    static func summary(diaryData: Data, healthData: Data, day: String) throws -> OneRepDaySummary {
        struct Diary: Decodable {
            struct Entry: Decodable {}
            struct Nutrition: Decodable { let protein: Double; let entries: [Entry] }
            struct Workout: Decodable { let durationMinutes: Double }
            let date: String
            let nutrition: Nutrition
            let waterMl: Double
            let waterEntries: [Entry]
            let workouts: [Workout]
            let restDay: Bool
        }
        struct Health: Decodable {
            struct Day: Decodable {
                let date: String
                let sleepMinutes, steps, restingHeartRateBpm, hrvMs, activeEnergyKcal: Double?
            }
            let days: [Day]
        }
        let decoder = JSONDecoder()
        guard let diary = try? decoder.decode(Diary.self, from: diaryData), diary.date == day,
              let health = try? decoder.decode(Health.self, from: healthData) else { throw OneRepAPIError.invalidResponse }
        let readings = health.days.first { $0.date == day }
        return OneRepDaySummary(
            workoutCount: diary.workouts.count,
            trainingMinutes: diary.workouts.reduce(0) { $0 + $1.durationMinutes },
            waterML: diary.waterEntries.isEmpty ? nil : diary.waterMl,
            proteinGrams: diary.nutrition.entries.isEmpty ? nil : diary.nutrition.protein,
            sleepMinutes: readings?.sleepMinutes, steps: readings?.steps,
            restingHeartRateBPM: readings?.restingHeartRateBpm, hrvMS: readings?.hrvMs,
            activeEnergyKcal: readings?.activeEnergyKcal, restDay: diary.restDay
        )
    }
}
